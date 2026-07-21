//  BookMentionServiceTests.swift
import XCTest
import SwiftData
@testable import Onda

private struct StubLLM: BookExtracting {
    var result: [LLMBookCandidate] = []
    func bookCandidates(transcriptChunks _: [String]) async throws -> [LLMBookCandidate] {
        result
    }
}

@MainActor
final class BookMentionServiceTests: XCTestCase {
    private func ctx() throws -> ModelContext {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    private func makeEpisode(_ ctx: ModelContext, isPrivate: Bool = false,
                             noteLinks: [URL] = [], cues: [(String, Double)] = []) -> Episode {
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "S", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1,
                          isPrivateFeed: isPrivate)
        let ep = Episode(guid: "g", title: "E", publishDate: .now, duration: 1000,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "",
                         noteLinks: noteLinks)
        ep.podcast = pod; pod.episodes.append(ep)
        ctx.insert(pod); ctx.insert(ep)
        if !cues.isEmpty {
            let tr = Transcript(source: "ondevice", language: "en"); tr.episode = ep; ep.transcript = tr
            ctx.insert(tr)
            for (text, start) in cues {
                let cue = TranscriptCue(startTime: start, endTime: start + 5, text: text, speaker: nil)
                cue.transcript = tr; tr.cues.append(cue); ctx.insert(cue)
            }
        }
        return ep
    }

    private func verifierReturning(_ book: VerifiedBook?) -> BookVerifier {
        BookVerifier(transport: { _ in
            guard let book else { throw URLError(.notConnectedToInternet) }
            let doc: [String: Any] = ["key": book.workKey, "title": book.title,
                                      "author_name": book.author.map { [$0] } ?? []]
            return try JSONSerialization.data(withJSONObject: ["docs": [doc]])
        })
    }

    func test_linkCandidate_verifies_andPersists() async throws {
        let ctx = try ctx()
        let ep = try makeEpisode(ctx, noteLinks: [XCTUnwrap(URL(string: "https://amazon.com/dp/0735211299"))])
        let svc = BookMentionService(
            modelContext: ctx,
            verifier: verifierReturning(VerifiedBook(workKey: "/works/OL1W", title: "Atomic Habits",
                                                     author: "James Clear", coverURL: nil)),
            llm: nil, isPersonName: { _ in false }
        )
        await svc.findBooks(for: ep)
        XCTAssertEqual(ep.bookMentions.count, 1)
        XCTAssertEqual(ep.bookMentions.first?.title, "Atomic Habits")
        XCTAssertEqual(ep.bookMentions.first?.sourceTier, "link")
    }

    func test_llmCandidate_recoversTimestampFromQuote() async throws {
        let ctx = try ctx()
        let ep = makeEpisode(ctx, cues: [("we talked about tiny changes remarkable results", 640)])
        let svc = BookMentionService(
            modelContext: ctx,
            verifier: verifierReturning(VerifiedBook(workKey: "/works/OL1W", title: "Atomic Habits",
                                                     author: nil, coverURL: nil)),
            llm: StubLLM(result: [LLMBookCandidate(title: "Atomic Habits", author: nil,
                                                   nearbyQuote: "tiny changes remarkable results")]),
            isPersonName: { _ in false }
        )
        await svc.findBooks(for: ep)
        XCTAssertEqual(ep.bookMentions.first?.timestamp, 640)
        XCTAssertEqual(ep.bookMentions.first?.sourceTier, "transcript")
    }

    func test_privateFeed_isExcludedEntirely() async throws {
        let ctx = try ctx()
        let ep = try makeEpisode(ctx, isPrivate: true,
                                 noteLinks: [XCTUnwrap(URL(string: "https://amazon.com/dp/0735211299"))])
        let svc = BookMentionService(
            modelContext: ctx,
            verifier: verifierReturning(VerifiedBook(workKey: "/works/OL1W", title: "X",
                                                     author: nil, coverURL: nil)),
            llm: nil, isPersonName: { _ in false }
        )
        await svc.findBooks(for: ep)
        XCTAssertTrue(ep.bookMentions.isEmpty, "private feeds never reach the network")
        XCTAssertNotNil(svc.lastFailure)
    }

    func test_unverifiedCandidates_neverPersist_andRerunReplaces() async throws {
        let ctx = try ctx()
        let ep = try makeEpisode(ctx, noteLinks: [XCTUnwrap(URL(string: "https://amazon.com/dp/0735211299"))])
        let failing = BookMentionService(modelContext: ctx, verifier: verifierReturning(nil),
                                         llm: nil, isPersonName: { _ in false })
        await failing.findBooks(for: ep)
        XCTAssertTrue(ep.bookMentions.isEmpty, "verification failure -> nothing persisted")

        let working = BookMentionService(
            modelContext: ctx,
            verifier: verifierReturning(VerifiedBook(workKey: "/works/OL1W", title: "Atomic Habits",
                                                     author: nil, coverURL: nil)),
            llm: nil, isPersonName: { _ in false }
        )
        await working.findBooks(for: ep)
        await working.findBooks(for: ep)
        XCTAssertEqual(ep.bookMentions.count, 1, "re-run replaces, never accumulates duplicates")
    }

    /// Regression: `findBooks` used to iterate `episode.bookMentions` while deleting its
    /// members inside that same loop (a live SwiftData relationship array), which can skip
    /// elements or crash. Multiple distinct mentions replaced by another full set on rerun is
    /// the scenario that would expose it.
    func test_multipleMentions_rerunReplacesAllWithoutSkippingOrCrashing() async throws {
        let ctx = try ctx()
        let asins = ["AAAAAAAAAA", "BBBBBBBBBB", "CCCCCCCCCC"]
        let ep = makeEpisode(ctx, noteLinks: asins.map { URL(string: "https://amazon.com/dp/\($0)")! })
        // Verify concurrently, and distinctly per candidate, by echoing the requested isbn back.
        let verifier = BookVerifier(transport: { url in
            let isbn = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "isbn" }?.value ?? "?"
            let doc: [String: Any] = ["key": "/works/\(isbn)", "title": "Book \(isbn)", "author_name": []]
            return try JSONSerialization.data(withJSONObject: ["docs": [doc]])
        })
        let svc = BookMentionService(modelContext: ctx, verifier: verifier, llm: nil,
                                     isPersonName: { _ in false })

        await svc.findBooks(for: ep)
        XCTAssertEqual(Set(ep.bookMentions.map(\.workKey)), Set(asins.map { "/works/\($0)" }),
                       "all three concurrently-verified candidates persist")

        await svc.findBooks(for: ep)
        XCTAssertEqual(ep.bookMentions.count, 3, "rerun replaces every old mention, none skipped")
        XCTAssertEqual(Set(ep.bookMentions.map(\.workKey)), Set(asins.map { "/works/\($0)" }))
    }
}
