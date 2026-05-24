# Pointer — Fully Offline Voice Setup

Pointer's voice pipeline runs entirely on-device:

- **STT**: [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML-accelerated Whisper for Apple Silicon)
- **TTS (primary)**: [Kokoro-82M v1.0](https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX) via [ONNX Runtime Swift](https://github.com/microsoft/onnxruntime-swift-package-manager) (neural TTS, ~88MB quantized model)
- **TTS (fallback)**: `AVSpeechSynthesizer` with macOS premium voices. Kicks in automatically while Kokoro is downloading on first launch, or if ONNX Runtime isn't wired up yet.

The only network call left is Claude `/chat` through the Cloudflare Worker. No AssemblyAI, no ElevenLabs, no per-character quotas, no third-party voice keys.

This doc walks through the Xcode-side wiring you need to do once. After this, every push-to-talk works fully offline (except the actual call to Claude).

---

## 1. Add the two Swift Packages

### 1a. WhisperKit (for STT)

1. Open `leanring-buddy.xcodeproj`.
2. **File → Add Package Dependencies…**
3. Paste:
   ```
   https://github.com/argmaxinc/WhisperKit
   ```
4. Choose **Up to Next Major Version**.
5. Click **Add Package**.
6. Tick `WhisperKit` and assign it to the `leanring-buddy` target. Click **Add Package**.

### 1b. ONNX Runtime (for Kokoro TTS)

1. **File → Add Package Dependencies…**
2. Paste:
   ```
   https://github.com/microsoft/onnxruntime-swift-package-manager
   ```
3. Choose **Up to Next Major Version**.
4. Click **Add Package**.
5. Tick `onnxruntime` and assign it to the `leanring-buddy` target. Click **Add Package**.

Verify both packages by opening `WhisperKitTranscriptionProvider.swift` and `KokoroTTSClient.swift` — the `#if canImport(...)` blocks should now be active (text no longer greyed out).

## 2. Add the new source files to the target

The fork created six new Swift files on disk but they're not yet in the Xcode project:

- `leanring-buddy/WhisperKitTranscriptionProvider.swift`
- `leanring-buddy/LocalTTSClient.swift`
- `leanring-buddy/KokoroTTSClient.swift`
- `leanring-buddy/KokoroTokenizer.swift`
- `leanring-buddy/KokoroPhonemizer.swift`
- `leanring-buddy/KokoroAssetDownloader.swift`

To add them:

1. In Xcode's Project Navigator, right-click the `leanring-buddy` group.
2. **Add Files to "leanring-buddy"…**
3. Select all six files (Cmd+click each).
4. Make sure **Add to targets: leanring-buddy** is ticked.
5. Click **Add**.

## 3. (Optional) Remove unused files from the target

These files are no longer referenced at runtime:

- `leanring-buddy/ElevenLabsTTSClient.swift`
- `leanring-buddy/AssemblyAIStreamingTranscriptionProvider.swift`

Leaving them in the target is harmless (just slightly bloats the binary). To remove: right-click each in the Project Navigator → **Delete** → **Remove Reference**.

## 4. Verify Info.plist

```xml
<key>VoiceTranscriptionProvider</key>
<string>whisperkit</string>
```

(The fork already set this.) Recognized values: `whisperkit`, `assemblyai`, `openai`, `apple`. If WhisperKit reports unavailable, the factory falls back to Apple Speech.

## 5. Build & run

In Xcode: select `leanring-buddy` scheme → set signing team → **Cmd + R**.

On first launch:
- **WhisperKit** downloads its model (`openai_whisper-small.en`, ~250MB) to `~/Library/Application Support/com.argmaxinc.whisperkit/`.
- **Kokoro** downloads its model (`model_quantized.onnx`, ~88MB) and the default voice (`af_heart.bin`, ~520KB) to `~/Library/Caches/Pointer/kokoro/`.
- **CMU dict** downloads (`cmudict.dict`, ~3MB) to `~/Library/Caches/Pointer/`.

Total first-launch download: roughly 350MB. Subsequent launches reuse the cache and start instantly.

During the Kokoro download, the app falls back to `AVSpeechSynthesizer`. Once Kokoro reports ready, it takes over automatically.

Expected console output on first warmed-up launch:

```
🎯 Pointer: Starting...
🎙️ Transcription: using WhisperKit (on-device)
🗣️ KokoroPhonemizer: loaded 134000 word pronunciations
🎤 KokoroTTS: ready (voice: af_heart, model: model_quantized.onnx)
🔊 LocalTTS: using voice "Ava (Premium)" (quality: Premium)
🔑 Pointer start — accessibility: true, ...
```

If you see `🎙️ Transcription: using Apple Speech` or no `🎤 KokoroTTS: ready` line, the SPM packages aren't fully wired — go back to step 1.

## 6. Verify the network path

After running it, hold push-to-talk and say something. The Xcode console should show only:

```
🌐 Claude streaming request: 0.3MB, 1 image(s)
🔊 KokoroTTS: playing 38400 samples (~1600ms)
```

No AssemblyAI websocket logs, no ElevenLabs TTS logs. Voice in and voice out are entirely local.

## 7. Pick a different Kokoro voice (optional)

The default is `af_heart` (American Female, the cleanest v1.0 voice). To switch, edit `KokoroTTSClient.defaultVoiceName` in `KokoroTTSClient.swift`. Available voices in the v1.0 release include:

- American Female: `af_heart`, `af_alloy`, `af_aoede`, `af_bella`, `af_jessica`, `af_kore`, `af_nicole`, `af_nova`, `af_river`, `af_sarah`, `af_sky`
- American Male: `am_adam`, `am_echo`, `am_eric`, `am_fenrir`, `am_liam`, `am_michael`, `am_onyx`, `am_puck`
- British Female: `bf_alice`, `bf_emma`, `bf_isabella`, `bf_lily`
- British Male: `bm_daniel`, `bm_fable`, `bm_george`, `bm_lewis`

Full list and voice samples at https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/tree/main/voices. Each voice file is ~520KB and downloads automatically on first use.

## 8. (Optional) Install premium fallback voices

When Kokoro is still downloading on first launch, Pointer uses `AVSpeechSynthesizer`. The macOS Premium voices sound much better than the default ones:

1. **System Settings → Accessibility → Spoken Content → System Voice → Customize…**
2. Find an English voice marked **(Premium)** (e.g., "Ava (Premium)", "Evan (Premium)").
3. Click the download icon. Each premium voice is ~100–200MB.
4. Restart Pointer.

## 9. Shrink the Cloudflare Worker

The worker now only proxies `/chat`. Delete the unused secrets:

```bash
cd worker
npx wrangler secret delete ASSEMBLYAI_API_KEY
npx wrangler secret delete ELEVENLABS_API_KEY
npx wrangler deploy
```

The only secret you still need is `ANTHROPIC_API_KEY`.

---

## Kokoro architecture notes

The Kokoro pipeline in this project consists of four files:

| File | Role |
|---|---|
| `KokoroTTSClient.swift` | Public entry point. Orchestrates phonemize → tokenize → ONNX inference → audio playback. Public API matches `LocalTTSClient` so callers don't know which engine is active. |
| `KokoroPhonemizer.swift` | Text → IPA phoneme string. Uses CMU Pronouncing Dictionary (downloaded once on first use) for word-level ARPAbet lookups, converts ARPAbet → IPA via a fixed mapping table, falls back to letter-by-letter pronunciation for unknown words. |
| `KokoroTokenizer.swift` | IPA phoneme string → `[Int64]` token ID sequence. Pads with leading/trailing silence tokens (ID 0). Vocabulary is Kokoro's fixed `$;:,.!?...ABC...abc...ɑɐɒ...` string. |
| `KokoroAssetDownloader.swift` | One-time download manager for the ONNX model and voice embedding files. Caches under `~/Library/Caches/Pointer/kokoro/`. |

The IPA phonemizer in this fork uses CMU dict + ARPAbet→IPA conversion. This covers >95% of common English words but is less accurate than upstream's `misaki` phonemizer (which is rule-based and handles unknown words better) or `espeak-ng`. If you find Kokoro pronouncing things oddly, the fix is usually to swap the phonemizer for a better one rather than to retrain Kokoro. The interface boundary between `KokoroPhonemizer` and `KokoroTTSClient` is narrow — only `phonemize(text:) async throws -> String` is called.

## Troubleshooting

**"ONNX Runtime not available" error** — The `onnxruntime` package isn't added to the target. Go back to step 1b.

**Kokoro outputs garbled audio** — Almost always a phonemizer issue (Kokoro is fed IPA that doesn't match what it was trained on). Check the console for what phonemes were generated by adding `print(phonemeString)` after the phonemize call in `KokoroTTSClient.speakText`. Compare against the IPA the upstream Python tools generate for the same text — if they differ, the ARPAbet→IPA mapping needs adjustment in `KokoroPhonemizer.arpabetToIPAMappings`.

**First-launch delay** — Downloads happen lazily on first model use. To download eagerly at app launch, call `Task { _ = try? await KokoroTTSClient() }` from `applicationDidFinishLaunching` so the user doesn't wait on their first push-to-talk.

**WhisperKit model is too big** — Switch to `openai_whisper-base.en` (~150MB) or `openai_whisper-tiny.en` (~75MB) by changing `whisperModelName` in `WhisperKitTranscriptionProvider.swift`. Quality drops noticeably below `base.en`.

**Higher-quality Kokoro** — Switch from the quantized model to the full FP16 model by changing the URL in `KokoroAssetDownloader.quantizedModelDownloadURL` from `model_quantized.onnx` to `model_fp16.onnx`. Roughly 2x quality, 3x model size, 2x inference latency.
