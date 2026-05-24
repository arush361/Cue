//
//  WhisperKitTranscriptionProvider.swift
//  leanring-buddy
//
//  Fully on-device transcription using WhisperKit (CoreML-accelerated Whisper
//  for Apple Silicon). Push-to-talk audio is buffered locally and transcribed
//  on key-up via WhisperKit's `transcribe(audioPath:)` API.
//
//  The implementation is wrapped in `#if canImport(WhisperKit)` so this file
//  compiles cleanly even before the WhisperKit Swift package has been added
//  to the Xcode project. Until WhisperKit is added, `isConfigured` returns
//  false and the factory falls back to Apple Speech.
//
//  To enable: in Xcode, File → Add Packages → paste
//  https://github.com/argmaxinc/WhisperKit → add the WhisperKit product to
//  the leanring-buddy target. Then rebuild — the provider activates automatically.
//

import AVFoundation
import Foundation

#if canImport(WhisperKit)
import WhisperKit
#endif

struct WhisperKitTranscriptionProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class WhisperKitTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "WhisperKit (on-device)"
    let requiresSpeechRecognitionPermission = false

    #if canImport(WhisperKit)
    /// Which Whisper variant to load. "openai_whisper-small.en" balances accuracy
    /// and latency well on Apple Silicon. Larger variants give better accuracy
    /// at the cost of binary/model size and first-token latency.
    private static let whisperModelName = "openai_whisper-small.en"

    /// Lazily-initialized WhisperKit instance. Building the pipeline involves
    /// loading model weights and warming up the encoder, which takes a few
    /// seconds the first time. We do it once and reuse across sessions.
    private static let sharedWhisperKitInstanceTask: Task<WhisperKit, Error> = Task {
        try await WhisperKit(model: whisperModelName)
    }
    #endif

    var isConfigured: Bool {
        #if canImport(WhisperKit)
        return true
        #else
        return false
        #endif
    }

    var unavailableExplanation: String? {
        #if canImport(WhisperKit)
        return nil
        #else
        return "WhisperKit Swift package is not added to the project yet. See SETUP_OFFLINE.md."
        #endif
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        #if canImport(WhisperKit)
        return WhisperKitTranscriptionSession(
            whisperKitInstanceTask: Self.sharedWhisperKitInstanceTask,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
        #else
        throw WhisperKitTranscriptionProviderError(
            message: "WhisperKit package not added to the project. See SETUP_OFFLINE.md."
        )
        #endif
    }
}

#if canImport(WhisperKit)

/// WhisperKit operates on whole-utterance audio, not streaming chunks like
/// AssemblyAI's websocket. So this session buffers PCM16 audio while the
/// user holds push-to-talk, then runs a single transcription pass when the
/// key is released. The result is delivered via `onFinalTranscriptReady`.
private final class WhisperKitTranscriptionSession: BuddyStreamingTranscriptionSession {
    /// WhisperKit is fast on Apple Silicon (a couple hundred ms for short
    /// clips with small.en) but not instant. Give it a generous fallback
    /// window before the caller assumes failure.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 6.0

    /// WhisperKit expects 16kHz mono audio.
    private static let whisperKitTargetSampleRateHz: Double = 16_000

    private let whisperKitInstanceTask: Task<WhisperKit, Error>
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let audioConverter: BuddyPCM16AudioConverter
    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var transcriptionTask: Task<Void, Never>?

    init(
        whisperKitInstanceTask: Task<WhisperKit, Error>,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.whisperKitInstanceTask = whisperKitInstanceTask
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
        self.audioConverter = BuddyPCM16AudioConverter(
            targetSampleRate: Self.whisperKitTargetSampleRateHz
        )
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard !hasRequestedFinalTranscript else { return }
        guard let pcm16Chunk = audioConverter.convertToPCM16Data(from: audioBuffer) else { return }
        bufferedPCM16AudioData.append(pcm16Chunk)
    }

    func requestFinalTranscript() {
        guard !hasRequestedFinalTranscript else { return }
        hasRequestedFinalTranscript = true

        let capturedPCM16Audio = bufferedPCM16AudioData
        // Whisper's official VAD threshold is ~0.1s of audio. Anything under
        // that is silence and we just deliver an empty transcript.
        guard capturedPCM16Audio.count >= 3200 else {
            deliverFinalTranscriptIfNeeded("")
            return
        }

        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let whisperKitInstance = try await self.whisperKitInstanceTask.value
                let temporaryWAVFileURL = try Self.writePCM16ToTemporaryWAVFile(
                    pcm16AudioData: capturedPCM16Audio,
                    sampleRate: Int(Self.whisperKitTargetSampleRateHz)
                )
                defer { try? FileManager.default.removeItem(at: temporaryWAVFileURL) }

                let transcriptionResults = try await whisperKitInstance.transcribe(
                    audioPath: temporaryWAVFileURL.path
                )

                let recognizedText = transcriptionResults
                    .map { $0.text }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                await MainActor.run {
                    if !recognizedText.isEmpty {
                        self.onTranscriptUpdate(recognizedText)
                    }
                    self.deliverFinalTranscriptIfNeeded(recognizedText)
                }
            } catch {
                await MainActor.run { self.onError(error) }
            }
        }
    }

    func cancel() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        bufferedPCM16AudioData.removeAll()
    }

    private func deliverFinalTranscriptIfNeeded(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }

    private static func writePCM16ToTemporaryWAVFile(
        pcm16AudioData: Data,
        sampleRate: Int
    ) throws -> URL {
        let wavBytes = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: pcm16AudioData,
            sampleRate: sampleRate
        )
        let temporaryFileName = "cue-whisperkit-\(UUID().uuidString).wav"
        let temporaryWAVFileURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(temporaryFileName)
        try wavBytes.write(to: temporaryWAVFileURL)
        return temporaryWAVFileURL
    }

    deinit {
        cancel()
    }
}

#endif
