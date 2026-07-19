# Transcript In-Panel Search & Word Lookup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Cmd-F-style find & jump inside the transcript panel, and make cue text natively selectable (long-press a word → system Look Up / Search Web menu).

**Architecture:** Pure match logic lives in a new `TranscriptFind` enum (mirroring the existing `ActiveCue` idiom). Cue text in read mode renders through a new `SelectableCueText` UIViewRepresentable (non-editable, selectable `UITextView`) fed by an `NSAttributedString` styler that layers active-word and search-match emphasis. `TranscriptView` gains search state, a top search bar (`BrutalSearchField` + counter + chevrons), and scroll wiring.

**Tech Stack:** SwiftUI, UIKit interop (`UIViewRepresentable`/`UITextView`), XCTest, XcodeGen, SwiftLint.

**Spec:** `docs/superpowers/specs/2026-07-18-transcript-ui-search-and-lookup-design.md`

## Global Constraints

- iOS 17+ deployment target; SwiftData models untouched — this plan changes no models, no networking.
- `Onda.xcodeproj` is generated: after adding any file, run `xcodegen generate` before building.
- Build/test destination on this Mac must be a **dedicated simulator** with isolated DerivedData (sibling agents contend the stock "iPhone 17"): create via `xcrun simctl create`, pass `-destination "id=$UDID" -derivedDataPath <scratch>`. See `~/.claude/.../memory/simulator-contention.md`.
- Unit tests only for this feature's logic; run with `-only-testing:OndaTests/<ClassName>` (never the whole suite — `OndaTests/SpeechEngineReproTests` hangs without a TCC record).
- Use `.scaledFont(size, weight:)` for SwiftUI text and `@ScaledMetric(relativeTo: .body)` for the UIKit font size so Dynamic Type honors the app-wide `.accessibility1` cap.
- Colors via `theme.color(_:)`; the neo-brutalist style helpers (`brutalBorder`) as used in `TranscriptView` today.
- The canonical timeline is feed-seconds; nothing in this plan converts or stores times.
- Commit after each task with the message given in the task.

## Existing code you will touch (read these first)

- `Onda/Player/TranscriptView.swift` — the whole feature surface. Cue snapshot (`CueVM`), row
  rendering (`cueRow`), `styledCueText`, auto-follow scroll logic, clip Select mode, toolbar.
- `Onda/Transcription/ActiveCue.swift` — the idiom `TranscriptFind` mirrors.
- `Onda/Theme/BrutalSearchField.swift` — shared search field; signature
  `BrutalSearchField(_ placeholder: String, text: Binding<String>, focus: FocusState<Bool>.Binding? = nil)`.
- `Onda/Models/Transcript.swift` — `WordTiming { text, startTime, endTime }`.
- `OndaTests/ActiveCueTests.swift` — test style to match (XCTest, `@MainActor`, terse `func test_…`).

---

### Task 1: `TranscriptFind` match logic (TDD)

**Files:**
- Create: `Onda/Transcription/TranscriptFind.swift`
- Test: `OndaTests/TranscriptFindTests.swift`

**Interfaces:**
- Consumes: nothing (pure Foundation).
- Produces (used by Tasks 2 & 3):
  - `TranscriptFind.Segment` — `struct { let text: String; let isMatch: Bool }`, `Equatable`.
  - `TranscriptFind.matchingIndices(query: String, in texts: [String]) -> [Int]`
  - `TranscriptFind.segments(of text: String, query: String) -> [TranscriptFind.Segment]`

- [ ] **Step 1: Write the failing tests**

Create `OndaTests/TranscriptFindTests.swift`:

