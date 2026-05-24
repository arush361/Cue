//
//  KokoroTokenizer.swift
//  leanring-buddy
//
//  Maps IPA phoneme strings to the integer token IDs that Kokoro-82M's ONNX
//  model expects on its `tokens` input. The vocabulary is a fixed string —
//  for each character of the phoneme sequence, its 1-based index in
//  `Self.tokenizerVocabulary` becomes the token ID. Characters outside the
//  vocab are dropped silently.
//
//  Reference: https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX
//  (matches the `_pad + _punctuation + _letters + _letters_ipa` construction
//  used by the upstream Python `kokoro-onnx` and `kokoro` packages).
//

import Foundation

enum KokoroTokenizer {
    /// The exact vocabulary Kokoro-82M was trained on. Index 0 (the "$"
    /// padding character) is reserved for silence at the boundaries.
    static let tokenizerVocabulary: String =
        "$" +
        ";:,.!?¡¿—…\"«»“” " +
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz" +
        "ɑɐɒæɓʙβɔɕçɗɖðʤəɘɚɛɜɝɞɟʄɡɠɢʛɦɧħɥʜɨɪʝɭɬɫɮʟɱɯɰŋɳɲɴøɵɸθœɶʘɹɺɾɻʀʁɽʂʃʈʧʉʊʋⱱʌɣɤʍχʎʏʑʐʒʔʡʕʢǀǁǂǃˈˌːˑʼʴʰʱʲʷˠˤ˞↓↑→↗↘'ᵻ"

    /// Pre-built lookup: phoneme character → token ID. Built once on first
    /// access to avoid O(n) `firstIndex(of:)` calls per character.
    private static let phonemeCharacterToTokenIdLookup: [Character: Int64] = {
        var lookup: [Character: Int64] = [:]
        for (zeroBasedIndex, vocabularyCharacter) in tokenizerVocabulary.enumerated() {
            lookup[vocabularyCharacter] = Int64(zeroBasedIndex)
        }
        return lookup
    }()

    /// Maximum number of phoneme tokens Kokoro can handle in a single forward
    /// pass. Longer inputs need to be chunked at sentence boundaries upstream.
    static let maximumTokenCountPerForwardPass: Int = 510

    /// Converts an IPA phoneme string into the int64 token sequence Kokoro
    /// expects. Pads the start and end with the silence token (0) — the
    /// model is trained with these boundary markers and quality drops
    /// audibly without them.
    static func tokenize(phonemeString: String) -> [Int64] {
        var tokenIds: [Int64] = [0]  // Leading silence token.

        for phonemeCharacter in phonemeString {
            if let tokenId = phonemeCharacterToTokenIdLookup[phonemeCharacter] {
                tokenIds.append(tokenId)
                if tokenIds.count >= maximumTokenCountPerForwardPass - 1 {
                    break
                }
            }
            // Unknown characters are silently dropped — they aren't part of
            // Kokoro's phoneme set so the model has no mapping for them.
        }

        tokenIds.append(0)  // Trailing silence token.
        return tokenIds
    }
}
