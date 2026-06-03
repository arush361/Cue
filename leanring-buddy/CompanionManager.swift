//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

/// The four cursor colors the user can pick from in the menu bar panel.
/// `blue` is the historical default that matches the original upstream
/// look. The other three give the cursor a more personal feel without
/// drifting off-brand.
enum CompanionCursorColor: String, CaseIterable {
    case blue
    case purple
    case green
    case pink

    /// SwiftUI Color used to render the cursor, response bubble dot,
    /// waveform, and spinner. Hex values picked to read well on both
    /// light and dark wallpapers.
    var swiftUIColor: Color {
        switch self {
        case .blue:   return Color(hex: "#3380FF")
        case .purple: return Color(hex: "#A463F2")
        case .green:  return Color(hex: "#34C759")
        case .pink:   return Color(hex: "#FF375F")
        }
    }

    /// Short human-readable name, used by VoiceOver / tooltips on the
    /// color picker swatches.
    var displayName: String {
        switch self {
        case .blue:   return "Blue"
        case .purple: return "Purple"
        case .green:  return "Green"
        case .pink:   return "Pink"
        }
    }
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Base URL for the Cloudflare Worker proxy. Used only as a fallback
    /// when ANTHROPIC_API_KEY isn't provided via environment variable.
    /// See README "Setup" section for both paths.
    private static let workerBaseURL = "http://localhost:8787"

    /// Claude API client. Priority: Keychain-saved key (set via the menu
    /// bar panel's API Key row) → ANTHROPIC_API_KEY environment variable
    /// (Xcode scheme Run > Arguments) → Cloudflare Worker proxy fallback.
    ///
    /// Implicitly-unwrapped because `start()` is responsible for
    /// constructing this exactly once via `rebuildClaudeAPI()`. We avoid
    /// initializing a throwaway proxy-mode instance at property-init
    /// time because ClaudeAPI fires a TLS-warmup HEAD on init — and a
    /// stub instance would hit localhost:8787 (the proxy fallback URL)
    /// before the real key is loaded, polluting the console with a
    /// connection-refused / timeout error.
    ///
    /// Re-created whenever the user saves or clears their key.
    private var claudeAPI: ClaudeAPI!

    /// True iff the user has saved a key in Keychain via the panel UI.
    /// The panel binds against this to swap between "Add API key" and
    /// "Replace / Clear" states.
    @Published private(set) var hasSavedAnthropicAPIKey: Bool = AnthropicAPIKeychain.hasSavedKey

    /// Last 4 characters of the saved key, e.g. "abcd". Surfaced in the
    /// UI as "sk-ant-…abcd" so users can recognize which key is loaded
    /// without ever seeing the full value.
    @Published private(set) var savedAnthropicAPIKeyLastFour: String? = AnthropicAPIKeychain.savedKeyLastFour

    /// Save (or replace) the Anthropic API key. Rebuilds the ClaudeAPI
    /// client so the next push-to-talk uses the new key immediately —
    /// no app restart needed.
    @discardableResult
    func saveAnthropicAPIKey(_ apiKey: String) -> Bool {
        let success = AnthropicAPIKeychain.save(apiKey)
        if success {
            hasSavedAnthropicAPIKey = AnthropicAPIKeychain.hasSavedKey
            savedAnthropicAPIKeyLastFour = AnthropicAPIKeychain.savedKeyLastFour
            rebuildClaudeAPI()
        }
        return success
    }

    /// Remove the saved Anthropic API key. The app falls back to the env
    /// var or proxy on the next push-to-talk.
    func clearSavedAnthropicAPIKey() {
        AnthropicAPIKeychain.clear()
        hasSavedAnthropicAPIKey = false
        savedAnthropicAPIKeyLastFour = nil
        rebuildClaudeAPI()
    }

