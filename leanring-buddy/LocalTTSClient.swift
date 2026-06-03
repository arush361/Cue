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
final class LocalTTSClient: NSObject, BuddyTTSClient {
    private let speechSynthesizer = AVSpeechSynthesizer()

    /// True between the moment we call `speak()` and the moment the
    /// synthesizer reports `didFinish`. Mirrors the ElevenLabs client's
    /// `isPlaying` property so the existing transient-cursor logic in
    /// CompanionManager keeps working unchanged.
    private(set) var isPlaying: Bool = false

    /// LocalTTSClient is always ready — AVSpeechSynthesizer is in the OS,
    /// no model download required. Conforms to BuddyTTSClient.
    let isReady: Bool = true

    /// The highest-quality English voice available on this machine. Resolved
    /// once at init time and reused — voice listing is non-trivial work and
    /// we don't want to redo it for every utterance.
    private let bestAvailableSpeechVoice: AVSpeechSynthesisVoice?

    /// User-picked voice identifier from the menu bar panel. `nil` means
    /// fall back to `bestAvailableSpeechVoice`. Settable so the picker
    /// can swap voices live; lookups happen per-utterance so the value
    /// always reflects the latest selection.
    var preferredVoiceIdentifier: String? = nil

    /// The voice each new utterance should use — preferred (if installed)
    /// or the auto-picked best.
    private var resolvedVoice: AVSpeechSynthesisVoice? {
        if let id = preferredVoiceIdentifier, let v = AVSpeechSynthesisVoice(identifier: id) {
            return v
        }
        return bestAvailableSpeechVoice
    }

    override init() {
        self.bestAvailableSpeechVoice = Self.findBestAvailableEnglishVoice()
        super.init()
        speechSynthesizer.delegate = self
        if let bestAvailableSpeechVoice {
            print("🔊 LocalTTS: using voice \"\(bestAvailableSpeechVoice.name)\" (quality: \(Self.qualityDescription(bestAvailableSpeechVoice.quality))) — id: \(bestAvailableSpeechVoice.identifier)")
        } else {
            print("⚠️ LocalTTS: no English voice found, using system default")
        }
        // One-shot inventory so we can see what else is installed in case
        // we want to pick a different voice later. Quality is sorted desc;
        // anything above .default tier is worth trying.
        Self.logInstalledEnglishVoices()
    }

