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
