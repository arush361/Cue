//
//  KokoroTTSClient.swift
//  leanring-buddy
//
//  On-device neural TTS using Kokoro-82M v1.0 via ONNX Runtime.
//
//  Pipeline:
//    text → KokoroPhonemizer (CMU dict + ARPAbet→IPA + letter fallback)
//         → KokoroTokenizer (IPA chars → int64 token IDs)
//         → ONNX Runtime forward pass (tokens, style, speed → audio)
//         → AVAudioPlayer (24kHz mono float32 PCM playback)
//
//  Wrapped in `#if canImport(OnnxRuntimeBindings)` so the file compiles
//  before the ONNX Runtime Swift Package is added to the Xcode project.
//  Until ONNX Runtime is wired up, `isReady` returns false and the
//  TTS factory falls back to LocalTTSClient (AVSpeechSynthesizer).
//
//  To enable: in Xcode, File → Add Package Dependencies… → paste
//  https://github.com/microsoft/onnxruntime-swift-package-manager →
//  add `onnxruntime` to the leanring-buddy target. See SETUP_OFFLINE.md.
//
//  Public API matches LocalTTSClient (`speakText`, `isPlaying`, `stopPlayback`)
//  so CompanionManager doesn't care which implementation is active.
//

import AVFoundation
import Foundation

#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings
#endif

@MainActor
final class KokoroTTSClient: NSObject {
    /// Which Kokoro voice to use. "af_heart" is the default American Female
    /// voice with the cleanest output in the v1.0 release. Other options
    /// include "am_michael", "bf_emma", "bm_george", etc. See
    /// https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/tree/main/voices
    nonisolated static let defaultVoiceName: String = "af_heart"

    /// Kokoro outputs audio at this sample rate. Fed straight to AVAudioEngine.
    nonisolated static let kokoroOutputSampleRateHz: Double = 24_000

    private let phonemizer = KokoroPhonemizer()
    private let assetDownloader = KokoroAssetDownloader()
    private var voiceStyleEmbedding: [Float]?
    private let voiceName: String

    private(set) var isPlaying: Bool = false
    private var currentAudioPlayer: AVAudioPlayer?
    private var modelInitializationTask: Task<Void, Error>?

    /// Reports `true` once the Kokoro model has been downloaded and the
    /// ONNX Runtime session is loaded. Callers should check this before
    /// using `speakText`; if false, they should fall back to LocalTTSClient.
    private(set) var isReady: Bool = false

    #if canImport(OnnxRuntimeBindings)
    private var ortEnvironment: ORTEnv?
    private var ortInferenceSession: ORTSession?
    #endif

    init(voiceName: String = KokoroTTSClient.defaultVoiceName) {
        self.voiceName = voiceName
        super.init()
        // Start initializing on creation — by the time the user holds
        // push-to-talk for the first time, the model is usually warm.
        modelInitializationTask = Task { try await self.initializeModelAndVoice() }
    }

    /// Synthesizes `text` to audio via Kokoro and plays it back. Throws if
    /// the model isn't ready or any pipeline step fails. The caller should
    /// catch and fall back to LocalTTSClient on failure.
    func speakText(_ text: String) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        // Wait for one-time init if it hasn't finished yet.
        try await modelInitializationTask?.value

        let phonemeString = try await phonemizer.phonemize(text: trimmedText)
        let phonemeTokenIds = KokoroTokenizer.tokenize(phonemeString: phonemeString)
        guard phonemeTokenIds.count > 2 else {
            // Empty phoneme output (e.g., text was just punctuation).
            return
        }

