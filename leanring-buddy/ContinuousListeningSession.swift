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

    /// The whole transcript the analyzer has produced since the start
    /// of this session. We slice it on each segment finalize.
    private var fullTranscript: String = ""

    /// Char index in `fullTranscript` past which we haven't yet flushed.
    /// Advances on every onSegmentFinalized fire.
    private var lastFlushedCursor: Int = 0

    /// Tracks the VAD state so we don't fire onSpeechStarted twice in a
    /// row, and so we know whether a silence event corresponds to an
    /// actual end-of-utterance (we had speech before it).
    private var isCurrentlyDetectingSpeech: Bool = false

    private var transcriberTask: Task<Void, Never>?
    private var detectorTask: Task<Void, Never>?
    private var hasFinished: Bool = false

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

        // (3) Drain transcriber results — every new partial appends to
        // fullTranscript. The detector task uses fullTranscript to
        // compute the slice on finalize.
        transcriberTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    self.fullTranscript = text
                    self.onTranscriptUpdate(text)
                }
            } catch {
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
                    if speakingNow && !self.isCurrentlyDetectingSpeech {
                        self.isCurrentlyDetectingSpeech = true
                        self.onSpeechStarted()
                    } else if !speakingNow && self.isCurrentlyDetectingSpeech {
                        self.isCurrentlyDetectingSpeech = false
                        self.flushSegmentIfAny()
                    }
                }
            } catch {
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

    /// Called by the orchestrator when the user double-presses to exit
    /// (or the session timeout fires).
    func finish() async {
        guard !hasFinished else { return }
        hasFinished = true
        bufferContinuation.finish()
        do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
        catch { /* swallow — about to be torn down anyway */ }
        // Final flush in case the user was mid-sentence at exit.
        flushSegmentIfAny()
        transcriberTask?.cancel()
        detectorTask?.cancel()
    }

    /// Cancels without waiting for the analyzer to drain. Used when
    /// something errored and we want to bail fast.
    func cancel() {
        hasFinished = true
        bufferContinuation.finish()
        transcriberTask?.cancel()
        detectorTask?.cancel()
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
    }

    // MARK: - Helpers

    private func flushSegmentIfAny() {
        guard lastFlushedCursor < fullTranscript.count else { return }
        let slice = String(fullTranscript.dropFirst(lastFlushedCursor))
        let trimmed = slice.trimmingCharacters(in: .whitespacesAndNewlines)
        lastFlushedCursor = fullTranscript.count
        if !trimmed.isEmpty {
            onSegmentFinalized(trimmed)
        }
    }
}