    /// Rebuilds `claudeAPI` from the current state (Keychain → env →
    /// proxy). Called at init and whenever the user changes their key.
    private func rebuildClaudeAPI() {
        if let savedKey = AnthropicAPIKeychain.load(), !savedKey.isEmpty {
            print("🌐 Claude API: direct mode (Keychain)")
            claudeAPI = ClaudeAPI(directAnthropicAPIKey: savedKey, model: selectedModel)
            return
        }
        if let anthropicAPIKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
           !anthropicAPIKey.isEmpty {
            print("🌐 Claude API: direct mode (env var ANTHROPIC_API_KEY)")
            claudeAPI = ClaudeAPI(directAnthropicAPIKey: anthropicAPIKey, model: selectedModel)
            return
        }
        print("🌐 Claude API: proxy mode (fallback to \(Self.workerBaseURL))")
        claudeAPI = ClaudeAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: selectedModel)
    }

    /// Primary on-device TTS: Kokoro-82M v1.0 via ONNX Runtime. Higher
    /// quality than AVSpeechSynthesizer but depends on the ONNX Runtime
    /// Swift package being added to the Xcode target. If the model isn't
    /// ready (still downloading, or ONNX Runtime not wired up), calls fall
    /// through to `localTTSClient` automatically. See KokoroTTSClient.swift
    /// and SETUP_OFFLINE.md.
    private lazy var kokoroTTSClient: KokoroTTSClient = {
        return KokoroTTSClient()
    }()

    /// Fallback TTS using Apple's AVSpeechSynthesizer with the best
    /// installed system voice. Always available, no dependencies.
    /// See LocalTTSClient.swift.
    private lazy var localTTSClient: LocalTTSClient = {
        let client = LocalTTSClient()
        // Seed with the user's saved voice pick if any. nil → keep
        // the auto-pick best-available voice the client chose at init.
        client.preferredVoiceIdentifier = selectedTTSVoiceIdentifier
        return client
    }()

    /// Whether the user's voice responses are currently playing back
    /// through either TTS engine. Mirrors the old `isPlaying` semantics
    /// so the transient-cursor logic doesn't change.
    /// True while EITHER on-device TTS engine is currently playing audio
    /// (Kokoro or the AVSpeechSynthesizer fallback). Exposed package-wide
    /// so the response side panel can observe TTS completion without
    /// needing direct references to both clients.
    var isAnyTTSPlaying: Bool {
        ttsClientsInPreferenceOrder.contains { $0.isPlaying }
    }

    /// TTS engines in preference order. Each conforms to `BuddyTTSClient`.
    /// First ready engine wins; if it throws, we fall through to the next.
    ///
    /// LocalTTSClient (AVSpeechSynthesizer w/ best installed Premium
    /// voice, e.g. Ava) is primary because synthesis is essentially
    /// instant — it starts speaking the moment a sentence is queued.
    /// Kokoro (neural, higher voice quality but ~1-2s of CPU-bound
    /// synthesis per sentence) is the fallback. Adding a new engine
    /// just means dropping it into this list.
    private var ttsClientsInPreferenceOrder: [any BuddyTTSClient] {
        [localTTSClient, kokoroTTSClient]
    }

    /// Speaks `text` through the first ready engine in
    /// `ttsClientsInPreferenceOrder`. Falls through on error.
    private func speakResponseThroughBestAvailableTTS(_ text: String) async {
        for client in ttsClientsInPreferenceOrder where client.isReady {
            do {
                try await client.speakText(text)
                return
            } catch {
                print("⚠️ TTS \(type(of: client)) failed, falling through: \(error.localizedDescription)")
            }
        }
        print("⚠️ All TTS engines failed or unready — no audio for this response.")
    }

    /// Stops any TTS playback from every registered engine.
    private func stopAllTTSPlayback() {
        for client in ttsClientsInPreferenceOrder {
            client.stopPlayback()
        }
    }

    /// Stops any currently-playing TTS audio. Exposed publicly so the
    /// response side panel's mute button can silence Cue mid-response.
    /// Doesn't affect the streamed text on screen — only the audio.
    /// Also tears down the streaming-TTS queue so any pending sentences
    /// don't sneak through after the mute.
    func muteCurrentTTSPlayback() {
        resetStreamingTTS()
        stopAllTTSPlayback()
    }

    /// Full barge-in teardown: cancel the in-flight Claude response,
    /// invalidate any chunks still arriving from it (via the generation
    /// counter), and drain the TTS pipeline. Used when the user starts
    /// speaking again during a continuous session — their new utterance
    /// will fire a fresh Claude call once the next silence-flush hits.
    func cancelInFlightResponseForBargeIn() {
        currentResponseGeneration += 1
        currentResponseTask?.cancel()
        currentResponseTask = nil
        resetStreamingTTS()
        stopAllTTSPlayback()
        streamingResponseText = ""
        print("🛑 Barge-in: cancelled in-flight response (gen=\(currentResponseGeneration))")
    }

    // MARK: - Streaming TTS (speak sentences as they arrive)

    /// Character index in the most recent streaming response past which
    /// no sentence has been queued for TTS yet. Reset on every new ask.
    private var streamingTTSCursor: Int = 0

    /// Sentences waiting to be spoken in order. Mutated only on @MainActor.
    private var streamingTTSQueue: [String] = []

    /// Single consumer that drains `streamingTTSQueue` sequentially.
    /// Awaiting each `speakResponseThroughBestAvailableTTS` ensures
    /// sentence N finishes playing before sentence N+1 starts — no
    /// overlapping audio between engines.
    private var streamingTTSConsumer: Task<Void, Never>?

    /// Bumped every time a consumer starts and every time resetStreamingTTS
    /// runs. The consumer captures its starting gen; the tail-grace cleanup
    /// only un-mutes the mic + clears state if the gen still matches at
    /// wake-up. Prevents the OLD consumer's tail-grace from undoing the
    /// NEW consumer's mute (the bug that let Cue's TTS feed back into the
    /// transcriber).
    private var streamingTTSConsumerGeneration: Int = 0

    /// Min sentence length before we'll cut at a terminator. Prevents
    /// "Hi. there" from breaking after "Hi." which would feel choppy.
    private static let streamingTTSMinSentenceChars = 8

    /// Examine the cumulative streaming text, find any newly-complete
    /// sentences past `streamingTTSCursor`, append them to the queue,
    /// and start the consumer Task if it isn't already running.
    ///
    /// Called from the streaming text-chunk callback after `[POINT...]`
    /// stripping, so the buffer never sees the raw coordinate tag.
    private func enqueueStreamingTTSChunks(_ cumulative: String) {
        let cumulativeChars = Array(cumulative)
        var index = streamingTTSCursor
        var didEnqueue = false

        while index < cumulativeChars.count {
            guard let end = nextSentenceEnd(in: cumulativeChars, from: index) else { break }
            let sentenceChars = cumulativeChars[streamingTTSCursor...end]
            let sentence = String(sentenceChars).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                streamingTTSQueue.append(sentence)
                didEnqueue = true
            }
            streamingTTSCursor = end + 1
            index = streamingTTSCursor
        }

        // Only spawn the consumer when we actually appended a sentence.
        // The previous unconditional call spawned a fresh consumer for
        // every text chunk — visible in logs as gen=5, gen=6, gen=7
        // cycles for one response — and each spurious cycle held the
        // mic muted through its 500ms tail-grace.
        if didEnqueue {
            startStreamingTTSConsumerIfNeeded()
        }
    }

    /// On stream end, flush any trailing fragment that didn't end in a
    /// terminator (e.g. "...with rate limit tests").
    private func flushStreamingTTSFinalFragment(_ finalCleanedText: String) {
        let finalChars = Array(finalCleanedText)
        guard streamingTTSCursor < finalChars.count else {
            startStreamingTTSConsumerIfNeeded()
            return
        }
        let tail = String(finalChars[streamingTTSCursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
        streamingTTSCursor = finalChars.count
        if !tail.isEmpty {
            streamingTTSQueue.append(tail)
        }
        startStreamingTTSConsumerIfNeeded()
    }

    private func startStreamingTTSConsumerIfNeeded() {
        guard streamingTTSConsumer == nil else { return }
        streamingTTSConsumerGeneration += 1
        let myGen = streamingTTSConsumerGeneration
        streamingTTSConsumer = Task { @MainActor [weak self] in
            guard let self else { return }
            // Switch to .responding the moment the first audio is about
            // to play so the spinner doesn't sit on .processing during
            // the gap between text arriving and audio starting.
            if !self.streamingTTSQueue.isEmpty && self.voiceState == .processing {
                self.voiceState = .responding
            }
            // Mute the continuous-listening mic for the lifetime of
            // this consumer so the speakers' echo doesn't get
            // transcribed as a fresh user utterance.
            self.buddyDictationManager.isMicMutedForOwnTTSPlayback = true
            print("🔇 Mic muted for own TTS (gen=\(myGen))")
            while !Task.isCancelled, let sentence = self.streamingTTSQueue.first {
                self.streamingTTSQueue.removeFirst()
                await self.speakResponseThroughBestAvailableTTS(sentence)
            }
            // Tail grace — speakers can echo for several hundred ms
            // after playback returns; keep the mic muted across that
            // window so we don't pick up the trailing audio. 500ms is
            // empirically safe on this hardware.
            try? await Task.sleep(nanoseconds: 500_000_000)
            // Only un-mute if we're still the active consumer. A
            // resetStreamingTTS (barge-in or new ask) bumps the
            // generation; in that case the new consumer owns the
            // flag and our tail must not touch it.
            guard self.streamingTTSConsumerGeneration == myGen else {
                print("🔁 Stale consumer (gen=\(myGen), current=\(self.streamingTTSConsumerGeneration)) — leaving mute alone")
                return
            }
            self.buddyDictationManager.isMicMutedForOwnTTSPlayback = false
            self.streamingTTSConsumer = nil
            print("🔊 Mic un-muted after TTS (gen=\(myGen))")
        }
    }

    /// Tear down all streaming-TTS state. Called on new push-to-talk, on
    /// mute, and on panel close so a follow-up doesn't inherit half-spoken
    /// sentences from the prior response.
    private func resetStreamingTTS() {
        streamingTTSConsumer?.cancel()
        streamingTTSConsumer = nil
        streamingTTSQueue.removeAll(keepingCapacity: true)
        streamingTTSCursor = 0
        // Invalidate any tail-grace sleeping inside the old consumer
        // so it doesn't wake up and un-mute the mic after the new
        // consumer has already taken over.
        streamingTTSConsumerGeneration += 1
        // Open the mic immediately on cancel/barge-in. If we leave the
        // mute on, the continuous-listening session would miss the
        // first ~300ms of the user's new utterance. A new consumer
        // (if one is about to start) will re-mute within ~10ms.
        buddyDictationManager.isMicMutedForOwnTTSPlayback = false
    }

    // MARK: - Continuous-listening session
    //
    // Entered by pressing Command + Control together (the shortcut
    // monitor watches for the [.command, .control] combo as a
    // standalone modifier press and emits .continuousSessionToggle on
    // 0→1 transitions). While active, the mic stays open across
    // multiple utterances; SpeechDetector segments speech via VAD and
    // each segment is sent to Claude as if it were a normal PTT
    // exchange. Exits on:
    //   1) another Cmd+Ctrl press (.continuousSessionToggle while active)
    //   2) the max-duration timer firing (default 10 min)
    //   3) the user clicking the menu-bar header or on-screen stop button
    //   4) a fatal error from the session

    /// User-visible session state for the menu-bar countdown + cursor
    /// indicator. SwiftUI binds against these.
    @Published private(set) var isContinuousSessionActive: Bool = false
    @Published private(set) var continuousSessionEndsAt: Date?

    /// Hard cap on a single continuous session. Acts as cost / safety
    /// guardrail in case the user forgets to exit. Default 10 minutes;
    /// adjustable as a follow-up via the menu-bar panel if desired.
    private static let continuousSessionMaxDurationSeconds: TimeInterval = 600

    /// Reasons the session ended — surfaced in logs for diagnostics.
    enum ContinuousSessionExitReason: String {
        case shortcut        // Cmd+Ctrl pressed again while active
        case timeout
        case manual          // menu-bar indicator or on-screen stop button click
        case error
    }

    private var continuousSessionTimeoutTask: Task<Void, Never>?

    func enterContinuousSession() {
        guard !isContinuousSessionActive else { return }

        // Tear down any in-flight PTT response state first — entering
        // continuous mode mid-response would otherwise create a weird
        // hybrid where the old response is still streaming. Bump the
        // generation so any chunks still arriving from that cancelled
        // call are dropped instead of leaking into the new session.
        currentResponseGeneration += 1
        currentResponseTask?.cancel()
        resetStreamingTTS()
        stopAllTTSPlayback()
        streamingResponseText = ""

        let endsAt = Date().addingTimeInterval(Self.continuousSessionMaxDurationSeconds)
        isContinuousSessionActive = true
        continuousSessionEndsAt = endsAt
        print("🎤 Continuous session: started (timeout \(Int(Self.continuousSessionMaxDurationSeconds))s)")

        // Floating top-right stop button on every screen. Visible until
        // exitContinuousSession tears it down. The cursor overlay is
        // click-through; this window isn't, so the user can click
        // "stop" anywhere even with Cue's panel closed.
        overlayWindowManager.showContinuousSessionStopButton(
            onScreens: NSScreen.screens,
            companionManager: self
        )

        // Schedule the safety timeout. The Task sleeps for the cap,
        // then exits the session on the main actor. exitContinuousSession
        // cancels this task on every other exit reason.
        continuousSessionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.continuousSessionMaxDurationSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.exitContinuousSession(reason: .timeout)
            }
        }

        // Hand off to the dictation manager to actually open the mic.
        // The dictation manager subscribes to the session's callbacks
        // and forwards each finalized segment back here via
        // `sendTranscriptToClaudeWithScreenshot`.
        Task { @MainActor in
            await buddyDictationManager.startContinuousListening(
                onSegmentFinalized: { [weak self] segmentText in
                    Task { @MainActor in
                        guard let self else { return }
                        CueAnalytics.trackUserMessageSent(transcript: segmentText)
                        self.sendTranscriptToClaudeWithScreenshot(transcript: segmentText)
                    }
                },
                onSpeechStarted: { [weak self] in
                    Task { @MainActor in
                        // Barge-in: if Cue is mid-response when the user
                        // speaks again, cancel the Claude call AND drop
                        // any chunks still arriving from it AND drain
                        // TTS. The same continuous session keeps
                        // listening; the user's new utterance fires a
                        // fresh Claude call on the next silence-flush.
                        self?.cancelInFlightResponseForBargeIn()
                    }
                },
                onError: { [weak self] error in
                    Task { @MainActor in
                        print("⚠️ Continuous session error: \(error.localizedDescription)")
                        self?.exitContinuousSession(reason: .error)
                    }
                }
            )
        }
    }

    func exitContinuousSession(reason: ContinuousSessionExitReason) {
        guard isContinuousSessionActive else { return }
        print("🎤 Continuous session: ended (reason: \(reason.rawValue))")

        continuousSessionTimeoutTask?.cancel()
        continuousSessionTimeoutTask = nil
        isContinuousSessionActive = false
        continuousSessionEndsAt = nil

        // Remove the floating top-right stop button.
        overlayWindowManager.hideContinuousSessionStopButton()

        // Tear down the mic + analyzer.
        buddyDictationManager.stopContinuousListening()

        // Don't kill in-flight TTS for clean exits — user might want to
        // hear the last response finish. For errors, take everything down.
        if reason == .error {
            currentResponseTask?.cancel()
            resetStreamingTTS()
            stopAllTTSPlayback()
        }
    }

    /// Find the next sentence-end index >= `from`, requiring the
    /// sentence to be at least `streamingTTSMinSentenceChars` long and
    /// the terminator to be followed by whitespace or end-of-input
    /// (so "Mr. Smith" doesn't cut after "Mr.").
    /// Also splits on `\n\n`.
    private func nextSentenceEnd(in chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            let ch = chars[i]
            // Paragraph break — split before the second newline.
            if ch == "\n", i + 1 < chars.count, chars[i + 1] == "\n",
               (i - start) >= Self.streamingTTSMinSentenceChars {
                return i
            }
            if (ch == "." || ch == "!" || ch == "?"),
               (i - start) >= Self.streamingTTSMinSentenceChars {
                // Terminator must be followed by whitespace or end.
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                if next == " " || next == "\n" || next == "\t" || i + 1 >= chars.count {
                    return i
                }
            }
            i += 1
        }
        return nil
    }

    /// Re-speaks the latest assistant response from the beginning. Used
    /// by the response panel's "unmute" action to play the audio again
    /// after the user has muted it. No-op if there's no response yet.
    func replayCurrentResponseTTS() {
        let textToReplay = streamingResponseText
        guard !textToReplay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        // Stop anything in flight so the replay starts cleanly.
        stopAllTTSPlayback()
        Task { await speakResponseThroughBestAvailableTTS(textToReplay) }
    }

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    /// Bumped every time we start a new response and every time we
    /// barge-in cancel an in-flight one. The onTextChunk callback
    /// captures its starting generation; any chunk arriving with a
    /// stale generation is dropped (ClaudeAPI doesn't honor Task
    /// cancellation, so post-cancel chunks would otherwise still
    /// re-fill the TTS pipeline).
    private var currentResponseGeneration: Int = 0

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-sonnet-4-6"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = model
    }

    /// The AVSpeechSynthesisVoice identifier the user picked in the menu
    /// bar panel. `nil` means "use the auto-pick best installed voice"
    /// (LocalTTSClient.findBestAvailableEnglishVoice). Persisted to
    /// UserDefaults.
    @Published var selectedTTSVoiceIdentifier: String? =
        UserDefaults.standard.string(forKey: "selectedTTSVoiceIdentifier")

    func setSelectedTTSVoice(identifier: String?) {
        selectedTTSVoiceIdentifier = identifier
        if let identifier {
            UserDefaults.standard.set(identifier, forKey: "selectedTTSVoiceIdentifier")
        } else {
            UserDefaults.standard.removeObject(forKey: "selectedTTSVoiceIdentifier")
        }
        localTTSClient.preferredVoiceIdentifier = identifier
    }

    /// Stable unique ID of the microphone the user picked in the menu bar
    /// panel. `nil` means "follow the system default input device". Persisted
    /// to UserDefaults and applied to the dictation engine at launch and on
    /// every change.
    @Published var selectedMicrophoneDeviceUID: String? =
        UserDefaults.standard.string(forKey: "selectedMicrophoneDeviceUID")

    func setSelectedMicrophone(uniqueID: String?) {
        selectedMicrophoneDeviceUID = uniqueID
        if let uniqueID {
            UserDefaults.standard.set(uniqueID, forKey: "selectedMicrophoneDeviceUID")
        } else {
            UserDefaults.standard.removeObject(forKey: "selectedMicrophoneDeviceUID")
        }
        buddyDictationManager.setPreferredInputDeviceUniqueID(uniqueID)
    }

    /// User preference for whether the Cue cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    ///
    /// One-time migration: if the new "isCueCursorEnabled" key is absent
    /// but the legacy "isCueCursorEnabled" key exists (from earlier
    /// builds), we read the legacy value so users don't get their setting
    /// reset by the rename.
    @Published var isCueCursorEnabled: Bool = {
        let userDefaults = UserDefaults.standard
        if userDefaults.object(forKey: "isCueCursorEnabled") != nil {
            return userDefaults.bool(forKey: "isCueCursorEnabled")
        }
        return true
    }()

    func setCueCursorEnabled(_ enabled: Bool) {
        isCueCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isCueCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Live-streamed Claude response text. Updated chunk-by-chunk as the SSE
    /// stream from `/chat` arrives. Drives the right-side response panel
    /// (ResponseSidePanelView) so the user can read along while Cue speaks.
    /// Reset to empty on each new push-to-talk.
    @Published var streamingResponseText: String = ""

    /// Whether the right-side response panel should be visible right now.
    /// Owned by CompanionManager so any view can observe it; the actual
    /// NSPanel lifecycle is in ResponseSidePanelManager.
    @Published var isResponsePanelVisible: Bool = false

    /// User preference for whether the response side panel should appear
    /// at all. When false, Cue still speaks responses but no panel is shown.
    /// Persisted to UserDefaults.
    @Published var showResponseSidePanelPreference: Bool =
        UserDefaults.standard.object(forKey: "showResponseSidePanel") as? Bool ?? true

    func setShowResponseSidePanelPreference(_ enabled: Bool) {
        showResponseSidePanelPreference = enabled
        UserDefaults.standard.set(enabled, forKey: "showResponseSidePanel")
        // If the user just turned the panel off while it's showing, hide it.
        if !enabled {
            isResponsePanelVisible = false
        }
    }

    /// User preference for whether Claude is allowed to search the web
    /// when answering. When true, every chat request advertises the
    /// `web_search_20250305` server tool and Claude decides per-turn
    /// whether to invoke it (capped at 3 searches per response).
    /// Persisted to UserDefaults; default is on so general-knowledge
    /// questions get current answers out of the box.
    @Published var isWebSearchEnabled: Bool =
        UserDefaults.standard.object(forKey: "isWebSearchEnabled") as? Bool ?? true

    func setWebSearchEnabled(_ enabled: Bool) {
        isWebSearchEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isWebSearchEnabled")
    }

    /// User-selected cursor color. Drives the blue/purple/green/pink
    /// rendering of the triangle cursor, waveform, spinner, and
    /// element-arrival bubble. Persisted to UserDefaults via its raw
    /// String value; default is blue (the original upstream look).
    @Published var selectedCursorColor: CompanionCursorColor = {
        let storedRawValue = UserDefaults.standard.string(forKey: "selectedCursorColor")
        return storedRawValue.flatMap(CompanionCursorColor.init(rawValue:)) ?? .blue
    }()

    func setSelectedCursorColor(_ newCursorColor: CompanionCursorColor) {
        selectedCursorColor = newCursorColor
        UserDefaults.standard.set(newCursorColor.rawValue, forKey: "selectedCursorColor")
    }

    /// Convenience accessor returning the SwiftUI Color the cursor and
    /// related chrome should render in. Updates automatically when the
    /// user picks a new color in the menu bar panel.
    var currentCursorColor: Color {
        selectedCursorColor.swiftUIColor
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Cue start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        // Apply the persisted microphone choice so capture uses the user's
        // selected input device from the first recording of this launch.
        buddyDictationManager.setPreferredInputDeviceUniqueID(selectedMicrophoneDeviceUID)
        // Resolve the Anthropic key (Keychain → env var → proxy) and seed
        // claudeAPI before anything triggers it. Also kicks the TLS warmup
        // handshake so it's done before the onboarding demo at ~40s.
        rebuildClaudeAPI()

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isCueCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .cueDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        CueAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .cueDismissPanel, object: nil)
        CueAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Cue: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Cue: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            CueAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            CueAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            CueAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            CueAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    CueAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isCueCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isCueCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .cueDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            resetStreamingTTS()
            stopAllTTSPlayback()
            clearDetectedElementLocation()

            // Reset the live-streaming response panel for the new turn.
            // Hide it now so the slide-out plays before we start the next
            // response; the new text will pop the panel back in.
            streamingResponseText = ""
            isResponsePanelVisible = false

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            CueAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        CueAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            CueAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .continuousSessionToggle:
            // User pressed Command + Control = toggle the hands-free
            // continuous-listening session. PTT (Ctrl+Option) behavior
            // is unaffected because Cmd+Ctrl is a different chord.
            if isContinuousSessionActive {
                exitContinuousSession(reason: .shortcut)
            } else {
                enterContinuousSession()
            }
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    /// Appended to companionVoiceResponseSystemPrompt when the user
    /// is in a continuous-listening session. Tells Claude to skip the
    /// "anything else?" tail prompts and keep replies tight — the user
    /// will just speak again when they want to.
    private static let continuousSessionAddendum = """
    you're in a continuous listening session right now. the user can ask multiple questions back-to-back without holding any button — voice-activity detection segments their speech automatically. keep replies very short (one or two sentences max — no exceptions) so you don't dominate the conversation. only elaborate if explicitly asked to. don't end with "anything else?" tail prompts or trailing suggestions — assume the user will speak again when they want to.
    """


    private static let companionVoiceResponseSystemPrompt = """
    you're cue, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - if a question needs current information you don't already know (news, weather, sports scores, recent events, current prices, what someone said yesterday, who won last night's game, etc.), use the web_search tool. don't search for things that are clearly on the user's screen or that are stable facts you already know — only reach for the web when freshness matters. when you do cite something from the web, mention the source naturally ("according to the verge", "from apple's announcement"), not with bracketed numbers.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - you'll usually get one image labeled "user's current window — <app>" of the app the user is in. when the window can't be identified, you'll get one or more "screen N of M" images instead — in that case, the one tagged "primary focus" is the cursor's screen.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the image label has its pixel dimensions — those are your coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the image's space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). when you got a single "user's current window" image, that's all you need — no screen suffix. only if you received multiple "screen N of M" images AND the element is on a non-cursor screen, append :screenN (e.g. :screen2) so the cursor routes to the right monitor. single-window responses are routed automatically.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via on-device TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        resetStreamingTTS()
        stopAllTTSPlayback()

        // Bump the generation so any chunks still arriving from a
        // previous response (which ClaudeAPI keeps streaming after
        // cancel) are dropped by the onTextChunk guard below.
        currentResponseGeneration += 1
        let myGen = currentResponseGeneration

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // Capture only the frontmost app window for a sharper,
                // focused image — no desktop clutter, no second monitors.
                // Falls back to all connected screens if no eligible window
                // can be found.
                let screenCaptures = try await CompanionScreenCaptureUtility.captureFrontmostFocusedRegionAsJPEG()

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Pass conversation history so Claude remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                // In a continuous session, append the hands-free addendum
                // so Claude keeps replies extra short (no "anything else?"
                // tail prompts, no elaboration unless asked).
                let activeSystemPrompt: String = {
                    if isContinuousSessionActive {
                        return Self.companionVoiceResponseSystemPrompt + "\n\n" + Self.continuousSessionAddendum
                    }
                    return Self.companionVoiceResponseSystemPrompt
                }()

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: activeSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    enableWebSearch: isWebSearchEnabled,
                    onTextChunk: { [weak self] cumulativeStreamedText in
                        // IMPORTANT: ClaudeAPI's onTextChunk callback passes
                        // the FULL accumulated text on every call, not the
                        // per-chunk delta. So we ASSIGN here, never append —
                        // otherwise the same text gets concatenated repeatedly
                        // (e.g. "Hello" → "HelloHello world" → "HelloHello
                        // worldHello world!") and the user sees a duplicated
                        // version of the response right up until the final
                        // cleanup at line `streamingResponseText = spokenText`
                        // below.
                        //
                        // We also strip any partial "[POINT..." tag on the
                        // fly so the user never sees the raw coordinate tag
                        // appear during streaming. The full unmodified
                        // response (with tag) is still captured by
                        // fullResponseText and used for coordinate parsing
                        // — only the display copy is sanitized here.
                        Task { @MainActor in
                            guard let self else { return }
                            // Generation gate: if a barge-in (or a new
                            // call) bumped the generation since we
                            // started, the user no longer cares about
                            // these chunks — drop them so they don't
                            // re-fill the TTS pipeline or overwrite
                            // newer streamingResponseText.
                            guard self.currentResponseGeneration == myGen else { return }
                            var displayText = cumulativeStreamedText
                            if let pointTagStartRange = displayText.range(of: "[POINT") {
                                displayText = String(displayText[..<pointTagStartRange.lowerBound])
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                            self.streamingResponseText = displayText
                            if self.showResponseSidePanelPreference {
                                self.isResponsePanelVisible = true
                            }
                            // Feed the streaming-TTS buffer. Any newly-complete
                            // sentences get queued and the consumer Task starts
                            // playing them immediately — no waiting for the
                            // full response to finish streaming.
                            self.enqueueStreamingTTSChunks(displayText)
                        }
                    }
                )

                guard !Task.isCancelled else { return }
                // Also bail if barge-in (or a newer call) advanced the
                // generation while we awaited — the rest of this
                // function would otherwise mutate streamingResponseText
                // / conversationHistory with a stale response.
                guard currentResponseGeneration == myGen else { return }

                // Parse the [POINT:...] tag from Claude's response
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                // Replace the live-streamed text with the cleaned spokenText
                // so the response panel doesn't end with a raw [POINT:...] tag.
                streamingResponseText = spokenText

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    CueAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                CueAnalytics.trackAIResponseReceived(response: spokenText)

                // Flush any trailing sentence fragment past the last
                // terminator into the streaming-TTS queue (the streaming
                // consumer already started speaking earlier sentences).
                // We do NOT re-speak the whole `spokenText` here — that
                // would double up on audio. Existing behavior of
                // `voiceState = .responding` is preserved; the consumer
                // also sets it once the first sentence begins playing.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        flushStreamingTTSFinalFragment(spokenText)
                        voiceState = .responding
                    } catch {
                        CueAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ Local TTS error: \(error)")
                        speakResponseErrorFallback(underlyingError: error)
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                // Same idea, but for URLSession's flavor of cancel
                // (Code=-999). The barge-in path cancels in-flight
                // network requests, which surfaces here as a regular
                // error — but it's expected, not a real failure, so
                // we suppress the audible fallback. Also suppress if
                // the generation moved on (another barge-in pathway
                // cancelled us between the await and the catch).
                let nsError = error as NSError
                let isURLCancellation = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
                let supersededByNewerCall = currentResponseGeneration != myGen
                if isURLCancellation || supersededByNewerCall {
                    print("⏭️ Companion response cancelled (gen=\(myGen), current=\(currentResponseGeneration)) — suppressing error TTS")
                } else {
                    CueAnalytics.trackResponseError(error: error.localizedDescription)
                    print("⚠️ Companion response error: \(error)")
                    speakResponseErrorFallback(underlyingError: error)
                }
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Cue" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isCueCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing (either engine)
            while isAnyTTSPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a neutral fallback message using macOS system TTS when the
    /// response pipeline or local TTS playback fails for any reason.
    /// Uses NSSpeechSynthesizer (different from the AVSpeechSynthesizer used
    /// by LocalTTSClient) so it works even if the main TTS path is wedged.
    /// The underlying error is logged so the real cause (network failure,
    /// missing worker API key, upstream API error, etc.) is visible in the
    /// console instead of being masked by a hardcoded credits message.
    private func speakResponseErrorFallback(underlyingError: Error) {
        print("⚠️ Speaking response error fallback. Underlying error: \(underlyingError.localizedDescription)")
        let utterance = "Sorry, something went wrong. Check the Xcode console for details."
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Cue flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            CueAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            CueAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're cue, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