        let audioSamples = try runKokoroInference(phonemeTokenIds: phonemeTokenIds)
        try playAudioSamples(audioSamples)
    }

    func stopPlayback() {
        currentAudioPlayer?.stop()
        currentAudioPlayer = nil
        isPlaying = false
    }

    // MARK: - Initialization

    private func initializeModelAndVoice() async throws {
        #if canImport(OnnxRuntimeBindings)
        let modelFileURL = try await assetDownloader.localFileURLForAsset(.quantizedONNXModel)
        let voiceFileURL = try await assetDownloader.localFileURLForAsset(
            .voiceStyleEmbedding(voiceName: voiceName)
        )

        // Load the voice embedding into memory. The file is a flat array of
        // float32 values shaped [510, 1, 256] — one 256-d style vector per
        // possible token sequence length, indexed at runtime by len(tokens) - 1.
        let voiceFileData = try Data(contentsOf: voiceFileURL)
        let voiceFloats: [Float] = voiceFileData.withUnsafeBytes { rawBufferPointer in
            let floatPointer = rawBufferPointer.bindMemory(to: Float.self)
            return Array(floatPointer)
        }

        try await phonemizer.loadDictionaryIfNeeded()

        let environment = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
        let sessionOptions = try ORTSessionOptions()
        try sessionOptions.setIntraOpNumThreads(2)
        let inferenceSession = try ORTSession(
            env: environment,
            modelPath: modelFileURL.path,
            sessionOptions: sessionOptions
        )

        self.ortEnvironment = environment
        self.ortInferenceSession = inferenceSession
        self.voiceStyleEmbedding = voiceFloats
        self.isReady = true
        print("🎤 KokoroTTS: ready (voice: \(voiceName), model: model_quantized.onnx)")
        #else
        throw NSError(domain: "KokoroTTSClient", code: -2, userInfo: [
            NSLocalizedDescriptionKey: "ONNX Runtime Swift Package not added to the project. See SETUP_OFFLINE.md."
        ])
        #endif
    }

    // MARK: - Inference

    private func runKokoroInference(phonemeTokenIds: [Int64]) throws -> [Float] {
        #if canImport(OnnxRuntimeBindings)
        guard let inferenceSession = ortInferenceSession else {
            throw NSError(domain: "KokoroTTSClient", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "Kokoro session not initialized"
            ])
        }
        guard let voiceStyleEmbedding else {
            throw NSError(domain: "KokoroTTSClient", code: -4, userInfo: [
                NSLocalizedDescriptionKey: "Voice style embedding not loaded"
            ])
        }

        // The voice file is [510, 1, 256]. We pick the row matching our
        // token count (minus 1 because tokens include leading/trailing 0s
        // but the embedding index is 0-based on inner content length).
        let voiceEmbeddingRowIndex = max(0, min(phonemeTokenIds.count - 1, 509))
        let styleVectorStartIndex = voiceEmbeddingRowIndex * 256
        let styleVectorEndIndex = styleVectorStartIndex + 256
        guard styleVectorEndIndex <= voiceStyleEmbedding.count else {
            throw NSError(domain: "KokoroTTSClient", code: -5, userInfo: [
                NSLocalizedDescriptionKey: "Voice embedding too small for token count"
            ])
        }
        let styleVectorForThisLength = Array(voiceStyleEmbedding[styleVectorStartIndex..<styleVectorEndIndex])

        // Build the three input tensors Kokoro expects.
        let tokensTensor = try makeInt64Tensor(
            values: phonemeTokenIds,
            shape: [1, NSNumber(value: phonemeTokenIds.count)]
        )
        let styleTensor = try makeFloatTensor(
            values: styleVectorForThisLength,
            shape: [1, 256]
        )
        let speedTensor = try makeFloatTensor(values: [1.0], shape: [1])

        let modelInputs: [String: ORTValue] = [
            "input_ids": tokensTensor,
            "style": styleTensor,
            "speed": speedTensor
        ]

        let outputTensors = try inferenceSession.run(
            withInputs: modelInputs,
            outputNames: Set(["waveform"]),
            runOptions: nil
        )

        guard let audioOutputTensor = outputTensors["waveform"] else {
            throw NSError(domain: "KokoroTTSClient", code: -6, userInfo: [
                NSLocalizedDescriptionKey: "Kokoro model returned no waveform output"
            ])
        }
        return try extractFloatArray(fromTensor: audioOutputTensor)
        #else
        throw NSError(domain: "KokoroTTSClient", code: -7, userInfo: [
            NSLocalizedDescriptionKey: "ONNX Runtime not available"
        ])
        #endif
    }

    #if canImport(OnnxRuntimeBindings)
    private func makeInt64Tensor(values: [Int64], shape: [NSNumber]) throws -> ORTValue {
        var mutableValues = values
        let tensorByteCount = mutableValues.count * MemoryLayout<Int64>.stride
        let tensorData = NSMutableData(bytes: &mutableValues, length: tensorByteCount)
        return try ORTValue(
            tensorData: tensorData,
            elementType: ORTTensorElementDataType.int64,
            shape: shape
        )
    }

    private func makeFloatTensor(values: [Float], shape: [NSNumber]) throws -> ORTValue {
        var mutableValues = values
        let tensorByteCount = mutableValues.count * MemoryLayout<Float>.stride
        let tensorData = NSMutableData(bytes: &mutableValues, length: tensorByteCount)
        return try ORTValue(
            tensorData: tensorData,
            elementType: ORTTensorElementDataType.float,
            shape: shape
        )
    }

    private func extractFloatArray(fromTensor tensor: ORTValue) throws -> [Float] {
        let tensorData = try tensor.tensorData() as Data
        return tensorData.withUnsafeBytes { rawBufferPointer in
            let floatPointer = rawBufferPointer.bindMemory(to: Float.self)
            return Array(floatPointer)
        }
    }
    #endif

    // MARK: - Audio playback

    private func playAudioSamples(_ audioSamples: [Float]) throws {
        // Convert Float PCM [-1, 1] → Int16 PCM, wrap in a WAV header, hand
        // to AVAudioPlayer. Easier than wiring up AVAudioEngine for a
        // one-shot playback. Reuses the existing WAV builder for parity
        // with WhisperKitTranscriptionProvider's path.
        let scaledInt16Samples = audioSamples.map { sample -> Int16 in
            let clampedSample = max(-1.0, min(1.0, sample))
            return Int16(clampedSample * Float(Int16.max))
        }

        let pcm16AudioData = scaledInt16Samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let wavAudioData = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: pcm16AudioData,
            sampleRate: Int(Self.kokoroOutputSampleRateHz)
        )

        let audioPlayer = try AVAudioPlayer(data: wavAudioData)
        audioPlayer.delegate = self
        currentAudioPlayer = audioPlayer
        isPlaying = true
        audioPlayer.play()
        print("🔊 KokoroTTS: playing \(audioSamples.count) samples (~\(Int(Double(audioSamples.count) / Self.kokoroOutputSampleRateHz * 1000))ms)")
    }
}

extension KokoroTTSClient: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentAudioPlayer = nil
        }
    }
}
