//
//  KokoroAssetDownloader.swift
//  leanring-buddy
//
//  Manages the one-time download of Kokoro-82M v1.0 ONNX assets on first
//  launch:
//
//    - model_quantized.onnx  (~88MB, INT8 quantized for fast Apple Silicon inference)
//    - voices/<voiceName>.bin (~520KB, per-voice style embedding)
//
//  Files are cached in `~/Library/Caches/Pointer/kokoro/`. Subsequent
//  launches reuse the cache and start instantly.
//
//  Source: https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX
//

import Foundation

actor KokoroAssetDownloader {
    enum KokoroAsset {
        case quantizedONNXModel
        case voiceStyleEmbedding(voiceName: String)
    }

    /// The quantized model is small enough to download in seconds and runs
    /// fast on Apple Silicon. The full FP32 model gives slightly better
    /// quality at ~300MB and 2-3x slower inference.
    private static let quantizedModelDownloadURL = URL(
        string: "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/main/onnx/model_quantized.onnx"
    )!

    private static func voiceStyleDownloadURL(voiceName: String) -> URL {
        return URL(
            string: "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/main/voices/\(voiceName).bin"
        )!
    }

    /// Root cache directory where all Kokoro assets live.
    let kokoroCacheDirectoryURL: URL

    init() {
        let cachesDirectoryURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first!
        self.kokoroCacheDirectoryURL = cachesDirectoryURL
            .appendingPathComponent("Pointer", isDirectory: true)
            .appendingPathComponent("kokoro", isDirectory: true)
    }

    /// Returns the local path for an asset, downloading it if not cached.
    func localFileURLForAsset(_ asset: KokoroAsset) async throws -> URL {
        try FileManager.default.createDirectory(
            at: kokoroCacheDirectoryURL,
            withIntermediateDirectories: true
        )

        let (localFileURL, remoteDownloadURL, humanReadableLabel) = filePathsForAsset(asset)

        if FileManager.default.fileExists(atPath: localFileURL.path) {
            return localFileURL
        }

        print("📥 Kokoro: downloading \(humanReadableLabel)…")
        let (downloadedFileURL, urlResponse) = try await URLSession.shared.download(
            from: remoteDownloadURL
        )
        guard let httpResponse = urlResponse as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "KokoroAssetDownloader", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to download \(humanReadableLabel) (HTTP \((urlResponse as? HTTPURLResponse)?.statusCode ?? 0))"
            ])
        }

        // The downloaded file lives in a temp dir — move it to our cache.
        try? FileManager.default.removeItem(at: localFileURL)
        try FileManager.default.moveItem(at: downloadedFileURL, to: localFileURL)
        print("📥 Kokoro: cached \(humanReadableLabel) at \(localFileURL.path)")
        return localFileURL
    }

    private func filePathsForAsset(_ asset: KokoroAsset) -> (localFileURL: URL, remoteDownloadURL: URL, humanReadableLabel: String) {
        switch asset {
        case .quantizedONNXModel:
            return (
                localFileURL: kokoroCacheDirectoryURL.appendingPathComponent("model_quantized.onnx"),
                remoteDownloadURL: Self.quantizedModelDownloadURL,
                humanReadableLabel: "Kokoro quantized ONNX model (~88MB)"
            )
        case .voiceStyleEmbedding(let voiceName):
            return (
                localFileURL: kokoroCacheDirectoryURL.appendingPathComponent("voices").appendingPathComponent("\(voiceName).bin"),
                remoteDownloadURL: Self.voiceStyleDownloadURL(voiceName: voiceName),
                humanReadableLabel: "Kokoro voice \"\(voiceName)\""
            )
        }
    }
}