    /// Speaks `text` through AVSpeechSynthesizer. Returns once playback has
    /// started (matching the ElevenLabsTTSClient contract — the caller can
    /// then watch `isPlaying` to know when playback has finished).
    func speakText(_ text: String) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let speechUtterance = AVSpeechUtterance(string: trimmedText)
        speechUtterance.voice = resolvedVoice
        // Slightly SLOWER than default for warmth — fast AVSpeech amplifies
        // its robotic-ness; a small drop reads as more natural / human.
        speechUtterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        // Lower pitch slightly to soften the voice. 1.0 reads flat and
        // computery; 0.96 reads measured and conversational. The valid
        // range is 0.5...2.0, but stay within 0.95-1.05 to avoid
        // dipping into the uncanny / cartoonish bands.
        speechUtterance.pitchMultiplier = 0.96
        speechUtterance.volume = 1.0
        // Add a small pre-utterance silence so back-to-back sentences in
        // the streaming-TTS queue don't run into each other.
        speechUtterance.preUtteranceDelay = 0.08
        speechUtterance.postUtteranceDelay = 0.05

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
    /// On macOS 26+, prefers Personal Voice / neural voices first (identified
    /// by Apple's voice identifier convention). Otherwise: prefers `.premium`
    /// voices (downloadable from System Settings → Accessibility → Spoken
    /// Content), then `.enhanced`, then anything else. Within a quality tier,
    /// prefers en-US, then en-GB, then any other English locale.
    private static func findBestAvailableEnglishVoice() -> AVSpeechSynthesisVoice? {
        let allInstalledVoices = AVSpeechSynthesisVoice.speechVoices()
        let englishVoices = allInstalledVoices.filter { $0.language.hasPrefix("en") }

        let preferredLanguageOrder = ["en-US", "en-GB", "en-AU", "en-IE", "en-IN"]

        func languageRank(forVoice voice: AVSpeechSynthesisVoice) -> Int {
            preferredLanguageOrder.firstIndex(of: voice.language) ?? preferredLanguageOrder.count
        }

        /// On macOS 26+, Apple ships richer neural voices and (optionally)
        /// Personal Voice. Identifier substrings that should rank first.
        /// Falls back to quality-tier ranking when no special voice matches.
        func neuralOrPersonalVoiceRank(forVoice voice: AVSpeechSynthesisVoice) -> Int {
            let identifier = voice.identifier.lowercased()
            if identifier.contains("personalvoice") { return 0 }
            if identifier.contains("neural") { return 1 }
            return 2
        }

        func qualityRank(forVoice voice: AVSpeechSynthesisVoice) -> Int {
            switch voice.quality {
            case .premium: return 0
            case .enhanced: return 1
            case .default: return 2
            @unknown default: return 3
            }
        }

        let isMacOS26OrLater: Bool = {
            if #available(macOS 26.0, *) { return true }
            return false
        }()

        return englishVoices.min { firstVoice, secondVoice in
            // On macOS 26+, prefer Personal Voice / neural voices first.
            if isMacOS26OrLater {
                let firstNeural = neuralOrPersonalVoiceRank(forVoice: firstVoice)
                let secondNeural = neuralOrPersonalVoiceRank(forVoice: secondVoice)
                if firstNeural != secondNeural { return firstNeural < secondNeural }
            }
            let firstQualityRank = qualityRank(forVoice: firstVoice)
            let secondQualityRank = qualityRank(forVoice: secondVoice)
            if firstQualityRank != secondQualityRank {
                return firstQualityRank < secondQualityRank
            }
            return languageRank(forVoice: firstVoice) < languageRank(forVoice: secondVoice)
        }
    }

    static func qualityDescription(_ voiceQuality: AVSpeechSynthesisVoiceQuality) -> String {
        switch voiceQuality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        case .default: return "Default"
        @unknown default: return "Unknown"
        }
    }

    /// Installed English voices above .default tier, sorted Premium →
    /// Enhanced → (then by language preference). Used by the panel's
    /// voice picker. Excludes legacy .default voices (they're robotic).
    static func installedSelectableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .filter { $0.quality != .default }
            .sorted { a, b in
                if a.quality.rawValue != b.quality.rawValue {
                    return a.quality.rawValue > b.quality.rawValue
                }
                return a.name < b.name
            }
    }

    /// Human-readable display name for the picker:
    /// "Ava (Premium · en-US)".
    static func displayName(for voice: AVSpeechSynthesisVoice) -> String {
        "\(voice.name) (\(qualityDescription(voice.quality)) · \(voice.language))"
    }

    /// Diagnostic dump of installed English voices above .default tier
    /// so we can see what alternatives are available if the current
    /// pick sounds robotic. Logged once at init.
    private static func logInstalledEnglishVoices() {
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .filter { $0.quality != .default }
            .sorted { (a, b) -> Bool in
                if a.quality.rawValue != b.quality.rawValue {
                    return a.quality.rawValue > b.quality.rawValue
                }
                return a.language < b.language
            }
        if voices.isEmpty {
            print("🔊 LocalTTS: no Premium/Enhanced English voices installed. Add some in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.")
            return
        }
        print("🔊 LocalTTS: installed Premium/Enhanced English voices (\(voices.count)):")
        for voice in voices {
            print("    \(qualityDescription(voice.quality).padding(toLength: 8, withPad: " ", startingAt: 0)) \(voice.language)  \(voice.name)  — id: \(voice.identifier)")
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
