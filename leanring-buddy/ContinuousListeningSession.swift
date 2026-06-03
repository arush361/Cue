//
//  ContinuousListeningSession.swift
//  leanring-buddy
//
//  Hands-free dictation session that stays open across multiple
//  utterances. Pairs `DictationTranscriber` with `SpeechDetector` so
//  Apple's voice-activity detection segments the user's speech for us —
//  every time the detector flips from "speech" to "silence" we flush
//  the accumulated transcript as a finished segment to the orchestrator
//  (which forwards it to Claude).
//
//  This is the macOS-26-only sister to MacOSSpeechAnalyzerTranscriptionSession,
//  but with different goals:
//    - PTT session: one segment per press-and-hold, finalized on release.
//    - Continuous session: many segments per "session", finalized by VAD.
//
//  Lifecycle:
//    1. caller `init(locale:)` → installs assets, picks audio format,
//       starts the SpeechAnalyzer with both modules
//    2. caller `appendAudioBuffer(_:)` repeatedly while the user speaks
//    3. detector fires `speechDetected = true`  → onSpeechStarted (used
//       by orchestrator for barge-in: cancel any in-flight TTS)
//    4. transcriber fires `Result` deltas → onTranscriptUpdate
//    5. detector fires `speechDetected = false` → onSegmentFinalized(text)
//       with the slice since the previous finalize
//    6. caller `finish()` on session exit → tears down the analyzer
//

import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, *)
struct ContinuousListeningSessionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@available(macOS 26.0, *)
final class ContinuousListeningSession {
    // MARK: - Callbacks set by the orchestrator (CompanionManager)

    /// Latest transcribed text since session start, on every interim
    /// result. Useful for UI; consumers should not derive "segments"
    /// from this — use onSegmentFinalized instead.
    var onTranscriptUpdate: (String) -> Void = { _ in }

    /// VAD detected the user began speaking. Used for barge-in
    /// semantics: orchestrator cancels any in-flight TTS so the user
    /// isn't talking over Cue.
    var onSpeechStarted: () -> Void = {}

    /// VAD detected end-of-speech AND there's new transcript text past
    /// the previous segment. Argument is the NEW text only (slice past
    /// the previously-flushed cursor) — orchestrator can forward it
    /// straight to Claude without dedup work.
    var onSegmentFinalized: (String) -> Void = { _ in }

    /// Any non-recoverable error from the analyzer or its modules.
    var onError: (Error) -> Void = { _ in }

    // MARK: - Internals

    private let transcriber: DictationTranscriber
    private let detector: SpeechDetector
    private let analyzer: SpeechAnalyzer
    private let bufferContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let requiredAudioFormat: AVAudioFormat
    private var audioConverter: AVAudioConverter?

    /// The latest text from `DictationTranscriber` — what the user
    /// most recently said as the transcriber currently sees it. Used
    /// for UI live-preview only; flush uses `bestTranscriptForCurrentSegment`.
    private var fullTranscript: String = ""

    /// The longest stable transcript we've seen since the last flush.
    /// `DictationTranscriber` sometimes shrinks its own output between
    /// the final partial and the per-utterance reset (e.g.
    ///   "Hey, how can I find the stock price of Nvidia?"
    ///   "Hey, how can I find the stock price of Nvidia"   ← drops ?
    ///   "?"                                                ← resets
    /// ). If we flushed `fullTranscript` at silence we'd lose the
    /// real utterance and emit just "?". Tracking the LONGEST text
    /// in the same trajectory (where one is a prefix of the other)
    /// gives us the user's actual question to flush.
    private var bestTranscriptForCurrentSegment: String = ""

    /// Snapshot of the transcript that was actually flushed last. Used
    /// to dedupe in accumulator-mode transcribers — if the new "best"
    /// text starts with this, we emit only the tail. Reset (cleared)
    /// after each flush via assignment of the current best.
    private var lastFlushedTranscript: String = ""

    /// Tracks the VAD state so we don't fire onSpeechStarted twice in a
    /// row, and so we know whether a silence event corresponds to an
    /// actual end-of-utterance (we had speech before it).
    private var isCurrentlyDetectingSpeech: Bool = false

    private var transcriberTask: Task<Void, Never>?
    private var detectorTask: Task<Void, Never>?
    private var hasFinished: Bool = false

