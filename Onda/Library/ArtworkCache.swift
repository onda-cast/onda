//  ArtworkCache.swift
//  In-memory artwork cache. AsyncImage restarts from empty every time a tab switch rebuilds
//  the view tree, so every visible card's art flashed its placeholder and re-decoded on each
//  switch — the perceived "small delay" after the main-thread work was fixed. A cache hit
//  renders synchronously on rebuild; only first-ever loads go async.
import SwiftUI

@MainActor
final class ArtworkCache {
    typealias Transport = @Sendable (URL) async throws -> Data

    static let shared = ArtworkCache()

    private let cache = NSCache<NSURL, UIImage>()
    private let transport: Transport

    init(transport: @escaping Transport = { url in
        // URLSession's disk cache still backs first loads across launches.
        try await URLSession.shared.data(from: url).0
    }) {
        self.transport = transport
        cache.totalCostLimit = 64 * 1024 * 1024   // ~64MB of decoded pixels
    }

    /// Synchronous hit — render path. nil means "kick off load(_:)".
    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Fetches, force-decodes off the render pass, and (when `store`) caches. Failures return
    /// nil and are never cached, so a later appearance retries. `store: false` is the Discover
    /// path: covers that just scrolled by shouldn't evict subscribed shows' art.
    func load(_ url: URL, store: Bool = true) async -> UIImage? {
        if let hit = image(for: url) { return hit }
        guard let data = try? await transport(url), let raw = UIImage(data: data) else { return nil }
        // byPreparingForDisplay decodes the bitmap now, off-main — otherwise the first draw
        // of each image pays JPEG decode during scrolling.
        let decoded = await raw.byPreparingForDisplay() ?? raw
        if store {
            let cost = Int(decoded.size.width * decoded.size.height * decoded.scale * decoded.scale * 4)
            cache.setObject(decoded, forKey: url as NSURL, cost: cost)
        }
        return decoded
    }
}
