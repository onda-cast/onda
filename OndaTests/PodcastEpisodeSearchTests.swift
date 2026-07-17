//  PodcastEpisodeSearchTests.swift
import XCTest
import SwiftData
@testable import Onda

@MainActor
final class PodcastEpisodeSearchTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: Schema(ondaSchema),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func makePodcast(_ ctx: ModelContext) -> Podcast {
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "World Brief",
                          author: "A", artworkURL: nil, category: "News", itunesId: 1, isSubscribed: true)
        ctx.insert(pod)
        return pod
    }

    @discardableResult
    private func addEpisode(_ ctx: ModelContext, to pod: Podcast, guid: String, title: String,
                            notes: String = "", publishDate: Date = .now,
                            archived: Bool = false) -> Episode {
        let ep = Episode(guid: guid, title: title, publishDate: publishDate, duration: 100,
                         audioURL: URL(string: "https://ex.com/\(guid).mp3")!, notes: notes)
        ep.isArchived = archived
        ep.podcast = pod
        ctx.insert(ep)
        return ep
    }

    func test_titleMatch_returnsEpisode_withoutSnippet() throws {
        let ctx = try makeContext()
        let pod = makePodcast(ctx)
        addEpisode(ctx, to: pod, guid: "a", title: "Germany votes on the budget")
        addEpisode(ctx, to: pod, guid: "b", title: "France and the euro")
        try ctx.save()

        let results = PodcastEpisodeSearch(index: nil).search("germany", in: pod)
        XCTAssertEqual(results.map(\.episode.guid), ["a"])
        XCTAssertNil(results.first?.snippet)
    }

    func test_notesMatch_returnsEpisode() throws {
        let ctx = try makeContext()
        let pod = makePodcast(ctx)
        addEpisode(ctx, to: pod, guid: "a", title: "Weekly roundup",
                   notes: "We discuss the situation in Germany at length.")
        try ctx.save()

        let results = PodcastEpisodeSearch(index: nil).search("germany", in: pod)
        XCTAssertEqual(results.map(\.episode.guid), ["a"])
    }

    func test_transcriptMatch_returnsEpisode_withSnippetAndStartTime() throws {
        let ctx = try makeContext()
        let index = try SearchIndex(path: ":memory:")
        let pod = makePodcast(ctx)
        addEpisode(ctx, to: pod, guid: "a", title: "Weekly roundup", notes: "nothing relevant here")
        try ctx.save()
        try index.upsert(SearchDoc(kind: "cue", episodeGuid: "a", startTime: 42,
                                   body: "the economy of Germany is slowing"))

        let results = PodcastEpisodeSearch(index: index).search("germany", in: pod)
        XCTAssertEqual(results.map(\.episode.guid), ["a"])
        XCTAssertNotNil(results.first?.snippet)
        XCTAssertEqual(results.first?.snippetStartTime, 42)
    }

    func test_transcriptHit_inOtherPodcast_isNotReturned() throws {
        let ctx = try makeContext()
        let index = try SearchIndex(path: ":memory:")
        let pod = makePodcast(ctx)
        addEpisode(ctx, to: pod, guid: "a", title: "Roundup", notes: "")
        try ctx.save()
        // A transcript hit for an episode that is NOT in `pod`.
        try index.upsert(SearchDoc(kind: "cue", episodeGuid: "other", startTime: 5,
                                   body: "Germany news"))

        XCTAssertTrue(PodcastEpisodeSearch(index: index).search("germany", in: pod).isEmpty)
    }

    func test_multiTerm_requiresAllTerms() throws {
        let ctx = try makeContext()
        let pod = makePodcast(ctx)
        addEpisode(ctx, to: pod, guid: "a", title: "Germany and the economy")
        addEpisode(ctx, to: pod, guid: "b", title: "Germany and sports")
        try ctx.save()

        let results = PodcastEpisodeSearch(index: nil).search("germany economy", in: pod)
        XCTAssertEqual(results.map(\.episode.guid), ["a"])
    }

    func test_noMatch_returnsEmpty() throws {
        let ctx = try makeContext()
        let pod = makePodcast(ctx)
        addEpisode(ctx, to: pod, guid: "a", title: "France news")
        try ctx.save()

        XCTAssertTrue(PodcastEpisodeSearch(index: nil).search("germany", in: pod).isEmpty)
    }

    func test_archivedEpisode_isExcluded() throws {
        let ctx = try makeContext()
        let pod = makePodcast(ctx)
        addEpisode(ctx, to: pod, guid: "a", title: "Germany news", archived: true)
        try ctx.save()

        XCTAssertTrue(PodcastEpisodeSearch(index: nil).search("germany", in: pod).isEmpty)
    }

    func test_emptyQuery_returnsEmpty() throws {
        let ctx = try makeContext()
        let pod = makePodcast(ctx)
        addEpisode(ctx, to: pod, guid: "a", title: "Germany news")
        try ctx.save()

        XCTAssertTrue(PodcastEpisodeSearch(index: nil).search("   ", in: pod).isEmpty)
    }

    func test_metadataAndTranscript_dedupeToSingleResult() throws {
        let ctx = try makeContext()
        let index = try SearchIndex(path: ":memory:")
        let pod = makePodcast(ctx)
        // Matches both in the title AND in a transcript cue — must appear once.
        addEpisode(ctx, to: pod, guid: "a", title: "Germany today", notes: "")
        try ctx.save()
        try index.upsert(SearchDoc(kind: "cue", episodeGuid: "a", startTime: 8, body: "Germany again"))

        let results = PodcastEpisodeSearch(index: index).search("germany", in: pod)
        XCTAssertEqual(results.count, 1)
        // Snippet still populated from the transcript hit.
        XCTAssertNotNil(results.first?.snippet)
    }

    func test_results_sortedByPublishDateDescending() throws {
        let ctx = try makeContext()
        let pod = makePodcast(ctx)
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        addEpisode(ctx, to: pod, guid: "old", title: "Germany then", publishDate: old)
        addEpisode(ctx, to: pod, guid: "new", title: "Germany now", publishDate: new)
        try ctx.save()

        let results = PodcastEpisodeSearch(index: nil).search("germany", in: pod)
        XCTAssertEqual(results.map(\.episode.guid), ["new", "old"])
    }
}