    /// Silence-based fallback. We schedule this every time the
    /// transcriber emits a new partial; if the transcript stays
    /// unchanged for `silenceFinalizeSeconds`, we treat that as
    /// end-of-utterance and flush the segment. Belt-and-suspenders for
    /// the case where SpeechDetector.results doesn't fire (which has
    /// been observed on macOS 26 betas).
    private var silenceTimer: Timer?
    /// How long the transcript must be unchanged before we treat it as
    /// end-of-utterance and flush. Too short and intra-sentence pauses
    /// fragment one utterance into N Claude calls; too long and the
    /// session feels sluggish. 1.0s is the goldilocks zone in practice.
    private static let silenceFinalizeSeconds: TimeInterval = 1.0

    // MARK: - Init / lifecycle

    init(locale: Locale) async throws {
        // Live-streaming dictation preset — same as PTT path because
        // the underlying capability is identical.
        self.transcriber = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)

        // `reportResults: true` is required to receive any Result from
        // SpeechDetector's `results` stream. Default `init()` runs the
        // VAD silently — we need the events for segmentation.
        //
        // `.medium` is Apple's recommended sensitivity level. `.low` is
        // more forgiving (won't cut off short pauses), `.high` is
        // aggressive (might fragment a slow speaker). If users report
        // bad VAD behavior, surface this as a setting later.
        self.detector = SpeechDetector(
            detectionOptions: SpeechDetector.DetectionOptions(sensitivityLevel: .medium),
            reportResults: true
        )

        self.analyzer = SpeechAnalyzer(modules: [transcriber, detector])

