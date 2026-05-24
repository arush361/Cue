# Pointer — Fully Offline Voice Setup

Pointer's voice pipeline runs on-device:

- **STT**: [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML-accelerated Whisper for Apple Silicon)
- **TTS**: `AVSpeechSynthesizer` with macOS premium/enhanced voices

The only network call left is Claude `/chat` through the Cloudflare Worker. No AssemblyAI, no ElevenLabs, no per-character quotas, no third-party voice keys.

This doc walks through the Xcode-side wiring you need to do once. After this, every push-to-talk works fully offline (except the actual call to Claude).

---

## 1. Add WhisperKit to the Xcode project

The Swift code in `leanring-buddy/WhisperKitTranscriptionProvider.swift` is already written. It's wrapped in `#if canImport(WhisperKit)` so the project builds even without the SPM, just with the provider reporting unavailable. You need to add WhisperKit as a Swift Package once.

1. Open `leanring-buddy.xcodeproj`.
2. **File → Add Package Dependencies…**
3. In the search field, paste:
   ```
   https://github.com/argmaxinc/WhisperKit
   ```
4. Choose **Up to Next Major Version** for the dependency rule.
5. Click **Add Package**.
6. When prompted to choose products, tick `WhisperKit` and assign it to the `leanring-buddy` target. Click **Add Package**.

Verify by opening `WhisperKitTranscriptionProvider.swift` — the `#if canImport(WhisperKit)` blocks should now be active (no greyed-out text).

## 2. Add the two new source files to the target

The fork created two new Swift files on disk but they're not yet in the Xcode project:

- `leanring-buddy/WhisperKitTranscriptionProvider.swift`
- `leanring-buddy/LocalTTSClient.swift`

To add them:

1. In Xcode's Project Navigator, right-click the `leanring-buddy` group.
2. Choose **Add Files to "leanring-buddy"…**
3. Select both files (Cmd+click).
4. Make sure **Add to targets: leanring-buddy** is ticked.
5. Click **Add**.

Xcode will update `project.pbxproj` automatically.

## 3. (Optional) Remove unused source files from the target

You no longer need these files at runtime:

- `leanring-buddy/ElevenLabsTTSClient.swift`
- `leanring-buddy/AssemblyAIStreamingTranscriptionProvider.swift` (only if you also remove `BuddyTranscriptionProviderFactory`'s fallback to it)

Leaving them in the target is harmless — they just bloat the binary slightly. To clean up: in the Project Navigator, right-click each → **Delete** → **Remove Reference** (not "Move to Trash" unless you also want them off disk). The factory's fallback paths to AssemblyAI will then go away naturally because nothing in `Info.plist` selects it anymore.

## 4. Make sure Info.plist is set to WhisperKit

The fork already set this for you, but verify:

```xml
<key>VoiceTranscriptionProvider</key>
<string>whisperkit</string>
```

Recognized values: `whisperkit`, `assemblyai`, `openai`, `apple`. If WhisperKit reports unavailable (e.g., the package wasn't added), the factory falls back to Apple Speech automatically.

## 5. (Optional but recommended) Install premium TTS voices

`LocalTTSClient` picks the highest-quality English voice installed on your Mac. By default macOS ships with okay voices; the **premium** voices sound significantly better.

1. **System Settings → Accessibility → Spoken Content**
2. Click the **System Voice** dropdown → **Customize…**
3. Find an English voice marked **(Premium)** (e.g., "Ava (Premium)", "Evan (Premium)", "Zoe (Premium)").
4. Click the download icon. Each premium voice is ~100–200MB.
5. Once downloaded, restart Pointer. Look for this log line on startup:
   ```
   🔊 LocalTTS: using voice "Ava (Premium)" (quality: Premium)
   ```

If no premium voice is installed, `LocalTTSClient` falls back to whatever is best available (typically an `(Enhanced)` voice, also pretty good).

## 6. Shrink the Cloudflare Worker

The worker now only proxies `/chat`. You can safely remove the unused secrets:

```bash
cd worker
npx wrangler secret delete ASSEMBLYAI_API_KEY
npx wrangler secret delete ELEVENLABS_API_KEY
```

And drop the `ELEVENLABS_VOICE_ID` line from `wrangler.toml` if you haven't already (the fork already removed it).

Redeploy:

```bash
npx wrangler deploy
```

The only secret the worker still needs is `ANTHROPIC_API_KEY`.

## 7. Build & run

In Xcode, select the `leanring-buddy` scheme → set your signing team → **Cmd + R**. On first launch, WhisperKit will download its model (~250MB for `openai_whisper-small.en`) to `~/Library/Application Support/com.argmaxinc.whisperkit/` and warm it up. Subsequent launches reuse the cached model and start instantly.

Expected console output:

```
🎯 Pointer: Starting...
🎙️ Transcription: using WhisperKit (on-device)
🔊 LocalTTS: using voice "Ava (Premium)" (quality: Premium)
🔑 Pointer start — accessibility: true, ...
```

If you see `🎙️ Transcription: using Apple Speech` instead of WhisperKit, the SPM package isn't wired up correctly — go back to step 1.

## 8. Verify the network path

Once running, hold push-to-talk and say something. In Xcode's console you should see only:

```
🌐 Claude streaming request: 0.3MB, 1 image(s)
```

No AssemblyAI websocket logs, no ElevenLabs TTS logs. Voice in and voice out are entirely local.

You can also confirm by enabling **Activity Monitor → View → Network → Open Files and Ports** and watching the process — only Cloudflare/Anthropic IPs should show up.

---

## Future upgrade: Kokoro-82M for higher-quality TTS

`AVSpeechSynthesizer` with premium voices is good enough for a companion. If you want ElevenLabs-grade quality, the path forward is:

1. Add [`onnxruntime-swift`](https://onnxruntime.ai/docs/get-started/with-swift.html) as an SPM dependency.
2. Bundle (or download on first launch) the [Kokoro-82M ONNX model](https://huggingface.co/onnx-community/Kokoro-82M-ONNX) (~80MB).
3. Implement phoneme conversion. Kokoro expects IPA phonemes; the upstream Python implementation uses `espeak-ng`. For Swift, the practical options are:
   - Bundle a pre-built grapheme-to-phoneme dictionary for English (smaller, English-only).
   - Wrap `espeak-ng` via a Swift C interop bridge (more complete, more setup).
4. Write a `KokoroTTSClient` matching `LocalTTSClient`'s interface (`speakText`, `isPlaying`, `stopPlayback`) and swap the lazy property in `CompanionManager.swift`.

This is a multi-day project. The interface boundary at `LocalTTSClient` is intentionally narrow so swapping the implementation is local — `CompanionManager`'s pipeline doesn't change.
