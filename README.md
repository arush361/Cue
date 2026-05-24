# Pointer

A macOS menu bar AI companion. Lives in the menu bar (no dock icon), uses push-to-talk to listen, sees your screen, and responds with voice. The blue cursor can fly across your screen and point at things it's referring to.

Pointer is a fork of [Clicky](https://github.com/farzaa/clicky) by Farza, **rebuilt around fully on-device voice**. Speech-to-text runs through WhisperKit, text-to-speech runs through Kokoro-82M v1.0 via ONNX Runtime (with `AVSpeechSynthesizer` as the fallback while Kokoro warms up). The only network call is Claude `/chat`.

## Architecture (the short version)

Menu bar app (no dock icon) with two `NSPanel` windows: one is the control panel dropdown, the other is the full-screen transparent cursor overlay. Push-to-talk buffers audio locally, runs WhisperKit transcription on key-up, then sends the transcript + screenshot to Claude via streaming SSE through a Cloudflare Worker proxy. The response is spoken locally via Kokoro-82M v1.0 (neural TTS, ~88MB ONNX model) once it finishes downloading; until then, `AVSpeechSynthesizer` covers playback. Claude can embed `[POINT:x,y:label:screenN]` tags in its responses to make the cursor fly to specific UI elements across multiple monitors.

No AssemblyAI, no ElevenLabs, no per-character quotas. Only Anthropic.

For the full technical breakdown, read `AGENTS.md` (also symlinked as `CLAUDE.md`). For the one-time Xcode-side wiring, read `SETUP_OFFLINE.md`.

## Prerequisites

- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- Node.js 18+ (for the Cloudflare Worker)
- A [Cloudflare](https://cloudflare.com) account (free tier works)
- An [Anthropic API key](https://console.anthropic.com)
- Apple Silicon recommended (Intel works but WhisperKit is much slower)

## Setup

### 1. Cloudflare Worker

The Worker is a tiny proxy that holds your Anthropic API key. The app talks to the Worker; the Worker talks to Anthropic. Key never ships in the binary.

```bash
cd worker
npm install
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler deploy
```

That returns a URL like `https://pointer-proxy.your-subdomain.workers.dev`. Copy it.

### 2. Local Worker dev (optional)

For iterating on the Worker without deploying:

```bash
cd worker
npx wrangler dev
```

Local server runs at `http://localhost:8787`. Create `worker/.dev.vars` with:

```
ANTHROPIC_API_KEY=sk-ant-...
```

### 3. Point the app at your Worker

The Worker URL is hardcoded in:

- `leanring-buddy/CompanionManager.swift` (constant `workerBaseURL`)
- `leanring-buddy/AssemblyAIStreamingTranscriptionProvider.swift` (constant `tokenProxyURL`, unused after Path A but still references the URL)

Default is `http://localhost:8787`. For production, replace with your deployed Worker URL.

### 4. Wire up the two SPM packages and the new source files in Xcode

This is the only step that can't be automated from the terminal because it requires Xcode UI. The full walkthrough is in **[SETUP_OFFLINE.md](./SETUP_OFFLINE.md)**. Short version:

1. Open `leanring-buddy.xcodeproj`.
2. **File → Add Package Dependencies…** → paste `https://github.com/argmaxinc/WhisperKit` → add to the `leanring-buddy` target.
3. **File → Add Package Dependencies…** again → paste `https://github.com/microsoft/onnxruntime-swift-package-manager` → add `onnxruntime` to the `leanring-buddy` target.
4. In the Project Navigator, right-click the `leanring-buddy` group → **Add Files to "leanring-buddy"…** → select all six new files (`WhisperKitTranscriptionProvider.swift`, `LocalTTSClient.swift`, `KokoroTTSClient.swift`, `KokoroTokenizer.swift`, `KokoroPhonemizer.swift`, `KokoroAssetDownloader.swift`) → make sure the `leanring-buddy` target is ticked → **Add**.
5. (Optional, for best fallback voice quality) **System Settings → Accessibility → Spoken Content → System Voice → Customize…** → download a Premium English voice (e.g., "Ava (Premium)").

### 5. Build & run

In Xcode: select the `leanring-buddy` scheme → set your signing team under *Signing & Capabilities* → **Cmd + R**.

On first launch:
- WhisperKit downloads the `openai_whisper-small.en` model (~250MB) to `~/Library/Application Support/com.argmaxinc.whisperkit/`.
- Kokoro downloads `model_quantized.onnx` (~88MB) and the default voice (`af_heart.bin`, ~520KB) to `~/Library/Caches/Pointer/kokoro/`.
- The CMU Pronouncing Dictionary downloads (`cmudict.dict`, ~3MB) to `~/Library/Caches/Pointer/`.

Total first-launch download: about 350MB. Subsequent launches reuse the cache and start instantly. While Kokoro is initializing, the app falls back to `AVSpeechSynthesizer` so it's immediately usable.

Pointer shows up in your menu bar. Click the icon, grant permissions, and you're good.

### Permissions

- **Microphone** for push-to-talk voice capture
- **Accessibility** for the global keyboard shortcut (Control + Option)
- **Screen Recording** for screenshot capture
- **Screen Content** for ScreenCaptureKit access

(No Speech Recognition permission needed — WhisperKit doesn't use Apple's Speech framework.)

## Don't run `xcodebuild` from the terminal

It invalidates TCC (Transparency, Consent, and Control) permissions and the app has to re-request screen recording, accessibility, etc. The only sanctioned `xcodebuild` usage is via `scripts/release.sh` for releases.

## Project structure

```
leanring-buddy/                            # Swift source (scheme name kept for compatibility)
  CompanionManager.swift                      # Central state machine
  CompanionPanelView.swift                    # Menu bar panel UI
  ClaudeAPI.swift                             # Claude streaming client
  LocalTTSClient.swift                        # Fallback TTS (AVSpeechSynthesizer)
  KokoroTTSClient.swift                       # Primary TTS (Kokoro-82M via ONNX Runtime)
  KokoroPhonemizer.swift                      # Text → IPA via CMU dict + ARPAbet→IPA
  KokoroTokenizer.swift                       # IPA → int64 token IDs for Kokoro
  KokoroAssetDownloader.swift                 # Lazy download of Kokoro model + voices
  WhisperKitTranscriptionProvider.swift       # On-device STT (WhisperKit)
  OverlayWindow.swift                         # Blue cursor overlay
  BuddyDictation*.swift                       # Push-to-talk pipeline
  AssemblyAI*.swift, OpenAI*.swift, Apple*.swift  # Optional cloud / Apple-Speech fallbacks
worker/                                    # Cloudflare Worker proxy
  src/index.ts                                # Single route: /chat
AGENTS.md                                  # Full architecture doc (CLAUDE.md is a symlink)
SETUP_OFFLINE.md                           # One-time Xcode setup walkthrough
```

## Note on the Clicky → Pointer rename

This fork rebranded user-facing strings (the panel title, Info.plist permission descriptions, system prompts to Claude) but kept the internal Swift identifiers (`isClickyCursorEnabled`, `ClickyAnalytics`, `clickyDismissPanel`, etc.) and the Xcode scheme name (`leanring-buddy`) intact. Touching those would mean editing the `.pbxproj` file, which is fragile. The app works fine; only the runtime branding changes.

## License

MIT. Inherited from the upstream Clicky project. See `LICENSE`.
