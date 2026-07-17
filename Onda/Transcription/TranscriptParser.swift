//  TranscriptParser.swift
import Foundation

struct TranscriptParser: Sendable {
    func parse(_ data: Data, type: String) -> [ParsedCue] {
        let hint = type.lowercased()
        let text = String(data: data, encoding: .utf8) ?? ""
        if hint.contains("json") || text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            return parseJSON(data)
        }
        if hint.contains("srt") || hint.contains("subrip") { return parseCueBlocks(text, srt: true) }
        return parseCueBlocks(text, srt: false)   // default: WebVTT
    }

    static func parseTimestamp(_ s: String) -> TimeInterval {
        let cleaned = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":").map { Double($0) ?? 0 }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private func parseJSON(_ data: Data) -> [ParsedCue] {
        guard let doc = try? JSONDecoder().decode(TranscriptDoc.self, from: data) else { return [] }
        return doc.segments.compactMap { seg in
            guard let body = seg.body, !body.isEmpty else { return nil }
            return ParsedCue(startTime: seg.startTime ?? 0, endTime: seg.endTime ?? (seg.startTime ?? 0),
                             text: body, speaker: seg.speaker)
        }
    }

    private func parseCueBlocks(_ text: String, srt: Bool) -> [ParsedCue] {
        var cues: [ParsedCue] = []
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
        for block in blocks {
            var lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard !lines.isEmpty else { continue }
            if lines[0].uppercased().hasPrefix("WEBVTT") { continue }
            if srt, Int(lines[0]) != nil { lines.removeFirst() }        // drop SRT index line
            guard let timing = lines.first(where: { $0.contains("-->") }) else { continue }
            let ends = timing.components(separatedBy: "-->")
            guard ends.count == 2 else { continue }
            let start = Self.parseTimestamp(ends[0])
            let end = Self.parseTimestamp(ends[1].trimmingCharacters(in: .whitespaces)
                .components(separatedBy: " ").first ?? ends[1])
            let bodyLines = lines.drop { $0 != timing }.dropFirst()
            var body = bodyLines.joined(separator: " ")
            var speaker: String?
            if let r = body.range(of: "^<v ([^>]+)>", options: .regularExpression) {
                speaker = String(body[r]).replacingOccurrences(of: "<v ", with: "")
                    .replacingOccurrences(of: ">", with: "")
                body.removeSubrange(r)
            }
            body = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                       .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(ParsedCue(startTime: start, endTime: end, text: body, speaker: speaker))
        }
        return cues
    }
}

// Podcasting 2.0 JSON transcript shape — kept file-private and flat (not nested inside
// parseJSON) to stay within SwiftLint's nesting-depth rule.
private struct TranscriptDoc: Codable { let segments: [TranscriptSegment] }
private struct TranscriptSegment: Codable {
    let startTime: Double?
    let endTime: Double?
    let speaker: String?
    let body: String?
}
