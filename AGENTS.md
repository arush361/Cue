# Pointer - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

> **About this fork:** Pointer is a fork of [Clicky](https://github.com/farzaa/clicky) by Farza. User-facing strings have been rebranded to "Pointer" but internal Swift identifiers (`isClickyCursorEnabled`, `ClickyAnalytics`, `clickyDismissPanel`, etc.) and the Xcode scheme (`leanring-buddy`) kept their original names to avoid `.pbxproj` edits. Architecture is otherwise identical to upstream.

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it on-device via WhisperKit, and sends the transcript + a screenshot of the user's screen to Claude. Claude responds with text (streamed via SSE) and the response is spoken aloud on-device via Kokoro-82M (neural TTS through ONNX Runtime), with `AVSpeechSynthesizer` as the fallback while Kokoro downloads on first launch. A blue cursor overlay can fly to and point at UI elements Claude references on any connected monitor.

Voice runs fully offline. The only network call is Claude `/chat` through the Cloudflare Worker. No AssemblyAI, no ElevenLabs, no per-character quotas. See `SETUP_OFFLINE.md` for the one-time Xcode wiring (add the WhisperKit + ONNX Runtime SPM packages, add the new source files to the target).

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude (Sonnet 4.6 default, Opus 4.6 optional) via Cloudflare Worker proxy with SSE streaming
- **Speech-to-Text**: WhisperKit (`openai_whisper-small.en` model, CoreML-accelerated, on-device). Cloud providers (AssemblyAI, OpenAI) and Apple Speech remain as fallback options if the user flips `VoiceTranscriptionProvider` in Info.plist.
- **Text-to-Speech**: Kokoro-82M v1.0 (neural, ~88MB INT8-quantized ONNX model) via ONNX Runtime Swift, running on-device. Pipeline: text → IPA phonemes (CMU dict + ARPAbet→IPA) → token IDs → ONNX inference → 24kHz Float32 PCM → AVAudioPlayer. Falls back to `AVSpeechSynthesizer` while Kokoro initializes on first launch or if ONNX Runtime isn't available. See `KokoroTTSClient.swift` and `LocalTTSClient.swift`.
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: Claude embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: PostHog via `ClickyAnalytics.swift`

### API Proxy (Cloudflare Worker)

The app's only network dependency (besides PostHog analytics and the optional onboarding video) is Claude. The worker (`worker/src/index.ts`) holds the Anthropic key as a secret and proxies the chat endpoint.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.anthropic.com/v1/messages` | Claude vision + streaming chat |

Worker secrets: `ANTHROPIC_API_KEY`
Worker vars: (none)

The previous `/tts` and `/transcribe-token` routes are removed. If you're migrating from the upstream Clicky worker, delete the unused secrets with `npx wrangler secret delete ASSEMBLYAI_API_KEY` and `npx wrangler secret delete ELEVENLABS_API_KEY`.

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Transient Cursor Mode**: When "Show Pointer" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

**WhisperKit Whole-Utterance Model**: Unlike AssemblyAI's streaming websocket, WhisperKit transcribes complete audio clips, not chunks. The session buffers PCM16 audio while push-to-talk is held, then runs a single `transcribe(audioPath:)` call on key-up. This is fine for short companion utterances (<30s) and avoids the overhead of running encoder passes on every chunk. Model load and warmup happen lazily on first use via a shared `Task<WhisperKit, Error>`.

**On-Device TTS Picks Best Available Voice**: `LocalTTSClient.findBestAvailableEnglishVoice()` ranks installed voices by `AVSpeechSynthesisVoiceQuality` (Premium > Enhanced > Default) then by locale preference (en-US > en-GB > en-AU > en-IE > en-IN). If the user installs a Premium voice via System Settings → Accessibility → Spoken Content, the app picks it up automatically on next launch. No code changes needed.

**Two-Tier TTS Strategy**: `CompanionManager.speakResponseThroughBestAvailableTTS` tries Kokoro first (`kokoroTTSClient.isReady`). If Kokoro fails or is still downloading its assets on first launch, it falls through to `LocalTTSClient` (AVSpeechSynthesizer). This means the app speaks immediately on first launch (via the system synthesizer) while Kokoro warms up in the background — there's no startup delay visible to the user. `stopAllTTSPlayback()` stops both engines and `isAnyTTSPlaying` reads both, so the transient-cursor scheduler doesn't care which engine is active.

**Kokoro Asset Download**: `KokoroAssetDownloader` lazily fetches `model_quantized.onnx` (~88MB) and the chosen voice file (~520KB) from HuggingFace on first use and caches them in `~/Library/Caches/Pointer/kokoro/`. `KokoroPhonemizer` separately fetches `cmudict.dict` (~3MB) from the cmusphinx repo. All three are cached for subsequent launches.

**IPA Phonemization Tradeoff**: `KokoroPhonemizer` uses the CMU Pronouncing Dictionary plus an ARPAbet→IPA mapping table. This covers >95% of common English words but is less accurate than upstream's `misaki` phonemizer (rule-based G2P) or `espeak-ng`. For an upgrade, the swap-point is narrow: `KokoroPhonemizer.phonemize(text:) async throws -> String` is the only method `KokoroTTSClient` calls.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1026 | Central state machine. Owns dictation, shortcut monitoring, screen capture, Claude API, on-device TTS, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, and cursor visibility. Coordinates the full push-to-talk → screenshot → Claude → TTS → pointing pipeline. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~761 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, model picker (Sonnet/Opus), permissions UI, DM feedback button, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~120 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — `whisperkit` (default), `assemblyai`, `openai`, or `apple`. Prefers WhisperKit when available; falls back to Apple Speech otherwise. |
| `WhisperKitTranscriptionProvider.swift` | ~210 | On-device transcription via WhisperKit (CoreML-accelerated Whisper). Buffers PCM16 audio while push-to-talk is held, writes a temp WAV on key-up, runs a single `transcribe(audioPath:)` call. Wrapped in `#if canImport(WhisperKit)` so the file compiles before the SPM is wired. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Optional cloud fallback. Streaming transcription via AssemblyAI v3 websocket. Only used if Info.plist selects `assemblyai`. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Optional cloud fallback. Upload-based transcription via OpenAI. Only used if Info.plist selects `openai`. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. Used when WhisperKit is unavailable and no cloud provider is configured. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads. Shared by WhisperKit and OpenAI providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `ClaudeAPI.swift` | ~291 | Claude vision API client with streaming (SSE) and non-streaming modes. TLS warmup optimization, image MIME detection, conversation history support. |
| `OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client. Dormant — no caller wires it up. |
| `KokoroTTSClient.swift` | ~260 | Primary on-device TTS using Kokoro-82M v1.0 via ONNX Runtime. Public API matches LocalTTSClient (`speakText`, `isPlaying`, `stopPlayback`). Initialization (model download + ONNX session load) starts on creation; reports `isReady = true` when usable. Wrapped in `#if canImport(OnnxRuntimeBindings)`. |
| `KokoroPhonemizer.swift` | ~210 | Text → IPA phonemes. Lazy-loads CMU Pronouncing Dictionary on first use (downloaded once from cmusphinx GitHub). ARPAbet → IPA via fixed mapping table. Falls back to letter-by-letter pronunciation for unknown words. |
| `KokoroTokenizer.swift` | ~60 | IPA phoneme string → `[Int64]` token ID sequence for Kokoro's ONNX model. Uses Kokoro's fixed `$;:,.!?…ABC...ɑɐɒ...` vocabulary. Pads boundaries with silence token. |
| `KokoroAssetDownloader.swift` | ~80 | Downloads and caches Kokoro's ONNX model and per-voice style embeddings on first use. Files live under `~/Library/Caches/Pointer/kokoro/`. |
| `LocalTTSClient.swift` | ~130 | Fallback TTS via `AVSpeechSynthesizer`. Auto-selects best installed English voice (Premium > Enhanced > Default). Used while Kokoro is still downloading on first launch, or if ONNX Runtime isn't wired up. |
| `ElevenLabsTTSClient.swift` | ~81 | Legacy ElevenLabs TTS client. No longer referenced by CompanionManager. Safe to remove from the Xcode target. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `ClickyAnalytics.swift` | ~121 | PostHog analytics integration for usage tracking. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `worker/src/index.ts` | ~70 | Cloudflare Worker proxy. Single route: `/chat` (Claude). TTS and STT both moved on-device. |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Cloudflare Worker

```bash
cd worker
npm install

# Add secrets
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY

# Deploy
npx wrangler deploy

# Local dev (create worker/.dev.vars with your keys)
npx wrangler dev
```

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