```swift
//  TranscriptFindTests.swift
import XCTest
@testable import Onda

final class TranscriptFindTests: XCTestCase {
    private let texts = [
        "Welcome back to the show today",          // 0
        "Penicillin was discovered by accident",   // 1
        "The mold genus is Penicillium",           // 2
        "Nothing relevant here",                   // 3
    ]

    // matchingIndices
    func test_matchingIndices_caseInsensitive() {
        XCTAssertEqual(TranscriptFind.matchingIndices(query: "penicill", in: texts), [1, 2])
    }
    func test_matchingIndices_emptyQuery_matchesNothing() {
        XCTAssertEqual(TranscriptFind.matchingIndices(query: "", in: texts), [])
    }
    func test_matchingIndices_whitespaceQuery_matchesNothing() {
        XCTAssertEqual(TranscriptFind.matchingIndices(query: "   ", in: texts), [])
    }
    func test_matchingIndices_noHits() {
        XCTAssertEqual(TranscriptFind.matchingIndices(query: "zebra", in: texts), [])
    }
    func test_matchingIndices_trimsQueryBeforeMatching() {
        XCTAssertEqual(TranscriptFind.matchingIndices(query: " mold ", in: texts), [2])
    }

    // segments
    func test_segments_splitsAroundMatch() {
        XCTAssertEqual(
            TranscriptFind.segments(of: "The mold genus", query: "mold"),
            [.init(text: "The ", isMatch: false),
             .init(text: "mold", isMatch: true),
             .init(text: " genus", isMatch: false)])
    }
    func test_segments_matchIsCaseInsensitive_preservesOriginalCasing() {
        XCTAssertEqual(
            TranscriptFind.segments(of: "Penicillin and penicillium", query: "PENICILL"),
            [.init(text: "Penicill", isMatch: true),
             .init(text: "in and ", isMatch: false),
             .init(text: "penicill", isMatch: true),
             .init(text: "ium", isMatch: false)])
    }
    func test_segments_noMatch_returnsWholeTextUnmatched() {
        XCTAssertEqual(TranscriptFind.segments(of: "Hello there", query: "zebra"),
                       [.init(text: "Hello there", isMatch: false)])
    }
    func test_segments_emptyQuery_returnsWholeTextUnmatched() {
        XCTAssertEqual(TranscriptFind.segments(of: "Hello", query: ""),
                       [.init(text: "Hello", isMatch: false)])
    }
    func test_segments_matchAtStartAndEnd() {
        XCTAssertEqual(
            TranscriptFind.segments(of: "ha in the middle ha", query: "ha"),
            [.init(text: "ha", isMatch: true),
             .init(text: " in the middle ", isMatch: false),
             .init(text: "ha", isMatch: true)])
    }
    func test_segments_reassembleToOriginalText() {
        let original = "Alexander Fleming noticed a contaminated petri dish"
        let joined = TranscriptFind.segments(of: original, query: "a").map(\.text).joined()
        XCTAssertEqual(joined, original)
    }
}
```

- [ ] **Step 2: Create the implementation file so the target compiles, regenerate the project, run tests to verify they fail**

Create `Onda/Transcription/TranscriptFind.swift` with stubs that compile but fail:

```swift
//  TranscriptFind.swift
import Foundation

enum TranscriptFind {
    struct Segment: Equatable {
        let text: String
        let isMatch: Bool
    }

    static func matchingIndices(query: String, in texts: [String]) -> [Int] { [] }
    static func segments(of text: String, query: String) -> [Segment] { [] }
}
```

Run:

```sh
xcodegen generate
RUNTIME=$(xcrun simctl list runtimes | grep -o 'com.apple.CoreSimulator.SimRuntime.iOS[^ )]*' | tail -1)
UDID=$(xcrun simctl create onda-tsearch com.apple.CoreSimulator.SimDeviceType.iPhone-17 "$RUNTIME")
echo "$UDID"   # reuse this UDID for every later build/test step; delete it in the final task
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination "id=$UDID" \
  -derivedDataPath /tmp/onda-tsearch-dd -only-testing:OndaTests/TranscriptFindTests 2>&1 | tail -20
```

