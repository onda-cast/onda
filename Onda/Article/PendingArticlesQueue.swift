//  PendingArticlesQueue.swift
import Foundation

/// Share-extension → app handoff: the extension appends shared URLs to a JSON file in
/// the App Group container; the app drains it on foreground. This file is the one piece
/// of feature state persisted outside SwiftData — the two processes share no database,
/// and the app may not be running when a share happens.
///
/// NOTE: compiled into BOTH the Onda app target and OndaShareExtension (see project.yml) —
/// keep it dependency-free (Foundation only).
struct PendingArticlesQueue: Sendable {
    static let appGroupID = "group.com.chasegilliam.onda"

    static var standard: PendingArticlesQueue {
        PendingArticlesQueue(containerURL: FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID))
    }

    let containerURL: URL?   // nil when the entitlement is missing (e.g. unit tests)

    private var fileURL: URL? {
        containerURL?.appendingPathComponent("pending-articles.json")
    }

    func append(_ url: URL) {
        guard let fileURL else { return }
        var urls = load()
        guard !urls.contains(url) else { return }
        urls.append(url)
        if let data = try? JSONEncoder().encode(urls) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func drain() -> [URL] {
        guard let fileURL else { return [] }
        let urls = load()
        try? FileManager.default.removeItem(at: fileURL)
        return urls
    }

    private func load() -> [URL] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([URL].self, from: data)) ?? []
    }
}
