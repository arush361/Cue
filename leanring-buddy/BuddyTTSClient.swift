//
//  BuddyTTSClient.swift
//  leanring-buddy
//
//  Shared TTS-engine protocol so CompanionManager can iterate engines in
//  preference order without caring which is Kokoro vs AVSpeechSynthesizer.
//
//  This formalizes the duck-typed shape KokoroTTSClient + LocalTTSClient
//  already share (`speakText`, `stopPlayback`, `isPlaying`, `isReady`).
//

import Foundation

@MainActor
protocol BuddyTTSClient: AnyObject {
    /// True between the moment `speakText` starts playback and the engine
    /// finishes (or `stopPlayback` cancels it).
    var isPlaying: Bool { get }

    /// True once the engine is initialized and able to render audio. Kokoro
    /// only flips this true after the ONNX model download completes;
    /// LocalTTSClient is ready synchronously at init.
    var isReady: Bool { get }

    /// Speaks `text`. Returns once playback has started — callers can watch
    /// `isPlaying` for completion.
    func speakText(_ text: String) async throws

    /// Stops any in-progress playback immediately.
    func stopPlayback()
}