Expected: TEST FAILED — the `matchingIndices` and non-empty `segments` assertions fail (stubs return `[]`).

- [ ] **Step 3: Implement `TranscriptFind`**

Replace the stub bodies:

```swift
//  TranscriptFind.swift
import Foundation

/// Pure in-transcript find logic (same idiom as ActiveCue: no SwiftData, no view state).
/// Matching is a case-insensitive substring scan — the transcript is already in memory,
/// so no FTS involvement.
enum TranscriptFind {
    struct Segment: Equatable {
        let text: String
        let isMatch: Bool
    }

    /// Indices (into `texts`) of entries containing `query`, in order. Empty/whitespace
    /// queries match nothing.
    static func matchingIndices(query: String, in texts: [String]) -> [Int] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return texts.indices.filter { texts[$0].range(of: q, options: .caseInsensitive) != nil }
    }

    /// Splits `text` into consecutive runs marked match/non-match for every occurrence of
    /// `query` (case-insensitive). Segments always reassemble to the original text.
    static func segments(of text: String, query: String) -> [Segment] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [Segment(text: text, isMatch: false)] }
        var result: [Segment] = []
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let r = text.range(of: q, options: .caseInsensitive, range: cursor..<text.endIndex) {
            if r.lowerBound > cursor {
                result.append(Segment(text: String(text[cursor..<r.lowerBound]), isMatch: false))
            }
            result.append(Segment(text: String(text[r]), isMatch: true))
            cursor = r.upperBound
        }
        if cursor < text.endIndex {
            result.append(Segment(text: String(text[cursor...]), isMatch: false))
        }
        return result.isEmpty ? [Segment(text: text, isMatch: false)] : result
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```sh
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination "id=$UDID" \
  -derivedDataPath /tmp/onda-tsearch-dd -only-testing:OndaTests/TranscriptFindTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **` (12 tests).

- [ ] **Step 5: Commit**

```sh
git add Onda/Transcription/TranscriptFind.swift OndaTests/TranscriptFindTests.swift Onda.xcodeproj
git commit -m "Transcript find: pure match/segment logic"
```

---

### Task 2: `SelectableCueText` — UITextView wrapper + attributed styler (TDD for the styler)

**Files:**
- Create: `Onda/Player/SelectableCueText.swift`
- Test: `OndaTests/CueTextStylerTests.swift`

**Interfaces:**
- Consumes: `TranscriptFind.segments(of:query:)` (Task 1), `WordTiming` (existing model).
- Produces (used by Task 3):
  - `CueTextStyler.attributed(text: String, words: [WordTiming]?, activeWordIndex: Int?, searchQuery: String, font: UIFont, baseColor: UIColor, emphasisColor: UIColor, accentColor: UIColor) -> NSAttributedString`
  - `SelectableCueText(attributed: NSAttributedString, onTap: @escaping () -> Void)` — a `UIViewRepresentable`.

Styling precedence (from the spec): when `searchQuery` is non-empty → search-match emphasis
(accent color + bold) over the plain cue text, no word-level coloring. Otherwise, if
`words != nil` → per-word coloring with `activeWordIndex` in `emphasisColor` and the rest in
`baseColor` (the existing active-cue behavior). Otherwise the whole string in `baseColor`.

- [ ] **Step 1: Write the failing styler tests**

Create `OndaTests/CueTextStylerTests.swift`:

```swift
//  CueTextStylerTests.swift
import XCTest
import UIKit
@testable import Onda

@MainActor
final class CueTextStylerTests: XCTestCase {
    private let font = UIFont.systemFont(ofSize: 16)

    private func attrs(_ s: NSAttributedString, at location: Int) -> [NSAttributedString.Key: Any] {
        s.attributes(at: location, effectiveRange: nil)
    }

