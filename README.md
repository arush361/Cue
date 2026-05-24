# Cue

A macOS menu bar AI companion. Lives in the menu bar (no dock icon), uses push-to-talk to listen, sees your screen, and responds with voice. The blue cursor can fly across your screen and point at things it's referring to.

Cue is a fork of [Clicky](https://github.com/farzaa/clicky) by Farza, **rebuilt around fully on-device voice**. Speech-to-text runs through WhisperKit, text-to-speech runs through Kokoro-82M v1.0 via ONNX Runtime (with `AVSpeechSynthesizer` as the fallback while Kokoro warms up). The only network call is Claude `/chat`.

Cue can also **search the web** for current information when you ask about news, weather, sports, recent events, or anything time-sensitive. Claude's built-in `web_search_20250305` tool runs server-side, so no extra API keys or services are needed — just Anthropic's standard per-search pricing. Toggleable from the menu bar panel (defaults to on, capped at 3 searches per response).

## Architecture (the short version)

Menu bar app (no dock icon) with two `NSPanel` windows: one is the control panel dropdown, the other is the full-screen transparent cursor overlay. Push-to-talk buffers audio locally, runs WhisperKit transcription on key-up, then sends the transcript + screenshot to Claude via streaming SSE. The response is spoken locally via Kokoro-82M v1.0 (neural TTS, ~88MB ONNX model) once it finishes downloading; until then, `AVSpeechSynthesizer` covers playback. Claude can embed `[POINT:x,y:label:screenN]` tags in its responses to make the cursor fly to specific UI elements across multiple monitors.

No AssemblyAI, no ElevenLabs, no per-character quotas. Only Anthropic.

For the full technical breakdown, read `AGENTS.md` (also symlinked as `CLAUDE.md`). For the one-time Xcode-side wiring, read `SETUP_OFFLINE.md`.

## Hardware requirements

| | Minimum | Recommended |
|---|---|---|
| **macOS** | 14.2 (Sonoma) | 26 (Tahoe) for real Liquid Glass UI |
| **CPU** | Intel Core i5 (8th gen+) | Apple Silicon (M1 / M2 / M3 / M4) |
| **RAM** | 8 GB | 16 GB |
| **Free disk** | ~500 MB (models + caches) | ~1 GB |
| **Microphone** | Any built-in or USB mic | Same |
| **Display** | Any | Single ≥1280×800 for the cursor flight to feel right |

Apple Silicon is **strongly recommended**. WhisperKit uses CoreML / the Apple Neural Engine — on Apple Silicon, full transcription of a 10-second utterance happens in ~150ms. On Intel Macs the same workload falls back to CPU and can take 1-2 seconds, which makes the push-to-talk experience feel sluggish. Kokoro inference via ONNX Runtime is similarly faster on Apple Silicon thanks to its INT8 quantized model.

You'll also need:
- **Xcode 15+** (for the build)
- **An Anthropic API key** ([console.anthropic.com](https://console.anthropic.com))
- *(Optional for the fallback path)* a [Cloudflare](https://cloudflare.com) account + Node.js 18+

## Setup

There are two ways to give Cue your Anthropic API key. Pick the one that fits how you're using the app.

### Recommended: direct mode (personal use)

Cue talks to `api.anthropic.com` directly, with your key read at runtime from the process environment. The key is never bundled into the binary, never committed to git, and never leaves your machine.

1. **Get an Anthropic API key** from [console.anthropic.com](https://console.anthropic.com).

2. **Add the key as a scheme environment variable in Xcode**:
   - Open `leanring-buddy.xcodeproj`.
   - Product → **Scheme → Edit Scheme…** (or **⌘ <**).
   - Select **Run** in the left sidebar → **Arguments** tab.
   - Under **Environment Variables**, click **+**:
     - Name: `ANTHROPIC_API_KEY`
     - Value: your `sk-ant-...` key
   - Close the dialog.

3. **Wire up the two SPM packages and the new source files** in Xcode (one-time, see [SETUP_OFFLINE.md](./SETUP_OFFLINE.md)).

4. **Build and run** (Cmd+R). On startup the console should show:
   ```
   🌐 Claude API: direct mode (env var ANTHROPIC_API_KEY)
   ```

Pros: zero infrastructure, no Worker to deploy, no extra hop. Cons: only works in the Xcode-launched build (the env var goes away when you run the app outside of Xcode). For a build you can run standalone, see the fallback below.

### Fallback: Cloudflare Worker proxy (production / shared builds)

Use this if you want to:
- Ship a signed `.app` to someone else without burning your API key into the binary.
- Run Cue without launching it from Xcode every time (e.g., on login).
- Keep the API key on a server you control instead of on every machine.

The Worker is a tiny proxy that holds your Anthropic API key as a Cloudflare secret. The app calls the Worker; the Worker forwards to Anthropic.

**Deploy it:**
```bash
cd worker
npm install
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler deploy
```

That returns a URL like `https://cue-proxy.your-subdomain.workers.dev`. Copy it.

**Or run it locally for development:**
```bash
cd worker
npx wrangler dev
```

Local server starts at `http://localhost:8787`. Create `worker/.dev.vars`:
```
ANTHROPIC_API_KEY=sk-ant-...
```

**Point the app at your Worker URL:**

The Worker base URL lives in `leanring-buddy/CompanionManager.swift` as the `workerBaseURL` constant — default is `http://localhost:8787`. For a deployed Worker, replace with your `workers.dev` URL.

Cue automatically prefers the Worker path **only when `ANTHROPIC_API_KEY` is not set in the environment**. So if you've configured the env var per the direct-mode instructions above, remove it (or empty it) to switch over. On startup the console will show:
```
🌐 Claude API: proxy mode (fallback to http://localhost:8787)
```

### One-time Xcode wiring (both paths)

Regardless of which key path you pick, you need to wire up the on-device voice stack once. Full walkthrough in **[SETUP_OFFLINE.md](./SETUP_OFFLINE.md)**. Short version:

1. **File → Add Package Dependencies…** → `https://github.com/argmaxinc/WhisperKit` → add to the `leanring-buddy` target.
2. **File → Add Package Dependencies…** again → `https://github.com/microsoft/onnxruntime-swift-package-manager` → add `onnxruntime` to the target.
3. Right-click the `leanring-buddy` group → **Add Files to "leanring-buddy"…** → select all six new files (`WhisperKitTranscriptionProvider.swift`, `LocalTTSClient.swift`, `KokoroTTSClient.swift`, `KokoroTokenizer.swift`, `KokoroPhonemizer.swift`, `KokoroAssetDownloader.swift`, `ResponseSidePanelView.swift`, `ResponseSidePanelManager.swift`) → ensure target is ticked → **Add**.
4. (Optional) System Settings → Accessibility → Spoken Content → System Voice → Customize → download a Premium English voice for a cleaner fallback TTS while Kokoro is downloading.

### First-launch downloads

On first run Cue downloads its on-device models:
- WhisperKit `openai_whisper-small.en` model → `~/Library/Application Support/com.argmaxinc.whisperkit/` (~250 MB)
- Kokoro `model_quantized.onnx` + `af_heart.bin` voice → `~/Library/Caches/Cue/kokoro/` (~89 MB)
- CMU Pronouncing Dictionary → `~/Library/Caches/Cue/cmudict.dict` (~3 MB)

Total: about 340 MB, one time. Subsequent launches reuse the cache and start instantly. While Kokoro is initializing, the app falls back to `AVSpeechSynthesizer` so it's usable from the very first push-to-talk.

### Permissions

When you first run Cue, grant these in the menu bar panel:

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
  ClaudeAPI.swift                             # Direct + proxy Claude client
  LocalTTSClient.swift                        # Fallback TTS (AVSpeechSynthesizer)
  KokoroTTSClient.swift                       # Primary TTS (Kokoro-82M via ONNX Runtime)
  KokoroPhonemizer.swift                      # Text → IPA via CMU dict + ARPAbet→IPA
  KokoroTokenizer.swift                       # IPA → int64 token IDs for Kokoro
  KokoroAssetDownloader.swift                 # Lazy download of Kokoro model + voices
  WhisperKitTranscriptionProvider.swift       # On-device STT (WhisperKit)
  ResponseSidePanelView.swift                 # Live-response side panel (Granola-style glass)
  ResponseSidePanelManager.swift              # NSPanel host for the side panel
  OverlayWindow.swift                         # Blue cursor overlay
  BuddyDictation*.swift                       # Push-to-talk pipeline
worker/                                    # Cloudflare Worker proxy (fallback path)
  src/index.ts                                # Single route: /chat
AGENTS.md                                  # Full architecture doc (CLAUDE.md is a symlink)
SETUP_OFFLINE.md                           # One-time Xcode setup walkthrough
```

## Note on the Clicky → Cue rename

This fork rebranded user-facing strings (the panel title, Info.plist permission descriptions, system prompts to Claude) but kept the internal Swift identifiers (`isClickyCursorEnabled`, `ClickyAnalytics`, `clickyDismissPanel`, etc.) and the Xcode scheme name (`leanring-buddy`) intact. Touching those would mean editing the `.pbxproj` file, which is fragile. The app works fine; only the runtime branding changes.

## License

MIT. Inherited from the upstream Clicky project. See `LICENSE`.
