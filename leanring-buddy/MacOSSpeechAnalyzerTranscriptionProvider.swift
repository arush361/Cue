//
//  MacOSSpeechAnalyzerTranscriptionProvider.swift
//  leanring-buddy
//
//  macOS-26+ on-device transcription using the new Speech framework
//  (SpeechAnalyzer + DictationTranscriber). No model download, no
//  WhisperKit dependency — the dictation model ships with the OS
//  (locale packs are managed in System Settings → Accessibility →
//  Spoken Content).
//
//  We pick DictationTranscriber over SpeechTranscriber because Apple
//  documents it as "similar to system dictation features" — a better
//  fit for our push-to-talk use case than the general-purpose transcriber.
//
//  Preset: `progressiveShortDictation` — Apple's own description is
//  "immediate transcription of about a minute of live audio", which
//  matches push-to-talk semantics exactly (interim results streamed
//  live, final result on key release).
//
//  Falls back gracefully: on macOS < 26, the entire file is gated out
//  via @available. On macOS 26 with no installed locale, isConfigured
//  returns false so the factory continues to WhisperKit / SFSpeechRecognizer.
//
//  Public API matches AppleSpeechTranscriptionProvider so the dictation
//  manager doesn't change.
//

import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, *)
struct MacOSSpeechAnalyzerTranscriptionProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@available(macOS 26.0, *)
final class MacOSSpeechAnalyzerTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "macOS 26 Speech (SpeechAnalyzer)"
    let requiresSpeechRecognitionPermission = true

    /// Locales we'll try in priority order. First match in
    /// `DictationTranscriber.installedLocales` (async) wins at session start;
    /// otherwise we throw and the dictation manager surfaces the error.
    private static let candidateLocales: [Locale] = [
        Locale.autoupdatingCurrent,
        Locale(identifier: "en-US"),
        Locale(identifier: "en-GB"),
    ]

    /// Both `supportedLocales` and `installedLocales` on
    /// DictationTranscriber are `get async`, so neither can gate the
    /// sync `isConfigured` check. The @available(macOS 26.0) class-level
    /// gate is our only sync OS-availability signal — that's enough.
    ///
    /// The real locale-installed check happens inside `startStreamingSession`
    /// (async path) and throws a clear error if no dictation locale is
    /// available. Almost all macOS 26 machines have at least one dictation
    /// locale installed by default, so this edge case is rare.
    let isConfigured = true

    let unavailableExplanation: String? = nil

    /// Async resolution of the best installed locale. Called inside
    /// `startStreamingSession` (which is async) so we get the real check
    /// without blocking the sync factory path.
    private static func bestInstalledLocale() async -> Locale? {
        let installed = await DictationTranscriber.installedLocales
        for candidate in candidateLocales {
            if installed.contains(where: { $0.identifier == candidate.identifier }) {
                return candidate
            }
        }
        return nil
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard let locale = await Self.bestInstalledLocale() else {
            throw MacOSSpeechAnalyzerTranscriptionProviderError(
                message: "No dictation locale installed. Add one in System Settings → Accessibility → Spoken Content."
            )
        }
        return try await MacOSSpeechAnalyzerTranscriptionSession(
            locale: locale,
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

@available(macOS 26.0, *)
final class MacOSSpeechAnalyzerTranscriptionSession: BuddyStreamingTranscriptionSession {
    /// Matches the AppleSpeech provider — gives the recognizer a moment
    /// to flush the final result after we close audio input.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 1.2

    private let transcriber: DictationTranscriber
    private let analyzer: SpeechAnalyzer
    private let bufferContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void
    private var resultsTask: Task<Void, Never>?

    /// Format SpeechAnalyzer requires for our chosen modules. Each incoming
    /// AVAudioPCMBuffer is converted to this format before being yielded.
    /// Apple's docs: "the analyzer does not transparently upsample,
    /// downsample, or convert audio input." Failure mode if we skip this:
    /// `Failed precondition: Audio sample data must be 16-bit signed integers`.
    private let requiredAudioFormat: AVAudioFormat

    /// Reused per buffer; lazily created the first time a real source
    /// format arrives in `appendAudioBuffer` (we don't know it at init
    /// time because the dictation manager owns AVAudioEngine).
    private var audioConverter: AVAudioConverter?

    private var latestRecognizedText = ""
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false

    init(
        locale: Locale,
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws {
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError

        // Live-streaming dictation preset (interim results during speech,
        // final on close). See Apple docs:
        //   progressiveShortDictation — "immediate transcription of about
        //   a minute of live audio"
        self.transcriber = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
        self.analyzer = SpeechAnalyzer(modules: [transcriber])

        // (1) Ask the system to download/allocate any dictation assets the
        //     transcriber needs for this locale. Without this we hit:
        //       "Cannot use modules with unallocated locales [en_CA]"
        //     The request returns nil if everything is already present, or
        //     an in-progress download object otherwise. First-run shows a
        //     system download UI; subsequent runs hit the cache.
        if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installationRequest.downloadAndInstall()
        }

        // (2) Discover the audio format the modules want and stash it. We
        //     convert each incoming AVAudioPCMBuffer to this format before
        //     yielding to the analyzer. Returns nil when modules need more
        //     assets installed — in practice (1) already handled that.
        guard let pickedFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw MacOSSpeechAnalyzerTranscriptionProviderError(
                message: "SpeechAnalyzer could not pick an audio format for the chosen modules."
            )
        }
        self.requiredAudioFormat = pickedFormat
        print("🎙️ SpeechAnalyzer: requiredAudioFormat = \(pickedFormat)")

        // Feed analyzer through an AsyncStream of AnalyzerInput. Each
        // AVAudioPCMBuffer the dictation manager hands us gets converted
        // to `requiredAudioFormat` and wrapped in AnalyzerInput inside
        // `appendAudioBuffer`.
        let (bufferStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.bufferContinuation = continuation

        // Optional context biasing: pass project/app proper nouns the
        // dictation model wouldn't otherwise recognize. Limited to 100
        // total per Apple's guidance.
        if !keyterms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: Array(keyterms.prefix(100))]
            try await analyzer.setContext(context)
        }

        try await analyzer.start(inputSequence: bufferStream)

        // Drain results. We treat EVERY result's text as the latest
        // running transcript (matches Apple's own sample code — there's
        // no documented `isFinal` flag on DictationTranscriber.Result).
        // When the user releases push-to-talk, the dictation manager
        // calls `requestFinalTranscript()` which closes the input stream
        // and triggers `finalizeAndFinishThroughEndOfInput()`. That ends
        // the results AsyncSequence; we then flush whatever text we have
        // as the final transcript.
        resultsTask = Task { [weak self] in
            guard let self else { return }
            var resultCount = 0
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    resultCount += 1
                    self.latestRecognizedText = text
                    print("🎙️ SpeechAnalyzer result #\(resultCount): \"\(text)\"")
                    self.onTranscriptUpdate(text)
                }
                print("🎙️ SpeechAnalyzer: results stream completed after \(resultCount) results. Final text: \"\(self.latestRecognizedText)\"")
                // Results stream completed (analyzer was finalized). Flush
                // latest text as the final transcript.
                if !self.latestRecognizedText.isEmpty {
                    self.deliverFinalTranscriptIfNeeded(self.latestRecognizedText)
                }
            } catch {
                if !self.hasDeliveredFinalTranscript {
                    self.onError(error)
                }
            }
        }
    }

    /// Diagnostic counters so we can see audio flow in the console when
    /// transcription doesn't appear to be happening.
    private var buffersReceived = 0
    private var buffersYielded = 0
    private var buffersDroppedFromConversion = 0
    private var hasLoggedFirstBuffer = false

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard !hasRequestedFinalTranscript else { return }
        buffersReceived += 1

        if !hasLoggedFirstBuffer {
            hasLoggedFirstBuffer = true
            print("🎙️ SpeechAnalyzer: first audio buffer arrived, source format = \(audioBuffer.format), frameLength = \(audioBuffer.frameLength)")
        }

        // Fast path: source already matches what the analyzer wants
        // (rare — AVAudioEngine typically hands us Float32 even when the
        // tap is requested in 16-bit).
        if audioBuffer.format.isEqual(requiredAudioFormat) {
            bufferContinuation.yield(AnalyzerInput(buffer: audioBuffer))
            buffersYielded += 1
            return
        }

        // Lazy-create the converter once we see the actual source format.
        // It's the same converter for every subsequent buffer in the session.
        if audioConverter == nil {
            audioConverter = AVAudioConverter(from: audioBuffer.format, to: requiredAudioFormat)
            print("🎙️ SpeechAnalyzer: created converter \(audioBuffer.format.sampleRate)Hz/\(audioBuffer.format.commonFormat.rawValue) → \(requiredAudioFormat.sampleRate)Hz/\(requiredAudioFormat.commonFormat.rawValue), converter = \(audioConverter == nil ? "FAILED" : "ok")")
        }
        guard let audioConverter else {
            buffersDroppedFromConversion += 1
            return
        }

        // Allocate an output buffer sized for the worst-case sample-rate
        // ratio. AVAudioConverter handles the underlying interleave / int16
        // packing the analyzer requires.
        let outputFrameCapacity = AVAudioFrameCount(
            Double(audioBuffer.frameLength)
                * (requiredAudioFormat.sampleRate / audioBuffer.format.sampleRate)
        ) + 1
        guard
            let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: requiredAudioFormat,
                frameCapacity: outputFrameCapacity
            )
        else {
            buffersDroppedFromConversion += 1
            return
        }

        var conversionError: NSError?
        var didProvideInput = false
        let status = audioConverter.convert(
            to: convertedBuffer,
            error: &conversionError
        ) { _, inputStatus in
            // Hand the source buffer once, then signal end-of-stream so the
            // converter flushes. The closure may be called multiple times.
            if didProvideInput {
                inputStatus.pointee = .endOfStream
                return nil
            }
            didProvideInput = true
            inputStatus.pointee = .haveData
            return audioBuffer
        }

        if status == .error || conversionError != nil {
            if buffersDroppedFromConversion == 0 {
                print("⚠️ SpeechAnalyzer: first conversion error — status=\(status.rawValue), err=\(conversionError?.localizedDescription ?? "nil")")
            }
            buffersDroppedFromConversion += 1
            return
        }

        if convertedBuffer.frameLength > 0 {
            bufferContinuation.yield(AnalyzerInput(buffer: convertedBuffer))
            buffersYielded += 1
        }
    }

    func requestFinalTranscript() {
        guard !hasRequestedFinalTranscript else { return }
        hasRequestedFinalTranscript = true
        print("🎙️ SpeechAnalyzer: requestFinalTranscript — received=\(buffersReceived), yielded=\(buffersYielded), dropped=\(buffersDroppedFromConversion)")
        bufferContinuation.finish()
        Task { [analyzer] in
            do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
            catch { print("⚠️ SpeechAnalyzer: finalizeAndFinishThroughEndOfInput threw \(error)") }
        }
    }

    func cancel() {
        bufferContinuation.finish()
        resultsTask?.cancel()
        resultsTask = nil
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
    }

    private func deliverFinalTranscriptIfNeeded(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }

    deinit {
        bufferContinuation.finish()
        resultsTask?.cancel()
    }
}