    func test_plainText_usesBaseColorAndFontThroughout() {
        let s = CueTextStyler.attributed(text: "Hello world", words: nil, activeWordIndex: nil,
                                         searchQuery: "", font: font,
                                         baseColor: .gray, emphasisColor: .black, accentColor: .green)
        XCTAssertEqual(s.string, "Hello world")
        XCTAssertEqual(attrs(s, at: 0)[.foregroundColor] as? UIColor, .gray)
        XCTAssertEqual(attrs(s, at: 10)[.foregroundColor] as? UIColor, .gray)
        XCTAssertEqual(attrs(s, at: 0)[.font] as? UIFont, font)
    }

    func test_searchQuery_boldsAndAccentsMatchRuns() {
        let s = CueTextStyler.attributed(text: "The mold genus", words: nil, activeWordIndex: nil,
                                         searchQuery: "mold", font: font,
                                         baseColor: .gray, emphasisColor: .black, accentColor: .green)
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
                                         searchQuery: "", font: font,
                                         baseColor: .gray, emphasisColor: .black, accentColor: .green)
        XCTAssertEqual(s.string, "alpha beta gamma")     // joined by single spaces
        XCTAssertEqual(attrs(s, at: 0)[.foregroundColor] as? UIColor, .gray)   // "alpha"
        XCTAssertEqual(attrs(s, at: 6)[.foregroundColor] as? UIColor, .black)  // "beta"
        XCTAssertEqual(attrs(s, at: 11)[.foregroundColor] as? UIColor, .gray)  // "gamma"
    }

    func test_searchQuery_takesPrecedenceOverWords() {
        let words = [WordTiming(text: "alpha", startTime: 0, endTime: 1),
                     WordTiming(text: "beta", startTime: 1, endTime: 2)]
        let s = CueTextStyler.attributed(text: "alpha beta", words: words, activeWordIndex: 0,
                                         searchQuery: "beta", font: font,
                                         baseColor: .gray, emphasisColor: .black, accentColor: .green)
        // Search styling path: match run accented, everything else base — no word emphasis.
        XCTAssertEqual(attrs(s, at: 0)[.foregroundColor] as? UIColor, .gray)
        XCTAssertEqual(attrs(s, at: 6)[.foregroundColor] as? UIColor, .green)
    }

    func test_noActiveWord_allWordsBaseColor() {
        let words = [WordTiming(text: "alpha", startTime: 0, endTime: 1)]
        let s = CueTextStyler.attributed(text: "alpha", words: words, activeWordIndex: nil,
                                         searchQuery: "", font: font,
                                         baseColor: .gray, emphasisColor: .black, accentColor: .green)
        XCTAssertEqual(attrs(s, at: 0)[.foregroundColor] as? UIColor, .gray)
    }
}
```

- [ ] **Step 2: Create `SelectableCueText.swift` with a styler stub, regenerate, run tests to verify they fail**

Create `Onda/Player/SelectableCueText.swift` containing (full wrapper now, stub styler — the
wrapper is exercised in Task 3's build and the simulator pass):

```swift
//  SelectableCueText.swift
import SwiftUI
import UIKit

/// Attributed-string builder for transcript cue text. Pure so it can be unit-tested; the
/// styling precedence is: search-match emphasis (accent + bold) wins over per-word active
/// emphasis, which wins over plain base color.
enum CueTextStyler {
    static func attributed(text: String, words: [WordTiming]?, activeWordIndex: Int?,
                           searchQuery: String, font: UIFont,
                           baseColor: UIColor, emphasisColor: UIColor,
                           accentColor: UIColor) -> NSAttributedString {
        NSAttributedString(string: text)
    }
}

