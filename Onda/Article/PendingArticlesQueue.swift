//  PendingArticlesQueue.swift
import Foundation

/// Share-extension → app handoff: the extension appends shared URLs to a JSON file in
/// the App Group container; the app reconciles it on foreground (ArticleConversionService.
/// resumePersisted()), removing an entry only on success or explicit dismiss. This file is
/// the one piece of feature state persisted outside SwiftData — the two processes share no
/// database, and the app may not be running when a share happens.
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

    struct Entry: Codable, Equatable, Sendable {
        var url: URL
        var attempts: Int
    }

    private var fileURL: URL? {
        containerURL?.appendingPathComponent("pending-articles.json")
    }

    func append(_ url: URL) {
        guard fileURL != nil else { return }
        var all = loadEntries()
        guard !all.contains(where: { $0.url == url }) else { return }
        all.append(Entry(url: url, attempts: 0))
        save(all)
    }

    func entries() -> [Entry] {
        loadEntries()
    }

    func remove(_ url: URL) {
        guard fileURL != nil else { return }
        save(loadEntries().filter { $0.url != url })
    }

    func recordAttempt(_ url: URL) {
        guard fileURL != nil else { return }
        var all = loadEntries()
        guard let i = all.firstIndex(where: { $0.url == url }) else { return }
        all[i].attempts += 1
        save(all)
    }

    private func loadEntries() -> [Entry] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        if let entries = try? JSONDecoder().decode([Entry].self, from: data) { return entries }
        // Legacy format: a plain [URL] array from the drain-once era.
        if let urls = try? JSONDecoder().decode([URL].self, from: data) {
            return urls.map { Entry(url: $0, attempts: 0) }
        }
        return []
    }

    private func save(_ entries: [Entry]) {
        guard let fileURL else { return }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