        // (1) Install dictation assets for the locale.
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await req.downloadAndInstall()
        }

        // (2) Discover the audio format the modules want.
        guard let picked = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw ContinuousListeningSessionError(
                message: "SpeechAnalyzer could not pick an audio format for the chosen modules."
            )
        }
        self.requiredAudioFormat = picked
        print("🎙️ ContinuousListening: requiredAudioFormat = \(picked)")

        let (bufferStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.bufferContinuation = continuation

        try await analyzer.start(inputSequence: bufferStream)

        // (3) Drain transcriber results. We track two strings:
        //   - fullTranscript: latest text from the transcriber (UI preview).
        //   - bestTranscriptForCurrentSegment: longest text we've seen
        //     during the current utterance; this is what we flush.
        //
        // Earlier versions tried to detect a "hard reset" (new partial
        // shares no prefix with best) and flush early from this loop.
        // That fired prematurely on punctuation flicker like
        // "...to?" → "...to this" and split single questions into
        // multiple Claude calls. We rely exclusively on the silence
        // timer for flush timing now — when the transcript stops
        // changing for `silenceFinalizeSeconds`, the user has stopped
        // speaking and we flush. Simpler, and proven correct in trace.
        transcriberTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    self.fullTranscript = text
                    print("🎙️ ContinuousListening transcriber: \"\(text)\"")
                    self.onTranscriptUpdate(text)

                    // Keep the longest text we've seen this utterance.
                    // The transcriber may shrink its own output (drop
                    // trailing punctuation, reset to "?") between the
                    // mature partial and the next utterance — never let
                    // that overwrite our best.
                    if text.count > self.bestTranscriptForCurrentSegment.count {
                        self.bestTranscriptForCurrentSegment = text
                    }
                    await MainActor.run { self.scheduleSilenceFlush() }
                }
                print("🎙️ ContinuousListening transcriber: stream ended")
            } catch {
                print("⚠️ ContinuousListening transcriber error: \(error.localizedDescription)")
                self.onError(error)
            }
        }

        // (4) Drain VAD events — true/false transitions trigger
        // onSpeechStarted / onSegmentFinalized.
        detectorTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in detector.results {
                    let speakingNow = result.speechDetected
                    print("🛰️ ContinuousListening VAD: speechDetected=\(speakingNow) (was=\(self.isCurrentlyDetectingSpeech))")
                    if speakingNow && !self.isCurrentlyDetectingSpeech {
                        self.isCurrentlyDetectingSpeech = true
                        self.onSpeechStarted()
                    } else if !speakingNow && self.isCurrentlyDetectingSpeech {
                        self.isCurrentlyDetectingSpeech = false
                        self.flushSegmentIfAny()
                    }
                }
                print("🛰️ ContinuousListening VAD: stream ended")
            } catch {
                print("⚠️ ContinuousListening VAD error: \(error.localizedDescription)")
                self.onError(error)
            }
        }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard !hasFinished else { return }

        if audioBuffer.format.isEqual(requiredAudioFormat) {
            bufferContinuation.yield(AnalyzerInput(buffer: audioBuffer))
            return
        }

        if audioConverter == nil {
            audioConverter = AVAudioConverter(from: audioBuffer.format, to: requiredAudioFormat)
        }
        guard let converter = audioConverter else { return }

        let outputCapacity = AVAudioFrameCount(
            Double(audioBuffer.frameLength)
                * (requiredAudioFormat.sampleRate / audioBuffer.format.sampleRate)
        ) + 1
        guard
            let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: requiredAudioFormat,
                frameCapacity: outputCapacity
            )
        else { return }

        var err: NSError?
        var didProvide = false
        let status = converter.convert(to: convertedBuffer, error: &err) { _, inputStatus in
            // Same trap as PTT: `.noDataNow` keeps the converter alive
            // across calls; `.endOfStream` would terminate it after the
            // first buffer.
            if didProvide {
                inputStatus.pointee = .noDataNow
                return nil
            }
            didProvide = true
            inputStatus.pointee = .haveData
            return audioBuffer
        }

        if status == .error || err != nil { return }
        if convertedBuffer.frameLength > 0 {
            bufferContinuation.yield(AnalyzerInput(buffer: convertedBuffer))
        }
    }

    /// Called by the orchestrator when the user toggles the session
    /// off (or the session timeout fires).
    func finish() async {
        guard !hasFinished else { return }
        hasFinished = true
        await MainActor.run {
            self.silenceTimer?.invalidate()
            self.silenceTimer = nil
        }
        bufferContinuation.finish()
        do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
        catch { /* swallow — about to be torn down anyway */ }
        // Final flush in case the user was mid-sentence at exit.
        await MainActor.run { self.flushSegmentIfAny() }
        transcriberTask?.cancel()
        detectorTask?.cancel()
    }

    /// Cancels without waiting for the analyzer to drain. Used when
    /// something errored and we want to bail fast.
    func cancel() {
        hasFinished = true
        let pendingSilenceTimer = silenceTimer
        silenceTimer = nil
        Task { @MainActor in pendingSilenceTimer?.invalidate() }
        bufferContinuation.finish()
        transcriberTask?.cancel()
        detectorTask?.cancel()
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
    }

    // MARK: - Helpers

    private func flushSegmentIfAny() {
        let current = bestTranscriptForCurrentSegment
        guard !current.isEmpty else { return }
        let newText: String
        if !lastFlushedTranscript.isEmpty && current.hasPrefix(lastFlushedTranscript) {
            // Append-mode transcriber: emit only the tail past the
            // already-flushed portion.
            newText = String(current.dropFirst(lastFlushedTranscript.count))
        } else {
            // Reset-mode transcriber (or first flush, or transcriber
            // reset to a different prefix mid-session): the entire
            // current best is the new segment.
            newText = current
        }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Always advance state, even if we skip — otherwise we'd
        // re-flush the same accumulated text on every silence tick.
        lastFlushedTranscript = current
        bestTranscriptForCurrentSegment = ""
        guard !trimmed.isEmpty else { return }
        // Skip junk fragments: trailing punctuation only ("?"), or
        // less than 2 word-ish characters. These come from the
        // transcriber's per-utterance reset emitting just the trailing
        // punctuation of the prior utterance.
        let alphanumericCount = trimmed.unicodeScalars.lazy.filter { CharacterSet.alphanumerics.contains($0) }.count
        guard alphanumericCount >= 2 else {
            print("⏭️ ContinuousListening: skipping trivial segment: \"\(trimmed)\"")
            return
        }
        print("📤 ContinuousListening: flushing segment: \"\(trimmed)\"")
        onSegmentFinalized(trimmed)
    }

    /// Restart the silence timer. Each new transcriber partial pushes
    /// the deadline forward; if the user keeps talking, the timer
    /// never fires. After `silenceFinalizeSeconds` of stable
    /// transcript, we treat that as end-of-utterance and flush.
    @MainActor
    private func scheduleSilenceFlush() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.silenceFinalizeSeconds,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                print("⏱️ ContinuousListening: silence-flush fired")
                self.flushSegmentIfAny()
            }
        }
    }
}