/// A non-editable, non-scrolling UITextView so cue text gets REAL native text selection —
/// long-press selects the word under the finger and the system menu offers Look Up /
/// Search Web / Translate. (SwiftUI `.textSelection` on iOS only offers whole-string
/// Copy/Share — spiked and rejected; see the design doc.)
struct SelectableCueText: UIViewRepresentable {
    let attributed: NSAttributedString
    let onTap: () -> Void

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.dataDetectorTypes = []
        tv.adjustsFontForContentSizeCategory = false   // font is pre-scaled via @ScaledMetric
        // Compression resistance off so long cues wrap instead of forcing row width.
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap))
        tv.addGestureRecognizer(tap)
        context.coordinator.textView = tv
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.onTap = onTap
        // Setting attributedText clears any selection, so skip no-op updates (playback ticks
        // re-render the row; don't stomp an in-progress selection unless the text changed).
        if tv.attributedText != attributed { tv.attributedText = attributed }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: fitted.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    final class Coordinator: NSObject {
        var onTap: () -> Void
        weak var textView: UITextView?
        init(onTap: @escaping () -> Void) { self.onTap = onTap }

        @objc func handleTap() {
            // A tap while text is selected clears the selection (standard iOS behavior)
            // instead of jumping playback out from under the user.
            if let tv = textView, tv.selectedRange.length > 0 {
                tv.selectedTextRange = nil
                return
            }
            onTap()
        }
    }
}
```

Run:

```sh
xcodegen generate
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination "id=$UDID" \
  -derivedDataPath /tmp/onda-tsearch-dd -only-testing:OndaTests/CueTextStylerTests 2>&1 | tail -20
