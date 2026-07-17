//  RSSFeedParser.swift
import Foundation

struct ParsedEpisode {
    let guid: String
    let title: String
    let publishDate: Date
    let duration: TimeInterval
    let audioURL: URL
    let notes: String
    let chaptersURL: URL?
    var transcriptURL: URL?
    var transcriptType: String?
}

struct ParsedFeed {
    let title: String
    let author: String
    let artworkURL: URL?
    let category: String
    let episodes: [ParsedEpisode]
}

protocol FeedFetching: Sendable {
    func fetchFeed(_ url: URL) async throws -> ParsedFeed
}

struct RSSFeedParser {
    func parse(_ data: Data) -> ParsedFeed? {
        let delegate = FeedDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse(), delegate.sawChannel else { return nil }
        return delegate.buildFeed()
    }

    static func parseDuration(_ raw: String) -> TimeInterval {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if !t.contains(":") { return TimeInterval(t) ?? 0 }
        let parts = t.split(separator: ":").map { Double($0) ?? 0 }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}

private final class FeedDelegate: NSObject, XMLParserDelegate {
    var sawChannel = false
    private var channelTitle = "", channelAuthor = "", channelCategory = ""
    private var channelArtwork: URL?

    private struct Item {
        var guid = "", title = "", notes = ""
        var pubDate: Date = .distantPast
        var duration: TimeInterval = 0
        var audioURL: URL?
        var chaptersURL: URL?
        var transcriptURL: URL?
        var transcriptType: String?
    }
    private var items: [Item] = []
    private var current: Item?
    private var inItem = false
    private var text = ""

    private static let rfc822: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName qn: String?, attributes attrs: [String: String]) {
        text = ""
        switch el {
        case "channel": sawChannel = true
        case "item": inItem = true; current = Item()
        default:
            if inItem { handleItemStartElement(el, attrs: attrs) } else { handleChannelStartElement(el, attrs: attrs) }
        }
    }

    private func handleChannelStartElement(_ el: String, attrs: [String: String]) {
        switch el {
        case "itunes:image": if let h = attrs["href"] { channelArtwork = URL(string: h) }
        case "itunes:category": if let t = attrs["text"], channelCategory.isEmpty { channelCategory = t }
        default: break
        }
    }

    private func handleItemStartElement(_ el: String, attrs: [String: String]) {
        switch el {
        case "enclosure": if let u = attrs["url"] { current?.audioURL = URL(string: u) }
        case "podcast:chapters": if let u = attrs["url"] { current?.chaptersURL = URL(string: u) }
        case "podcast:transcript": handlePodcastTranscript(attrs: attrs)
        default: break
        }
    }

    private func handlePodcastTranscript(attrs: [String: String]) {
        guard let u = attrs["url"] else { return }
        // Prefer JSON over VTT over SRT when a feed offers multiple formats.
        let type = attrs["type"] ?? ""
        if current?.transcriptURL == nil || transcriptRank(type) > transcriptRank(current?.transcriptType ?? "") {
            current?.transcriptURL = URL(string: u)
            current?.transcriptType = type
        }
    }

    private func transcriptRank(_ type: String) -> Int {
        if type.contains("json") { return 3 }
        if type.contains("vtt") { return 2 }
        if type.contains("srt") || type.contains("subrip") { return 1 }
        return 0
    }

    func parser(_ p: XMLParser, foundCharacters s: String) { text += s }
    func parser(_ p: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { text += s }
    }

    func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName qn: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inItem { handleItemEndElement(el, value: value) } else { handleChannelEndElement(el, value: value) }
        text = ""
    }

    private func handleItemEndElement(_ el: String, value: String) {
        switch el {
        case "title": current?.title = value
        case "guid": current?.guid = value
        case "description", "itunes:summary":
            if current?.notes.isEmpty ?? true { current?.notes = stripHTML(value) }
        case "pubDate": current?.pubDate = FeedDelegate.rfc822.date(from: value) ?? .distantPast
        case "itunes:duration": current?.duration = RSSFeedParser.parseDuration(value)
        case "item":
            if let c = current { items.append(c) }
            current = nil; inItem = false
        default: break
        }
    }

    private func handleChannelEndElement(_ el: String, value: String) {
        switch el {
        case "title": if channelTitle.isEmpty { channelTitle = value }
        case "itunes:author": channelAuthor = value
        default: break
        }
    }

    private func stripHTML(_ s: String) -> String {
        decodeEntities(
            s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Feeds commonly double-encode HTML entities; XMLParser only unwraps one layer,
    // leaving literal "&mdash;" etc. in show notes.
    private func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
            "&nbsp;": "\u{00A0}", "&mdash;": "\u{2014}", "&ndash;": "\u{2013}",
            "&hellip;": "\u{2026}", "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}",
            "&rdquo;": "\u{201D}", "&ldquo;": "\u{201C}"
        ]
        for (entity, char) in named { out = out.replacingOccurrences(of: entity, with: char) }
        // Numeric entities: &#8217; and &#x2019;
        while let r = out.range(of: "&#x?[0-9a-fA-F]+;", options: .regularExpression) {
            let body = out[r].dropFirst(2).dropLast()
            let scalar = body.hasPrefix("x") || body.hasPrefix("X")
                ? UInt32(body.dropFirst(), radix: 16)
                : UInt32(body)
            if let scalar, let u = Unicode.Scalar(scalar) {
                out.replaceSubrange(r, with: String(Character(u)))
            } else {
                out.replaceSubrange(r, with: "")
            }
        }
        return out
    }

    func buildFeed() -> ParsedFeed {
        let eps: [ParsedEpisode] = items.compactMap { it in
            guard let audio = it.audioURL else { return nil }   // skip items without audio
            let guid = it.guid.isEmpty ? audio.absoluteString : it.guid
            return ParsedEpisode(guid: guid, title: it.title, publishDate: it.pubDate,
                                 duration: it.duration, audioURL: audio, notes: it.notes,
                                 chaptersURL: it.chaptersURL,
                                 transcriptURL: it.transcriptURL, transcriptType: it.transcriptType)
        }
        return ParsedFeed(title: channelTitle, author: channelAuthor,
                          artworkURL: channelArtwork, category: channelCategory.isEmpty ? "Podcast" : channelCategory,
                          episodes: eps)
    }
}

struct RSSFeedClient: FeedFetching {
    typealias Transport = @Sendable (URL) async throws -> Data
    private let transport: Transport
    private let parser = RSSFeedParser()

    init(transport: @escaping Transport = { try await URLSession.shared.data(from: $0).0 }) {
        self.transport = transport
    }

    func fetchFeed(_ url: URL) async throws -> ParsedFeed {
        let data = try await transport(url)
        guard let feed = parser.parse(data) else {
            throw NSError(domain: "Onda.RSS", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No channel in feed"])
        }
        return feed
    }
}
