//  SentenceSplitter.swift
import Foundation
import NaturalLanguage

/// Splits article prose into sentences for per-utterance TTS rendering.
/// NLTokenizer handles abbreviations/locales far better than punctuation regexes.
///
/// Readability's `textContent` preserves the source HTML's hard line-wraps, and NLTokenizer
/// treats a single newline as a sentence boundary — turning a wrapped sentence into choppy
/// fragment cues. So splitting is paragraph-aware: blank lines (a real structural break, e.g.
/// between a heading/byline and body prose) stay hard boundaries, but single newlines *within*
/// a paragraph are just wrapping and get collapsed to a space before tokenizing.
enum SentenceSplitter {
    static func split(_ text: String) -> [String] {
        let paragraphs = text.split(separator: /\n\s*\n/, omittingEmptySubsequences: true)
        return paragraphs.flatMap { paragraph -> [String] in
            let normalized = normalizeWhitespace(String(paragraph))
            guard !normalized.isEmpty else { return [] }
            return sentences(in: normalized)
        }
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func sentences(in text: String) -> [String] {
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
