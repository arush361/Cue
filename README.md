# Pointer

A macOS menu bar AI companion. Lives in the menu bar (no dock icon), uses push-to-talk to listen, sees your screen, and responds with voice. The blue cursor can fly across your screen and point at things it's referring to.

Pointer is a fork of [Clicky](https://github.com/farzaa/clicky) by Farza. Same core architecture, rebranded for hacking and extension.

## Architecture (the short version)

Menu bar app (no dock icon) with two `NSPanel` windows. One is the control panel dropdown, the other is the full-screen transparent cursor overlay. Push-to-talk streams audio over a websocket to AssemblyAI, sends the transcript + screenshot to Claude via streaming SSE, and plays the response through ElevenLabs TTS. Claude can embed `[POINT:x,y:label:screenN]` tags in its responses to make the cursor fly to specific UI elements across multiple monitors. All three APIs are proxied through a Cloudflare Worker so no keys ship in the app.

For the full technical breakdown, read `AGENTS.md` (also symlinked as `CLAUDE.md`).

## Prerequisites

- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- Node.js 18+ (for the Cloudflare Worker)
- A [Cloudflare](https://cloudflare.com) account (free tier works)
- API keys for: [Anthropic](https://console.anthropic.com), [AssemblyAI](https://www.assemblyai.com), [ElevenLabs](https://elevenlabs.io)

## Setup

### 1. Cloudflare Worker

The Worker is a tiny proxy that holds your API keys. The app talks to the Worker; the Worker talks to the APIs. Keys never ship in the binary.

```bash
cd worker
npm install
```

Add your secrets:

```bash
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY
```

Set the ElevenLabs voice ID in `wrangler.toml`:

```toml
[vars]
ELEVENLABS_VOICE_ID = "your-voice-id-here"
```

Deploy:

```bash
npx wrangler deploy
```

That returns a URL like `https://pointer-proxy.your-subdomain.workers.dev`. Copy it.

### 2. Local Worker dev (optional)

For iterating on the Worker without deploying:

```bash
cd worker
npx wrangler dev
```

Local server runs at `http://localhost:8787`. Create `worker/.dev.vars` with your keys:

```
ANTHROPIC_API_KEY=sk-ant-...
ASSEMBLYAI_API_KEY=...
ELEVENLABS_API_KEY=...
ELEVENLABS_VOICE_ID=...
```

### 3. Point the app at your Worker

The Worker URL is hardcoded in two places in the Swift code:

- `leanring-buddy/CompanionManager.swift` (constant `workerBaseURL`)
- `leanring-buddy/AssemblyAIStreamingTranscriptionProvider.swift` (constant `tokenProxyURL`)

Both currently default to `http://localhost:8787`. For production, replace with your deployed Worker URL.

### 4. Open in Xcode and run

```bash
open leanring-buddy.xcodeproj
```

1. Select the `leanring-buddy` scheme (the typo is legacy from the original Clicky repo; renaming it would touch the `.pbxproj` and risk breaking the build)
2. Set your signing team under *Signing & Capabilities*
3. Hit **Cmd + R**

Pointer shows up in your menu bar (no dock icon). Click the icon to open the panel, grant permissions, and you're good.

### Permissions

- **Microphone** for push-to-talk voice capture
- **Accessibility** for the global keyboard shortcut (Control + Option)
- **Screen Recording** for screenshot capture
- **Screen Content** for ScreenCaptureKit access

## Don't run `xcodebuild` from the terminal

It invalidates TCC (Transparency, Consent, and Control) permissions and the app has to re-request screen recording, accessibility, etc. The only sanctioned `xcodebuild` usage is via `scripts/release.sh` for releases.

## Project structure

```
leanring-buddy/          # Swift source (scheme name kept for compatibility)
  CompanionManager.swift    # Central state machine
  CompanionPanelView.swift  # Menu bar panel UI
  ClaudeAPI.swift           # Claude streaming client
  ElevenLabsTTSClient.swift # Text-to-speech playback
  OverlayWindow.swift       # Blue cursor overlay
  AssemblyAI*.swift         # Real-time transcription
  BuddyDictation*.swift     # Push-to-talk pipeline
worker/                  # Cloudflare Worker proxy
  src/index.ts              # Three routes: /chat, /tts, /transcribe-token
AGENTS.md                # Full architecture doc (CLAUDE.md is a symlink to this)
```

## Note on the Clicky → Pointer rename

This fork rebranded user-facing strings (the panel title, Info.plist permission descriptions, system prompts to Claude) but kept the internal Swift identifiers (`isClickyCursorEnabled`, `ClickyAnalytics`, `clickyDismissPanel`, etc.) and the Xcode scheme name (`leanring-buddy`) intact. Touching those would mean editing the `.pbxproj` file, which is fragile. The app works fine; only the runtime branding changes.

## License

MIT. Inherited from the upstream Clicky project. See `LICENSE`.
