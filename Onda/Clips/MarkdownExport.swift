//  MarkdownExport.swift
import Foundation

@MainActor
enum MarkdownExport {
    static func timeStr(_ s: TimeInterval) -> String {
        let t = Int(max(0, s)); return String(format: "%d:%02d", t / 60, t % 60)
    }

    /// One clip as Markdown. Unlike audio sharing, this is a personal export: notes included.
    static func clipMarkdown(_ clip: Clip) -> String {
        let episode = clip.episode?.title ?? "Unknown episode"
        let show = clip.episode?.podcast?.title ?? "Unknown show"
        var lines: [String] = []
        if !clip.text.isEmpty { lines.append("> \(clip.text)") ; lines.append("") }
        lines.append("\u{2014} \(episode), \(show) @ \(timeStr(clip.startTime))\u{2013}\(timeStr(clip.endTime))")
        if let note = clip.note, !note.isEmpty { lines.append("**Note:** \(note)") }
        return lines.joined(separator: "\n")
    }

    /// All clips as one document, grouped by show → episode, clips ordered by start time.
    static func document(clips: [Clip]) -> String {
        var out = ["# Onda Clips", ""]
        let byShow = Dictionary(grouping: clips) { $0.episode?.podcast?.title ?? "Unknown show" }
        for show in byShow.keys.sorted() {
            out.append("## \(show)"); out.append("")
            let byEpisode = Dictionary(grouping: byShow[show] ?? []) {
                $0.episode?.title ?? "Unknown episode"
            }
            for episode in byEpisode.keys.sorted() {
                out.append("### \(episode)"); out.append("")
                for clip in (byEpisode[episode] ?? []).sorted(by: { $0.startTime < $1.startTime }) {
                    out.append(clipMarkdown(clip)); out.append("")
                }
            }
        }
        return out.joined(separator: "\n")
    }

    /// Writes the document to a temporary .md file for the share sheet.
    static func writeDocument(clips: [Clip]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OndaClips")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Date.now.formatted(.iso8601.year().month().day())
        let url = dir.appendingPathComponent("onda-clips-\(stamp).md")
        try MarkdownExport.document(clips: clips).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
