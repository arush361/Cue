//
//  LocalTTSClient.swift
//  leanring-buddy
//
//  Fully on-device text-to-speech using AVSpeechSynthesizer. Picks the
//  best available English voice on the system (Premium > Enhanced > Default)
//  so quality is meaningfully better than the legacy NSSpeechSynthesizer
//  used by the response-error fallback.
//
//  This is the offline replacement for ElevenLabsTTSClient. Public API
//  matches deliberately (`speakText`, `isPlaying`, `stopPlayback`) so
//  CompanionManager's call sites don't change.
//
//  Future upgrade path: replace this with a neural TTS model (Kokoro-82M
//  via ONNX Runtime Swift, or MLX-Swift if/when Kokoro support lands there)
//  if higher voice quality is needed. The on-device user-experience contract
//  doesn't change.
//

import AVFoundation
import Foundation

@MainActor
final class LocalTTSClient: NSObject {
    private let speechSynthesizer = AVSpeechSynthesizer()

    /// True between the moment we call `speak()` and the moment the
    /// synthesizer reports `didFinish`. Mirrors the ElevenLabs client's
    /// `isPlaying` property so the existing transient-cursor logic in
    /// CompanionManager keeps working unchanged.
    private(set) var isPlaying: Bool = false

    /// The highest-quality English voice available on this machine. Resolved
    /// once at init time and reused — voice listing is non-trivial work and
    /// we don't want to redo it for every utterance.
    private let bestAvailableSpeechVoice: AVSpeechSynthesisVoice?

    override init() {
        self.bestAvailableSpeechVoice = Self.findBestAvailableEnglishVoice()
        super.init()
        speechSynthesizer.delegate = self
        if let bestAvailableSpeechVoice {
            print("🔊 LocalTTS: using voice \"\(bestAvailableSpeechVoice.name)\" (quality: \(Self.qualityDescription(bestAvailableSpeechVoice.quality)))")
        } else {
            print("⚠️ LocalTTS: no English voice found, using system default")
        }
    }

    /// Speaks `text` through AVSpeechSynthesizer. Returns once playback has
    /// started (matching the ElevenLabsTTSClient contract — the caller can
    /// then watch `isPlaying` to know when playback has finished).
    func speakText(_ text: String) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let speechUtterance = AVSpeechUtterance(string: trimmedText)
        speechUtterance.voice = bestAvailableSpeechVoice
        // Slightly faster than the default rate to feel snappier as a companion.
        speechUtterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        speechUtterance.pitchMultiplier = 1.0
        speechUtterance.volume = 1.0

        isPlaying = true
        speechSynthesizer.speak(speechUtterance)
        print("🔊 LocalTTS: speaking \(trimmedText.count) chars")
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        isPlaying = false
    }

    /// Picks the highest-quality English voice installed on the system.
    /// Prefers `.premium` voices (downloadable from System Settings → Accessibility →
    /// Spoken Content), then `.enhanced`, then anything else. Within a quality
    /// tier, prefers en-US, then en-GB, then any other English locale.
    private static func findBestAvailableEnglishVoice() -> AVSpeechSynthesisVoice? {
        let allInstalledVoices = AVSpeechSynthesisVoice.speechVoices()
        let englishVoices = allInstalledVoices.filter { $0.language.hasPrefix("en") }

        let preferredLanguageOrder = ["en-US", "en-GB", "en-AU", "en-IE", "en-IN"]

        func languageRank(forVoice voice: AVSpeechSynthesisVoice) -> Int {
            preferredLanguageOrder.firstIndex(of: voice.language) ?? preferredLanguageOrder.count
        }

        func qualityRank(forVoice voice: AVSpeechSynthesisVoice) -> Int {
            // Higher quality should sort earlier — invert by subtracting from a constant.
            switch voice.quality {
            case .premium: return 0
            case .enhanced: return 1
            case .default: return 2
            @unknown default: return 3
            }
        }

        return englishVoices.min { firstVoice, secondVoice in
            let firstQualityRank = qualityRank(forVoice: firstVoice)
            let secondQualityRank = qualityRank(forVoice: secondVoice)
            if firstQualityRank != secondQualityRank {
                return firstQualityRank < secondQualityRank
            }
            return languageRank(forVoice: firstVoice) < languageRank(forVoice: secondVoice)
        }
    }

    private static func qualityDescription(_ voiceQuality: AVSpeechSynthesisVoiceQuality) -> String {
        switch voiceQuality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        case .default: return "Default"
        @unknown default: return "Unknown"
        }
    }
}

extension LocalTTSClient: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.isPlaying = false }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.isPlaying = false }
    }
}
