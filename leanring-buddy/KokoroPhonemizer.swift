//
//  KokoroPhonemizer.swift
//  leanring-buddy
//
//  Converts English text into the IPA phoneme strings Kokoro-82M expects.
//
//  Strategy:
//  1. Tokenize text into words preserving punctuation.
//  2. For each word, look up its ARPAbet pronunciation in the CMU
//     Pronouncing Dictionary (cmudict, downloaded once and cached).
//  3. Translate ARPAbet → IPA via a fixed mapping table.
//  4. For words not in the dictionary, fall back to letter-by-letter
//     pronunciation. Quality drops for unknown words but the output
//     is still intelligible.
//
//  This is NOT as accurate as upstream's `misaki` or `espeak-ng` phonemizers,
//  both of which use rule-based grapheme-to-phoneme models. For commonly
//  spoken English the CMU dict covers >95% of word occurrences though, so
//  results are usable. If voice quality on uncommon words matters, swap
//  this for an `espeak-ng` Swift binding later.
//

import Foundation

actor KokoroPhonemizer {
    /// Where the CMU dict text file is cached after first download.
    private let cachedDictionaryFileURL: URL

    /// Word (lowercased) → ARPAbet phoneme sequence. Loaded lazily on first
    /// `phonemize` call. Empty until the dictionary is loaded — phonemize
    /// will then fall back to letter-by-letter for every word.
    private var arpabetDictionary: [String: String] = [:]
    private var isDictionaryLoaded = false

    init() {
        let cachesDirectoryURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first!
        self.cachedDictionaryFileURL = cachesDirectoryURL
            .appendingPathComponent("Pointer", isDirectory: true)
            .appendingPathComponent("cmudict.dict")
    }

    /// Ensures the CMU dictionary is loaded into memory. Downloads it once
    /// if not yet cached.
    func loadDictionaryIfNeeded() async throws {
        guard !isDictionaryLoaded else { return }

        if !FileManager.default.fileExists(atPath: cachedDictionaryFileURL.path) {
            try await downloadCMUDictionary()
        }

        let dictionaryContents = try String(contentsOf: cachedDictionaryFileURL, encoding: .utf8)
        arpabetDictionary = Self.parseCMUDict(rawText: dictionaryContents)
        isDictionaryLoaded = true
        print("🗣️ KokoroPhonemizer: loaded \(arpabetDictionary.count) word pronunciations")
    }

    /// Converts an English sentence into an IPA phoneme string suitable for
    /// `KokoroTokenizer.tokenize(phonemeString:)`. Spaces and punctuation
    /// are preserved (Kokoro uses them as prosody cues).
    func phonemize(text: String) async throws -> String {
        try await loadDictionaryIfNeeded()

        let parsedTextSegments = Self.tokenizeTextIntoWordsAndPunctuation(rawText: text)
        var phonemeOutputPieces: [String] = []

        for textSegment in parsedTextSegments {
            switch textSegment {
            case .word(let wordText):
                let lowercaseWord = wordText.lowercased()
                if let arpabetForWord = arpabetDictionary[lowercaseWord] {
                    phonemeOutputPieces.append(Self.convertARPAbetToIPA(arpabetSequence: arpabetForWord))
                } else {
                    // Word not in dictionary — pronounce it letter by letter.
                    phonemeOutputPieces.append(Self.pronounceUnknownWordByLetters(word: lowercaseWord))
                }
            case .punctuation(let punctuationCharacter):
                phonemeOutputPieces.append(String(punctuationCharacter))
            case .whitespace:
                phonemeOutputPieces.append(" ")
            }
        }

        return phonemeOutputPieces.joined()
    }

    // MARK: - Dictionary download

    /// CMU Pronouncing Dictionary download URL. Public domain, ~3MB.
    private static let cmuDictDownloadURL = URL(
        string: "https://raw.githubusercontent.com/cmusphinx/cmudict/master/cmudict.dict"
    )!

    private func downloadCMUDictionary() async throws {
        print("🗣️ KokoroPhonemizer: downloading CMU dict (one-time, ~3MB)…")
        let (downloadedData, urlResponse) = try await URLSession.shared.data(from: Self.cmuDictDownloadURL)
        guard let httpResponse = urlResponse as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "KokoroPhonemizer", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to download cmudict.dict"
            ])
        }
        try FileManager.default.createDirectory(
            at: cachedDictionaryFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try downloadedData.write(to: cachedDictionaryFileURL)
        print("🗣️ KokoroPhonemizer: dict cached at \(cachedDictionaryFileURL.path)")
    }

    // MARK: - Parsing

    /// Parses the cmudict.dict file format. Lines look like:
    /// `pointer P OY1 N T ER0`
    /// Words with multiple pronunciations have a `(2)` suffix on duplicates;
    /// we keep only the first pronunciation.
    private static func parseCMUDict(rawText: String) -> [String: String] {
        var dictionary: [String: String] = [:]
        for line in rawText.split(separator: "\n") {
            // Skip comments and blank lines.
            if line.isEmpty || line.first == ";" || line.first == "#" {
                continue
            }
            let lineParts = line.split(separator: " ", maxSplits: 1)
            guard lineParts.count == 2 else { continue }

            // Strip "(2)", "(3)" alternate-pronunciation suffix from the word.
            var wordSpelling = String(lineParts[0]).lowercased()
            if let parenthesisIndex = wordSpelling.firstIndex(of: "(") {
                wordSpelling = String(wordSpelling[..<parenthesisIndex])
            }
            let arpabetSequence = String(lineParts[1])

            // Keep only the first pronunciation we see for each word.
            if dictionary[wordSpelling] == nil {
                dictionary[wordSpelling] = arpabetSequence
            }
        }
        return dictionary
    }

    // MARK: - Tokenization

    private enum ParsedTextSegment {
        case word(String)
        case punctuation(Character)
        case whitespace
    }

    private static let kokoroPreservedPunctuation: Set<Character> = [
        ";", ":", ",", ".", "!", "?", "—", "…", "\"", "'"
    ]

    private static func tokenizeTextIntoWordsAndPunctuation(rawText: String) -> [ParsedTextSegment] {
        var parsedSegments: [ParsedTextSegment] = []
        var currentWordCharacters: [Character] = []

        func flushCurrentWord() {
            if !currentWordCharacters.isEmpty {
                parsedSegments.append(.word(String(currentWordCharacters)))
                currentWordCharacters.removeAll()
            }
        }

        for character in rawText {
            if character.isLetter || character == "'" {
                currentWordCharacters.append(character)
            } else if character.isWhitespace {
                flushCurrentWord()
                parsedSegments.append(.whitespace)
            } else if kokoroPreservedPunctuation.contains(character) {
                flushCurrentWord()
                parsedSegments.append(.punctuation(character))
            } else {
                // Drop other characters silently (digits, special symbols).
                flushCurrentWord()
            }
        }
        flushCurrentWord()
        return parsedSegments
    }

    // MARK: - ARPAbet → IPA conversion

    /// CMU dict gives ARPAbet symbols like "P OY1 N T ER0" (with stress
    /// markers 0/1/2). Kokoro expects IPA. This table is the standard
    /// mapping used by `misaki` and most ARPAbet→IPA converters.
    private static let arpabetToIPAMappings: [String: String] = [
        // Vowels
        "AA": "ɑ", "AE": "æ", "AH": "ʌ", "AO": "ɔ", "AW": "aʊ", "AY": "aɪ",
        "EH": "ɛ", "ER": "ɝ", "EY": "eɪ", "IH": "ɪ", "IY": "i",  "OW": "oʊ",
        "OY": "ɔɪ", "UH": "ʊ", "UW": "u",
        // Consonants
        "B": "b", "CH": "tʃ", "D": "d", "DH": "ð", "F": "f", "G": "ɡ",
        "HH": "h", "JH": "dʒ", "K": "k", "L": "l", "M": "m", "N": "n",
        "NG": "ŋ", "P": "p", "R": "ɹ", "S": "s", "SH": "ʃ", "T": "t",
        "TH": "θ", "V": "v", "W": "w", "Y": "j", "Z": "z", "ZH": "ʒ"
    ]

    private static func convertARPAbetToIPA(arpabetSequence: String) -> String {
        var ipaOutputCharacters: [String] = []
        // Stress goes BEFORE the syllable in IPA (ˈ for primary, ˌ for secondary).
        // We emit it before the next phoneme we see.
        var pendingStressMarker: String? = nil

        for arpabetSymbolRaw in arpabetSequence.split(separator: " ") {
            var arpabetSymbol = String(arpabetSymbolRaw)
            // Trailing digit = stress marker. Strip it and remember.
            if let lastCharacter = arpabetSymbol.last, lastCharacter.isNumber {
                let stressDigit = lastCharacter
                arpabetSymbol.removeLast()
                if stressDigit == "1" {
                    pendingStressMarker = "ˈ"
                } else if stressDigit == "2" {
                    pendingStressMarker = "ˌ"
                }
            }

            if let ipaEquivalent = arpabetToIPAMappings[arpabetSymbol] {
                if let stressMarker = pendingStressMarker {
                    ipaOutputCharacters.append(stressMarker)
                    pendingStressMarker = nil
                }
                ipaOutputCharacters.append(ipaEquivalent)
            }
        }
        return ipaOutputCharacters.joined()
    }

    // MARK: - Letter-by-letter fallback

    /// Last-resort pronunciation for words not in the dictionary. Maps each
    /// letter to its name-pronunciation in IPA. Quality is low (every word
    /// becomes a spelled-out acronym) but the model produces SOMETHING
    /// rather than silently dropping the word.
    private static let englishLetterPronunciations: [Character: String] = [
        "a": "eɪ",  "b": "bi",  "c": "si",  "d": "di",  "e": "i",
        "f": "ɛf",  "g": "dʒi", "h": "eɪtʃ","i": "aɪ",  "j": "dʒeɪ",
        "k": "keɪ", "l": "ɛl",  "m": "ɛm",  "n": "ɛn",  "o": "oʊ",
        "p": "pi",  "q": "kju", "r": "ɑɹ",  "s": "ɛs",  "t": "ti",
        "u": "ju",  "v": "vi",  "w": "ˈdʌbəlju", "x": "ɛks", "y": "waɪ",
        "z": "zi"
    ]

    private static func pronounceUnknownWordByLetters(word: String) -> String {
        var ipaPieces: [String] = []
        for letter in word {
            if let letterPronunciation = englishLetterPronunciations[letter] {
                ipaPieces.append(letterPronunciation)
            }
        }
        return ipaPieces.joined(separator: " ")
    }
}
