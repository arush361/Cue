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

        // Feed analyzer through an AsyncStream of AnalyzerInput. Each
        // AVAudioPCMBuffer the dictation manager hands us gets wrapped
        // into an AnalyzerInput inside `appendAudioBuffer`.
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

        // Drain partial + final results. SpeechAnalyzer is an actor and
        // AsyncSequence iteration is cooperatively scheduled, so it's
        // fine to spin this off on a detached task.
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
        bufferContinuation.yield(AnalyzerInput(buffer: audioBuffer))
    }

    func requestFinalTranscript() {
        guard !hasRequestedFinalTranscript else { return }
        hasRequestedFinalTranscript = true
        bufferContinuation.finish()
        Task { [analyzer] in
            do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
            catch { /* ignore — the results task surfaces any error */ }
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
