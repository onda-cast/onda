//  CueTextStylerTests.swift
import XCTest
import UIKit
@testable import Onda

@MainActor
final class CueTextStylerTests: XCTestCase {
    private let font = UIFont.systemFont(ofSize: 16)
    private lazy var style = CueTextStyler.Style(font: font, base: .gray, emphasis: .black, accent: .green)

    private func attrs(_ s: NSAttributedString, at location: Int) -> [NSAttributedString.Key: Any] {
        s.attributes(at: location, effectiveRange: nil)
    }

    func test_plainText_usesBaseColorAndFontThroughout() {
        let s = CueTextStyler.attributed(text: "Hello world", words: nil, activeWordIndex: nil,
                                         searchQuery: "", style: style)
        XCTAssertEqual(s.string, "Hello world")
        XCTAssertEqual(attrs(s, at: 0)[.foregroundColor] as? UIColor, .gray)
        XCTAssertEqual(attrs(s, at: 10)[.foregroundColor] as? UIColor, .gray)
        XCTAssertEqual(attrs(s, at: 0)[.font] as? UIFont, font)
    }

    func test_searchQuery_boldsAndAccentsMatchRuns() {
        let s = CueTextStyler.attributed(text: "The mold genus", words: nil, activeWordIndex: nil,
                                         searchQuery: "mold", style: style)
        XCTAssertEqual(s.string, "The mold genus")
        // "The " — base
        XCTAssertEqual(attrs(s, at: 0)[.foregroundColor] as? UIColor, .gray)
        // "mold" — accent + bold
        let matchFont = attrs(s, at: 4)[.font] as? UIFont
        XCTAssertEqual(attrs(s, at: 4)[.foregroundColor] as? UIColor, .green)
        XCTAssertTrue(matchFont?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false)
        XCTAssertEqual(matchFont?.pointSize, font.pointSize)
        // " genus" — base again
        XCTAssertEqual(attrs(s, at: 9)[.foregroundColor] as? UIColor, .gray)
    }

    func test_words_activeWordGetsEmphasisColor_othersBase() {
        let words = [WordTiming(text: "alpha", startTime: 0, endTime: 1),
                     WordTiming(text: "beta", startTime: 1, endTime: 2),
                     WordTiming(text: "gamma", startTime: 2, endTime: 3)]
        let s = CueTextStyler.attributed(text: "alpha beta gamma", words: words, activeWordIndex: 1,
                                         searchQuery: "", style: style)
        XCTAssertEqual(s.string, "alpha beta gamma")     // joined by single spaces
        XCTAssertEqual(attrs(s, at: 0)[.foregroundColor] as? UIColor, .gray)   // "alpha"
        XCTAssertEqual(attrs(s, at: 6)[.foregroundColor] as? UIColor, .black)  // "beta"
        XCTAssertEqual(attrs(s, at: 11)[.foregroundColor] as? UIColor, .gray)  // "gamma"
    }

    func test_searchQuery_takesPrecedenceOverWords() {
        let words = [WordTiming(text: "alpha", startTime: 0, endTime: 1),
                     WordTiming(text: "beta", startTime: 1, endTime: 2)]
        let s = CueTextStyler.attributed(text: "alpha beta", words: words, activeWordIndex: 0,
                                         searchQuery: "beta", style: style)
        // Search styling path: match run accented, everything else base — no word emphasis.
        XCTAssertEqual(attrs(s, at: 0)[.foregroundColor] as? UIColor, .gray)
        XCTAssertEqual(attrs(s, at: 6)[.foregroundColor] as? UIColor, .green)
    }

    func test_noActiveWord_allWordsBaseColor() {
        let words = [WordTiming(text: "alpha", startTime: 0, endTime: 1)]
        let s = CueTextStyler.attributed(text: "alpha", words: words, activeWordIndex: nil,
                                         searchQuery: "", style: style)
        XCTAssertEqual(attrs(s, at: 0)[.foregroundColor] as? UIColor, .gray)
    }
}