```

Expected: TEST FAILED — attribute assertions fail (stub sets no attributes).

- [ ] **Step 3: Implement the styler**

Replace the `CueTextStyler` stub body:

```swift
enum CueTextStyler {
    static func attributed(text: String, words: [WordTiming]?, activeWordIndex: Int?,
                           searchQuery: String, font: UIFont,
                           baseColor: UIColor, emphasisColor: UIColor,
                           accentColor: UIColor) -> NSAttributedString {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            // Search styling: accent + bold on match runs over the plain cue text.
            let bold = UIFont.systemFont(ofSize: font.pointSize, weight: .bold)
            let result = NSMutableAttributedString()
            for seg in TranscriptFind.segments(of: text, query: query) {
                result.append(NSAttributedString(
                    string: seg.text,
                    attributes: [.font: seg.isMatch ? bold : font,
                                 .foregroundColor: seg.isMatch ? accentColor : baseColor]))
            }
            return result
        }
        if let words, !words.isEmpty {
            // Active-cue word emphasis: the currently-spoken word in emphasisColor.
            let result = NSMutableAttributedString()
            for (i, w) in words.enumerated() {
                let prefix = i == 0 ? "" : " "
                result.append(NSAttributedString(
                    string: prefix + w.text,
                    attributes: [.font: font,
                                 .foregroundColor: i == activeWordIndex ? emphasisColor : baseColor]))
            }
            return result
        }
        return NSAttributedString(string: text,
                                  attributes: [.font: font, .foregroundColor: baseColor])
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```sh
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination "id=$UDID" \
  -derivedDataPath /tmp/onda-tsearch-dd -only-testing:OndaTests/CueTextStylerTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **` (5 tests).

- [ ] **Step 5: Commit**

```sh
git add Onda/Player/SelectableCueText.swift OndaTests/CueTextStylerTests.swift Onda.xcodeproj
git commit -m "Transcript: UITextView-backed selectable cue text + attributed styler"
```

---

### Task 3: Wire `SelectableCueText` into the transcript rows

**Files:**
- Modify: `Onda/Player/TranscriptView.swift`

**Interfaces:**
- Consumes: `SelectableCueText`, `CueTextStyler` (Task 2).
- Produces: read-mode rows render selectable text; `styledCueText` is deleted. Row/tap/clip
  behavior otherwise unchanged. (Task 4 later feeds a real `query` into the styler — in this
  task the styler is called with `searchQuery: ""`.)

- [ ] **Step 1: Add the scaled font metric and UIKit color bridge to `TranscriptView`**

In `Onda/Player/TranscriptView.swift`, below the `@State` block, add:

```swift
    // UIKit-side equivalent of .scaledFont(16): @ScaledMetric honors Dynamic Type and the
    // app-wide cap, and the resulting UIFont feeds the attributed cue text.
    @ScaledMetric(relativeTo: .body) private var cueFontSize: CGFloat = 16
```

- [ ] **Step 2: Replace the cue-text rendering in `cueRow`**

In `cueRow`, replace:

```swift
                styledCueText(cue, isActiveCue: i == activeIndex)
                    .scaledFont(16)
                    .foregroundStyle(i == activeIndex ? theme.color(.text) : theme.color(.textTertiary))
```

with:

```swift
                if selecting {
                    Text(cue.text)
                        .scaledFont(16)
                        .foregroundStyle(i == activeIndex ? theme.color(.text) : theme.color(.textTertiary))
                } else {
                    SelectableCueText(
                        attributed: CueTextStyler.attributed(
                            text: cue.text,
                            words: i == activeIndex ? cue.words : nil,
                            activeWordIndex: i == activeIndex ? activeWordIndex(for: cue) : nil,
                            searchQuery: "",
                            font: .systemFont(ofSize: cueFontSize),
                            baseColor: UIColor(theme.color(i == activeIndex ? .text : .textTertiary)),
                            emphasisColor: UIColor(theme.color(.text)),
                            accentColor: UIColor(theme.color(.accent))),
                        onTap: { playback.jumpFromTranscript(episode: episode, to: cue.start) })
                }
```

Note the word-emphasis inputs replicate the old `styledCueText` guard (`words` only when the cue
is active): for the active cue the styler receives the word list and active index; for inactive
cues it renders plain base-colored text.

- [ ] **Step 3: Delete `styledCueText`**

Remove the whole `private func styledCueText(_ cue: CueVM, isActiveCue: Bool) -> Text` function —
nothing references it after Step 2.

Keep the existing `.onTapGesture` row handler as-is: in read mode a tap on the row *outside* the
text view (padding, timestamp, speaker) still jumps, and the text view's own tap recognizer covers
taps on the text. In Select mode the row tap still picks clip ranges (the plain `Text` branch has
no competing recognizer).

- [ ] **Step 4: Build**

```sh
xcodebuild build -project Onda.xcodeproj -scheme Onda -destination "id=$UDID" \
  -derivedDataPath /tmp/onda-tsearch-dd 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Run the existing transcript-adjacent unit tests (regression)**

```sh
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination "id=$UDID" \
  -derivedDataPath /tmp/onda-tsearch-dd \
  -only-testing:OndaTests/ActiveCueTests -only-testing:OndaTests/TranscriptFindTests \
  -only-testing:OndaTests/CueTextStylerTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```sh
git add Onda/Player/TranscriptView.swift
git commit -m "Transcript: render read-mode cues through SelectableCueText"
```

---

### Task 4: In-panel search — state, bar, matching, jump, highlight

**Files:**
- Modify: `Onda/Player/TranscriptView.swift`

**Interfaces:**
- Consumes: `TranscriptFind.matchingIndices` (Task 1), `BrutalSearchField` (existing),
  `CueTextStyler` via the Task 3 call site (the `searchQuery:` argument goes live here).
- Produces: the finished feature; nothing downstream.

- [ ] **Step 1: Add search state**

In the `@State` block of `TranscriptView`, add:

```swift
    @State private var searching = false
    @State private var query = ""
    @State private var matchIndices: [Int] = []
    @State private var currentMatch = 0
    @FocusState private var searchFocused: Bool
```

- [ ] **Step 2: Add the toolbar magnifier and make the modes mutually exclusive**

Replace the existing single `ToolbarItem` block in `.toolbar { … }` with:

```swift
                if transcript != nil, !(transcript?.cues.isEmpty ?? true) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            if searching { closeSearch() } else {
                                searching = true
                                resetSelection()          // search and clip-select are exclusive
                                selecting = false
                                searchFocused = true
                            }
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .accessibilityLabel(searching ? "Close search" : "Search transcript")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(selecting ? "Done" : "Select") {
                            selecting.toggle(); selStart = nil; selEnd = nil
                            if selecting { closeSearch() }   // entering select mode closes search
                        }
                    }
                }
```

(`resetSelection()` also sets `selecting = false`; calling it before `selecting = false` keeps the
intent explicit.)

- [ ] **Step 3: Add the search bar as a top inset**

On the `Group` inside the `NavigationStack` (the one holding
`transcriptList`/`progressState`/`emptyState`), directly after `.navigationBarTitleDisplayMode(.inline)`, add:

```swift
            .safeAreaInset(edge: .top) {
                if searching {
                    HStack(spacing: 10) {
                        BrutalSearchField("Find in transcript", text: $query, focus: $searchFocused)
                        Text(matchCounterText)
                            .scaledFont(13, weight: .semibold).monospacedDigit()
                            .foregroundStyle(theme.color(.textSecondary))
                            .fixedSize()
                        Button { prevMatch() } label: {
                            Image(systemName: "chevron.up").scaledFont(14, weight: .bold)
                                .foregroundStyle(theme.color(matchIndices.isEmpty ? .textTertiary : .accent))
                                .frame(width: 36, height: 36)
                                .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                        }
                        .buttonStyle(.plain).disabled(matchIndices.isEmpty)
                        .accessibilityLabel("Previous match")
                        Button { nextMatch() } label: {
                            Image(systemName: "chevron.down").scaledFont(14, weight: .bold)
                                .foregroundStyle(theme.color(matchIndices.isEmpty ? .textTertiary : .accent))
                                .frame(width: 36, height: 36)
                                .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                        }
                        .buttonStyle(.plain).disabled(matchIndices.isEmpty)
                        .accessibilityLabel("Next match")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(theme.color(.bg))
                }
            }
```

- [ ] **Step 4: Add search helpers**

Next to `resetSelection()`, add:

```swift
    private var matchCounterText: String {
        matchIndices.isEmpty ? "0 / 0" : "\(currentMatch + 1) / \(matchIndices.count)"
    }

    private func closeSearch() {
        searching = false; query = ""; matchIndices = []; currentMatch = 0
    }

    private func recomputeMatches() {
        matchIndices = TranscriptFind.matchingIndices(query: query, in: cueVMs.map(\.text))
        currentMatch = 0
    }

    private func nextMatch() {
        guard !matchIndices.isEmpty else { return }
        currentMatch = (currentMatch + 1) % matchIndices.count
    }

    private func prevMatch() {
        guard !matchIndices.isEmpty else { return }
        currentMatch = (currentMatch - 1 + matchIndices.count) % matchIndices.count
    }

    /// Cue index of the current match (nil when not searching / no matches).
    private var currentMatchCue: Int? {
        guard searching, !matchIndices.isEmpty, currentMatch < matchIndices.count else { return nil }
        return matchIndices[currentMatch]
    }
```

- [ ] **Step 5: Wire matching + scroll into `transcriptList`**

Inside `transcriptList`'s `ScrollViewReader`, on the `ScrollView` (alongside the existing
`.onChange(of: activeIndex)`), add:

