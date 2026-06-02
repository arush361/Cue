//
//  MacOSSpeechAnalyzerTranscriptionProvider.swift
//  leanring-buddy
//
//  macOS-26+ on-device transcription using the new Speech framework
//  (SpeechAnalyzer + DictationTranscriber). No model download, no
//  WhisperKit dependency — the model ships with the OS (locale packs
//  are managed in System Settings → Accessibility → Spoken Content).
//
//  We pick DictationTranscriber over SpeechTranscriber because Apple
//  documents it as "similar to system dictation features" — a better
//  fit for our push-to-talk use case than the general-purpose transcriber.
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

    /// Locale we'll try in priority order. First match in `installedLocales`
    /// wins; otherwise we report unconfigured and fall back to WhisperKit.
    private static let candidateLocales: [Locale] = [
        Locale.autoupdatingCurrent,
        Locale(identifier: "en-US"),
        Locale(identifier: "en-GB"),
    ]

    private static var bestInstalledLocale: Locale? {
        guard DictationTranscriber.isAvailable else { return nil }
        let installed = DictationTranscriber.installedLocales
        for candidate in candidateLocales {
            if installed.contains(where: { $0.identifier == candidate.identifier }) {
                return candidate
            }
        }
        return nil
    }

    var isConfigured: Bool {
        Self.bestInstalledLocale != nil
    }

    var unavailableExplanation: String? {
        guard DictationTranscriber.isAvailable else {
            return "macOS 26 Speech is not available on this hardware."
        }
        if Self.bestInstalledLocale == nil {
            let preferred = Self.candidateLocales.first?.identifier ?? "en-US"
            return "Install the dictation model for \(preferred) in System Settings → Accessibility → Spoken Content."
        }
        return nil
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard let locale = Self.bestInstalledLocale else {
            throw MacOSSpeechAnalyzerTranscriptionProviderError(
                message: unavailableExplanation ?? "macOS 26 Speech unavailable."
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
    /// Empirically chosen to match the AppleSpeech provider — gives the
    /// recognizer a moment to emit the final result after we close audio.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 1.2

    private let transcriber: DictationTranscriber
    private let analyzer: SpeechAnalyzer
    private let bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void
    private var resultsTask: Task<Void, Never>?

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

        // DictationTranscriber: dictation-tuned, on-device, matches the
        // accuracy/latency profile of the system dictation widget.
        self.transcriber = DictationTranscriber(locale: locale, preset: .dictation)
        self.analyzer = SpeechAnalyzer(modules: [transcriber])

        // Feed audio buffers through an AsyncStream the analyzer consumes
        // autonomously. Continuation is captured so appendAudioBuffer can
        // yield into it from the synchronous dictation-manager callback.
        let (bufferStream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.bufferContinuation = continuation

        // Apply optional context biasing if the caller supplied key terms
        // (project / app names that the dictation model wouldn't otherwise
        // recognize well). DictationTranscriber accepts these via the
        // analyzer's AnalysisContext.contextualStrings.
        if !keyterms.isEmpty {
            try await analyzer.setContext({
                let context = AnalysisContext()
                context.contextualStrings = keyterms
                return context
            }())
        }

        try await analyzer.start(inputSequence: bufferStream)

        // Drain partial + final results into the dictation manager's
        // callbacks. We run on a detached task; the analyzer is an actor
        // and AsyncSequence iteration is cooperatively scheduled.
        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    self.latestRecognizedText = text
                    if result.isFinal {
                        self.deliverFinalTranscriptIfNeeded(text)
                    } else {
                        self.onTranscriptUpdate(text)
                    }
                }
                // Results stream completed without a final-flagged result —
                // common when finalizeAndFinish was called. Flush latest text.
                if self.hasRequestedFinalTranscript {
                    self.deliverFinalTranscriptIfNeeded(self.latestRecognizedText)
                }
            } catch {
                if !self.hasDeliveredFinalTranscript {
                    self.onError(error)
                }
            }
        }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard !hasRequestedFinalTranscript else { return }
        bufferContinuation.yield(audioBuffer)
    }

    func requestFinalTranscript() {
        guard !hasRequestedFinalTranscript else { return }
        hasRequestedFinalTranscript = true
        bufferContinuation.finish()
        Task { [analyzer] in
            do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
            catch { /* ignore — results task will surface anything actionable */ }
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
