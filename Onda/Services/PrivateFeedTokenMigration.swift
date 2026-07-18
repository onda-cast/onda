//  PrivateFeedTokenMigration.swift
import Foundation
import SwiftData

/// One-time, idempotent, fail-safe migration of existing private-feed podcasts: moves each
/// real tokenized feedURL into Keychain and rewrites the SwiftData row to the non-secret
/// placeholder form. Run at app launch, before any UI is shown. A podcast whose Keychain write
/// fails is left with its real feedURL untouched and is retried on the next launch. See
/// docs/superpowers/specs/2026-07-18-private-feed-token-keychain-design.md.
enum PrivateFeedTokenMigration {
    static func run(context: ModelContext, tokenStore: PrivateFeedTokenStoring) {
        let descriptor = FetchDescriptor<Podcast>(predicate: #Predicate { $0.isPrivateFeed == true })
        guard let podcasts = try? context.fetch(descriptor) else { return }
        var didMigrateAny = false
        for podcast in podcasts where !PrivateFeedIdentity.isPlaceholder(podcast.feedURL) {
            let realURL = podcast.feedURL
            let hash = PrivateFeedIdentity.hash(for: realURL)
            guard (try? tokenStore.store(realURL: realURL, hash: hash)) != nil else { continue }
            podcast.feedURL = PrivateFeedIdentity.placeholderURL(forHash: hash)
            didMigrateAny = true
        }
        if didMigrateAny { try? context.save() }
    }
}