```swift
            .onChange(of: query) { _, _ in recomputeMatches() }
            .onChange(of: currentMatchCue) { _, new in
                // Search-driven scrolls always fire — they bypass the auto-follow throttle.
                guard let new else { return }
                withAnimation { proxy.scrollTo(new, anchor: .center) }
            }
```

And suspend playback auto-follow while searching by extending the existing guard in
`.onChange(of: activeIndex)`:

```swift
            .onChange(of: activeIndex) { _, new in
                guard let new, isFollowing, !searching,
                      Date.now.timeIntervalSince(lastUserScrollAt) > 4 else { return }
                withAnimation { proxy.scrollTo(new, anchor: .center) }
            }
```

- [ ] **Step 6: Feed the live query into the row rendering**

In `cueRow` (Task 3's `SelectableCueText` branch), change `searchQuery: ""` to
`searchQuery: searching ? query : ""`.

Add the current-match row wash: replace the row `.background(…)` expression with:

```swift
        .background(
            (selecting && (selectionRange?.contains(i) ?? false))
                ? theme.color(.accentWash)
                : (i == currentMatchCue || (i == activeIndex && !selecting && !searching)
                    ? theme.color(.accentWash) : .clear))
```

(While searching, the current match gets the wash and the playback wash is suppressed; when not
searching, `currentMatchCue` is nil and behavior is exactly as before.)

- [ ] **Step 7: Build and run the feature's unit tests**

```sh
xcodebuild build -project Onda.xcodeproj -scheme Onda -destination "id=$UDID" \
  -derivedDataPath /tmp/onda-tsearch-dd 2>&1 | tail -3
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination "id=$UDID" \
  -derivedDataPath /tmp/onda-tsearch-dd \
  -only-testing:OndaTests/TranscriptFindTests -only-testing:OndaTests/CueTextStylerTests 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit**

```sh
git add Onda/Player/TranscriptView.swift
git commit -m "Transcript: in-panel find & jump (search bar, counter, chevrons, highlight)"
```

---

### Task 5: Lint + full simulator verification

**Files:**
- Modify: possibly small fixes surfaced by lint/verification (any file touched above).

**Interfaces:**
- Consumes: everything above.
- Produces: verified feature; evidence for the final report.

- [ ] **Step 1: SwiftLint**

```sh
swiftlint lint 2>&1 | grep -E "TranscriptView|SelectableCueText|TranscriptFind" || echo "clean"
```

Expected: `clean` (fix any violations in the new/changed files and re-run; commit fixes with
`git commit -am "Lint fixes for transcript search/lookup"`).

- [ ] **Step 2: Simulator verification (verify skill flow)**

Use the `verify` skill's build+install+launch flow on the dedicated `$UDID` device. A local test
feed already exists from the design spike — reuse it (serve
`<scratchpad>/feed/` with `python3 -m http.server 8737`, add
`http://localhost:8737/feed.xml` via Discover → add-by-URL if the show isn't already subscribed
on the device). Then, in the episode's transcript:

