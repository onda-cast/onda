//  PrivateFeedTokenMigrationTests.swift
import XCTest
import SwiftData
@testable import Onda

private struct InMemoryTokenStoreError: Error {}

private final class InMemoryTokenStore: PrivateFeedTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: URL] = [:]
    // Failure-injection hook for testing the migration's fail-safe path — hashes in this set
    // fail `store(realURL:hash:)` as if the Keychain write failed. Doesn't affect the three
    // pre-existing tests, which never populate it.
    var failingHashes: Set<String> = []

    func store(realURL: URL, hash: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failingHashes.contains(hash) { throw InMemoryTokenStoreError() }
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

    func test_run_mixedBatch_oneFailsOneSucceeds_savesTheSuccessfulOne() throws {
        let ctx = try context()
        let okURL = URL(string: "https://feeds.example.com/ok.xml?token=good")!
        let failURL = URL(string: "https://feeds.example.com/fail.xml?token=bad")!
        let okHash = PrivateFeedIdentity.hash(for: okURL)
        let failHash = PrivateFeedIdentity.hash(for: failURL)

        let okPod = Podcast(feedURL: okURL, title: "OK Show", author: "A", artworkURL: nil,
                            category: "Tech", itunesId: nil, isSubscribed: true, isPrivateFeed: true)
        let failPod = Podcast(feedURL: failURL, title: "Fail Show", author: "A", artworkURL: nil,
                              category: "Tech", itunesId: nil, isSubscribed: true, isPrivateFeed: true)
        ctx.insert(okPod)
        ctx.insert(failPod)
        try ctx.save()

        let tokenStore = InMemoryTokenStore()
        tokenStore.failingHashes = [failHash]
        PrivateFeedTokenMigration.run(context: ctx, tokenStore: tokenStore)

        XCTAssertTrue(PrivateFeedIdentity.isPlaceholder(okPod.feedURL),
                      "the podcast whose Keychain store succeeded is rewritten to a placeholder")
        XCTAssertEqual(try tokenStore.realURL(forHash: okHash), okURL,
                      "the successfully-migrated podcast's real URL is retrievable from the token store")

        XCTAssertEqual(failPod.feedURL, failURL,
                       "the podcast whose Keychain store failed keeps its real feedURL untouched")
        XCTAssertNil(try tokenStore.realURL(forHash: failHash), "no token stored for the failed podcast")

        // The save must have actually persisted — refetch from the context rather than trusting
        // the in-memory reference, to catch a regression where context.save() was skipped.
        let refetched = try ctx.fetch(FetchDescriptor<Podcast>())
        let refetchedOK = refetched.first { $0.title == "OK Show" }
        XCTAssertNotNil(refetchedOK)
        XCTAssertTrue(PrivateFeedIdentity.isPlaceholder(refetchedOK?.feedURL ?? okURL),
                      "context.save() persisted the successful migration even though the other podcast failed")
    }
}
