//  PrivateFeedTokenMigrationTests.swift
import XCTest
import SwiftData
@testable import Onda

private final class InMemoryTokenStore: PrivateFeedTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: URL] = [:]

    func store(realURL: URL, hash: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[hash] = realURL
    }

    func realURL(forHash hash: String) throws -> URL? {
        lock.lock(); defer { lock.unlock() }
        return storage[hash]
    }

    func delete(hash: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: hash)
    }
}

final class PrivateFeedTokenMigrationTests: XCTestCase {
    private func context() throws -> ModelContext {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    func test_run_migratesPrivatePodcastWithRealFeedURL() throws {
        let ctx = try context()
        let realURL = URL(string: "https://feeds.example.com/private.xml?token=s3cret")!
        let pod = Podcast(feedURL: realURL, title: "T", author: "A", artworkURL: nil,
                          category: "Tech", itunesId: nil, isSubscribed: true, isPrivateFeed: true)
        ctx.insert(pod)
        try ctx.save()

        let tokenStore = InMemoryTokenStore()
        PrivateFeedTokenMigration.run(context: ctx, tokenStore: tokenStore)

        XCTAssertTrue(PrivateFeedIdentity.isPlaceholder(pod.feedURL), "feedURL rewritten to placeholder")
        let hash = pod.feedURL.host!
        XCTAssertEqual(try tokenStore.realURL(forHash: hash), realURL, "real URL stored in token store")
    }

    func test_run_skipsAlreadyMigratedPodcast() throws {
        let ctx = try context()
        let hash = PrivateFeedIdentity.hash(for: URL(string: "https://feeds.example.com/x.xml?t=1")!)
        let placeholder = PrivateFeedIdentity.placeholderURL(forHash: hash)
        let pod = Podcast(feedURL: placeholder, title: "T", author: "A", artworkURL: nil,
                          category: "Tech", itunesId: nil, isSubscribed: true, isPrivateFeed: true)
        ctx.insert(pod)
        try ctx.save()

        let tokenStore = InMemoryTokenStore()
        PrivateFeedTokenMigration.run(context: ctx, tokenStore: tokenStore)

        XCTAssertEqual(pod.feedURL, placeholder, "already-placeholder feedURL left untouched")
        XCTAssertNil(try tokenStore.realURL(forHash: hash), "no token written for an already-migrated podcast")
    }

    func test_run_leavesPublicPodcastsUntouched() throws {
        let ctx = try context()
        let realURL = URL(string: "https://ex.com/public.xml")!
        let pod = Podcast(feedURL: realURL, title: "T", author: "A", artworkURL: nil,
                          category: "Tech", itunesId: 1, isSubscribed: true, isPrivateFeed: false)
        ctx.insert(pod)
        try ctx.save()

        PrivateFeedTokenMigration.run(context: ctx, tokenStore: InMemoryTokenStore())

        XCTAssertEqual(pod.feedURL, realURL, "public podcasts are never touched by migration")
    }
}