Selection/lookup checks:
- Long-press a word in a cue → the word alone is selected with drag handles; the system menu
  shows **Look Up / Search Web** (possibly behind the menu's overflow arrow) — the core spike
  criterion.
- Tap a cue's text → player jumps (transcript sheet dismisses via the jump nonce).
- With a selection active, tap once → selection clears, NO jump.
- Scroll the list with a drag starting on cue text → scrolls normally.
- "Select" mode → tap two lines → clip bar appears; long-press in Select mode does nothing.

Search checks:
- Magnifier → search bar appears with focus; type `peni` → counter shows `1 / N`-style count,
  first matching cue scrolls to center with `peni` runs in accent bold and the row washed.
- Chevron down/up walk the matches (wrap at both ends), scrolling each to center.
- Type a no-hit query (`zzz`) → counter `0 / 0`, chevrons disabled, no wash.
- Clear/close search (magnifier again) → highlights and wash gone, normal read mode.
- Start playback, open search → auto-follow does not scroll while the bar is up; close search →
  follow resumes.
- Select button while searching → search closes, clip flow works.

- [ ] **Step 3: Clean up and commit any verification fixes**

```sh
xcrun simctl shutdown "$UDID" && xcrun simctl delete "$UDID"
git status --short   # commit any fixes made during verification
```

Expected: clean tree (or a final fix commit), feature verified end-to-end.
