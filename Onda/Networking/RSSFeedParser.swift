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
}

struct ParsedFeed {
    let title: String
    let author: String
    let artworkURL: URL?
    let category: String
    let episodes: [ParsedEpisode]
}

protocol FeedFetching {
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
        case "itunes:image": if !inItem, let h = attrs["href"] { channelArtwork = URL(string: h) }
        case "itunes:category": if !inItem, let t = attrs["text"], channelCategory.isEmpty { channelCategory = t }
        case "enclosure": if inItem, let u = attrs["url"] { current?.audioURL = URL(string: u) }
        case "podcast:chapters": if inItem, let u = attrs["url"] { current?.chaptersURL = URL(string: u) }
        default: break
        }
    }

    func parser(_ p: XMLParser, foundCharacters s: String) { text += s }
    func parser(_ p: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { text += s }
    }

    func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName qn: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inItem {
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
        } else {
            switch el {
            case "title": if channelTitle.isEmpty { channelTitle = value }
            case "itunes:author": channelAuthor = value
            default: break
            }
        }
        text = ""
    }

    private func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func buildFeed() -> ParsedFeed {
        let eps: [ParsedEpisode] = items.compactMap { it in
            guard let audio = it.audioURL else { return nil }   // skip items without audio
            let guid = it.guid.isEmpty ? audio.absoluteString : it.guid
            return ParsedEpisode(guid: guid, title: it.title, publishDate: it.pubDate,
                                 duration: it.duration, audioURL: audio, notes: it.notes,
                                 chaptersURL: it.chaptersURL)
        }
        return ParsedFeed(title: channelTitle, author: channelAuthor,
                          artworkURL: channelArtwork, category: channelCategory.isEmpty ? "Podcast" : channelCategory,
                          episodes: eps)
    }
}

struct RSSFeedClient: FeedFetching {
    typealias Transport = (URL) async throws -> Data
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
