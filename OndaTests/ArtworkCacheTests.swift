//  ArtworkCacheTests.swift
import XCTest
@testable import Onda

@MainActor
final class ArtworkCacheTests: XCTestCase {
    private var pngData: Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        return renderer.pngData { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    func test_missThenHit_afterLoad() async {
        let cache = ArtworkCache(transport: { [data = pngData] _ in data })
        let url = URL(string: "https://ex.com/art.png")!
        XCTAssertNil(cache.image(for: url), "cold cache misses")

        let loaded = await cache.load(url)
        XCTAssertNotNil(loaded, "fetch + decode succeeds")
        XCTAssertNotNil(cache.image(for: url), "synchronous hit after load")
    }

    func test_loadWithoutStore_decodesButDoesNotCache() async {
        // Discover artwork: shown while the row is alive, never kept — only subscribed
        // shows' art earns a cache slot.
        let cache = ArtworkCache(transport: { [data = pngData] _ in data })
        let url = URL(string: "https://ex.com/discover.png")!
        let loaded = await cache.load(url, store: false)
        XCTAssertNotNil(loaded, "image still decodes for display")
        XCTAssertNil(cache.image(for: url), "but is not retained in the cache")
    }

    func test_failedFetch_staysEmpty_noCrash() async {
        let cache = ArtworkCache(transport: { _ in throw URLError(.notConnectedToInternet) })
        let url = URL(string: "https://ex.com/art.png")!
        let loaded = await cache.load(url)
        XCTAssertNil(loaded)
        XCTAssertNil(cache.image(for: url))
    }

    func test_undecodableData_notCached() async {
        let cache = ArtworkCache(transport: { _ in Data("not an image".utf8) })
        let url = URL(string: "https://ex.com/art.png")!
        let loaded = await cache.load(url)
        XCTAssertNil(loaded)
        XCTAssertNil(cache.image(for: url))
    }
}
