//  SentenceSplitter.swift
import Foundation
import NaturalLanguage

/// Splits article prose into sentences for per-utterance TTS rendering.
/// NLTokenizer handles abbreviations/locales far better than punctuation regexes.
enum SentenceSplitter {
    static func split(_ text: String) -> [String] {
        var sentences: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { sentences.append(s) }
            return true
        }
        return sentences
    }
}
