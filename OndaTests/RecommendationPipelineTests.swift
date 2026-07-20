//  RecommendationPipelineTests.swift
import XCTest
import SwiftData
@testable import Onda

private struct StubSearch: Searching {
    var byTerm: [String: [PodcastDTO]] = [:]
    var chartIds: [Int] = []
    var chartLookup: [PodcastDTO] = []
    func search(term: String) async throws -> [PodcastDTO] { byTerm[term] ?? [] }
    func lookup(ids: [Int]) async throws -> [PodcastDTO] { chartLookup }
    func topChartIds(limit: Int) async throws -> [Int] { chartIds }
}

private struct StubFeeds: FeedFetching {
    var byURL: [URL: ParsedFeed] = [:]
    func fetchFeed(_ url: URL) async throws -> ParsedFeed {
        guard let f = byURL[url] else { throw NSError(domain: "test", code: 1) }
        return f
    }
}

private func dto(_ name: String, feed: String, genre: String? = nil, artist: String = "Artist") -> PodcastDTO {
    PodcastDTO(collectionId: abs(name.hashValue % 100000), collectionName: name, artistName: artist,
               feedUrl: URL(string: feed), artworkUrl600: nil, primaryGenreName: genre)
}

private func feed(_ title: String, episodes: [(String, String)]) -> ParsedFeed {
    ParsedFeed(title: title, author: "A", artworkURL: nil, category: "Tech",
               episodes: episodes.map {
                   ParsedEpisode(guid: $0.0, title: $0.0, publishDate: .now, duration: 100,
                                 audioURL: URL(string: "https://ex.com/a.mp3")!, notes: $0.1,
                                 chaptersURL: nil, transcriptURL: nil, transcriptType: nil)
               })
}

@MainActor
final class RecommendationPipelineTests: XCTestCase {
    // MARK: TasteProfileBuilder

    private func ctx() throws -> ModelContext {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    func test_profile_clipTextOutweighsGenreTally() throws {
        let ctx = try ctx()
        let pod = Podcast(feedURL: URL(string: "https://a.com/f.xml")!, title: "Java Diaries",
                          author: "Dev", artworkURL: nil, category: "Technology", itunesId: 1)
        ctx.insert(pod)
        let ep = Episode(guid: "e", title: "E", publishDate: .now, duration: 10,
                         audioURL: URL(string: "https://a.com/e.mp3")!, notes: "")
        ep.podcast = pod; pod.episodes.append(ep); ctx.insert(ep)
        let clip = Clip(startTime: 0, endTime: 5, text: "espresso espresso espresso portafilter",
                        note: nil, createdAt: .now, needsReview: false)
        clip.episode = ep; ctx.insert(clip)

        let profile = TasteProfileBuilder.build(subscriptions: [pod], clips: [clip], searchTerms: [])
        XCTAssertEqual(profile.categories["Technology"], TasteProfileBuilder.Weight.tally)
        // Clip term should dominate the vector's top terms.
        XCTAssertEqual(profile.terms.topTerms(1), ["espresso"])
        XCTAssertGreaterThan(profile.terms.overlap(with: TermVector(text: "espresso"), limit: 1).count, 0)
    }

    func test_profile_excludesPrivateFeeds() throws {
        let ctx = try ctx()
        let priv = Podcast(feedURL: URL(string: "https://ex.com/p.xml?token=s3cret")!,
                           title: "Secret Members Show", author: "Patron Person",
                           artworkURL: nil, category: "TrueCrime", itunesId: nil,
                           isPrivateFeed: true)
        ctx.insert(priv)
        let ep = Episode(guid: "e", title: "Members Only Episode", publishDate: .now, duration: 10,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "")
        ep.played = true
        ep.podcast = priv; priv.episodes.append(ep); ctx.insert(ep)

        let profile = TasteProfileBuilder.build(subscriptions: [priv], clips: [], searchTerms: [])
        XCTAssertTrue(profile.isEmpty,
                      "private shows must contribute nothing — their terms feed iTunes search queries")
    }

    func test_profile_emptyWhenNoSignals() throws {
        let profile = TasteProfileBuilder.build(subscriptions: [], clips: [], searchTerms: [])
        XCTAssertTrue(profile.isEmpty)
    }

    func test_profile_displayVocabulary_excludesTranscriptAndClipTokens() throws {
        let ctx = try ctx()
        let pod = Podcast(feedURL: URL(string: "https://a.com/f.xml")!, title: "Show",
                          author: "Dev", artworkURL: nil, category: "Technology", itunesId: 1)
        ctx.insert(pod)
        let ep = Episode(guid: "e", title: "E", publishDate: .now, duration: 10,
                         audioURL: URL(string: "https://a.com/e.mp3")!, notes: "")
        ep.podcast = pod; pod.episodes.append(ep); ctx.insert(ep)
        let tr = Transcript(source: "published", language: "en"); tr.episode = ep; ep.transcript = tr
        let cue = TranscriptCue(startTime: 0, endTime: 5, text: "a shocking murder", speaker: nil)
        cue.transcript = tr; tr.cues = [cue]; ctx.insert(tr); ctx.insert(cue)
        let clip = Clip(startTime: 0, endTime: 5, text: "espresso portafilter", note: nil,
                        createdAt: .now, needsReview: false)
        clip.episode = ep; ctx.insert(clip)

        let profile = TasteProfileBuilder.build(subscriptions: [pod], clips: [clip],
                                                searchTerms: ["swift concurrency"])
        XCTAssertTrue(profile.displayVocabulary.contains("technology"), "category is showable")
        XCTAssertTrue(profile.displayVocabulary.contains("swift"), "search term is showable")
        XCTAssertTrue(profile.displayVocabulary.contains("dev"), "author is showable")
        XCTAssertFalse(profile.displayVocabulary.contains("murder"), "transcript token not shown")
        XCTAssertFalse(profile.displayVocabulary.contains("espresso"), "clip token not shown")
        // …but transcript/clip tokens still drive scoring.
        XCTAssertTrue(profile.terms.terms.contains("murder"))
        XCTAssertTrue(profile.terms.terms.contains("espresso"))
    }

    // MARK: Retriever query construction + exclusions

    func test_retriever_coldStartUsesFollowedCategories() {
        let q = CandidateRetriever.queries(profile: TasteProfile(), followedCategories: ["News", "Comedy", "Tech", "Extra"])
        XCTAssertEqual(q, ["News", "Comedy", "Tech"], "cold start = first 3 followed categories")
    }

    func test_retriever_usesProfileTermsCategoriesAuthors() {
        var profile = TasteProfile()
        profile.terms.add(text: "espresso espresso coffee", weight: 1)
        profile.categories["Food"] = 5
        profile.authors["James Hoffmann"] = 5
        let q = CandidateRetriever.queries(profile: profile, followedCategories: [])
        XCTAssertTrue(q.contains("espresso"))
        XCTAssertTrue(q.contains("Food"))
        XCTAssertTrue(q.contains("James Hoffmann"))
    }

    func test_retriever_dropsSubscribedAndDismissed() async {
        let subscribed = dto("Sub", feed: "https://sub.com/f.xml")
        let dismissed = dto("Bad", feed: "https://bad.com/f.xml")
        let good = dto("Good", feed: "https://good.com/f.xml")
        let client = StubSearch(byTerm: ["coffee": [subscribed, dismissed, good]])
        var profile = TasteProfile(); profile.terms.add(text: "coffee", weight: 1)
        let retriever = CandidateRetriever(client: client)
        let pool = await retriever.retrieve(
            profile: profile, followedCategories: [],
            subscribedFeeds: [URL(string: "https://sub.com/f.xml")!],
            isDismissed: { $0.feedUrl?.absoluteString == "https://bad.com/f.xml" })
        XCTAssertEqual(pool.map(\.collectionName), ["Good"])
    }

    func test_retriever_dropsHiddenCategoryShows() async {
        let hidden = dto("Crime Show", feed: "https://crime.com/f.xml", genre: "True Crime")
        let good = dto("Good Show", feed: "https://good.com/f.xml", genre: "Technology")
        let client = StubSearch(byTerm: ["coffee": [hidden, good]])
        var profile = TasteProfile(); profile.terms.add(text: "coffee", weight: 1)
        let retriever = CandidateRetriever(client: client)
        let pool = await retriever.retrieve(
            profile: profile, followedCategories: [], subscribedFeeds: [],
            isDismissed: { _ in false },
            isCategoryHidden: { $0.primaryGenreName == "True Crime" })
        XCTAssertEqual(pool.map(\.collectionName), ["Good Show"])
    }

    // MARK: Reranker with a fake feed fetcher

    func test_reranker_ranksContentMatchAboveNoise() async {
        var profile = TasteProfile()
        profile.terms.add(text: "espresso coffee grinder beans", weight: 1)
        let match = dto("Coffee Hour", feed: "https://match.com/f.xml", genre: "Food")
        let noise = dto("Sports Desk", feed: "https://noise.com/f.xml", genre: "Sports")
        let feeds = StubFeeds(byURL: [
            URL(string: "https://match.com/f.xml")!:
                feed("Coffee Hour", episodes: [("Espresso basics", "all about coffee beans and grinder technique")]),
            URL(string: "https://noise.com/f.xml")!:
                feed("Sports Desk", episodes: [("Playoff recap", "touchdowns and trades")])
        ])
        let reranker = CandidateReranker(feeds: feeds, embedding: nil)
        let ranked = await reranker.rank(profile: profile, candidates: [noise, match], limit: 15)
        XCTAssertEqual(ranked.first?.dto.collectionName, "Coffee Hour")
        XCTAssertNotNil(ranked.first?.reasonLine)
    }

    // MARK: Service cold-start + dismiss + TTL

    func test_service_coldStart_fallsBackToCharts() async throws {
        let ctx = try ctx()
        let chart = dto("Top Show", feed: "https://top.com/f.xml", genre: "News")
        let client = StubSearch(chartIds: [42], chartLookup: [chart])
        let feeds = StubFeeds(byURL: [URL(string: "https://top.com/f.xml")!:
                                        feed("Top Show", episodes: [("Ep", "news of the day")])])
        let svc = RecommendationService(modelContext: ctx, client: client, feeds: feeds,
                                        embedding: nil, searchLog: SearchTermLog(defaults: freshDefaults()),
                                        dismissed: DismissedShows(defaults: freshDefaults()))
        await svc.refresh(followedCategories: [])
        XCTAssertEqual(svc.recommendations.map(\.dto.collectionName), ["Top Show"])
        XCTAssertFalse(svc.isStale, "cache fresh after refresh")
        XCTAssertFalse(svc.isPersonalized, "no profile signal → charts, not personalized")
    }

    func test_service_coldStart_excludesHiddenCategoryFromCharts() async throws {
        let ctx = try ctx()
        let hiddenShow = dto("Crime Show", feed: "https://crime.com/f.xml", genre: "True Crime")
        let goodShow = dto("Top Show", feed: "https://top.com/f.xml", genre: "News")
        let client = StubSearch(chartIds: [1, 2], chartLookup: [hiddenShow, goodShow])
        let feeds = StubFeeds(byURL: [
            URL(string: "https://crime.com/f.xml")!: feed("Crime Show", episodes: [("Ep", "murder")]),
            URL(string: "https://top.com/f.xml")!: feed("Top Show", episodes: [("Ep", "news of the day")])
        ])
        let hiddenCategories = HiddenCategories(defaults: freshDefaults())
        hiddenCategories.toggle("True Crime")
        let svc = RecommendationService(modelContext: ctx, client: client, feeds: feeds,
                                        embedding: nil, searchLog: SearchTermLog(defaults: freshDefaults()),
                                        dismissed: DismissedShows(defaults: freshDefaults()),
                                        hiddenCategories: hiddenCategories)
        await svc.refresh(followedCategories: [])
        XCTAssertEqual(svc.recommendations.map(\.dto.collectionName), ["Top Show"])
    }

    func test_service_dismiss_removesAndPersists() async throws {
        let ctx = try ctx()
        let defaults = freshDefaults()
        let chart = dto("Top Show", feed: "https://top.com/f.xml")
        let client = StubSearch(chartIds: [1], chartLookup: [chart])
        let feeds = StubFeeds(byURL: [URL(string: "https://top.com/f.xml")!:
                                        feed("Top Show", episodes: [("Ep", "hi")])])
        let svc = RecommendationService(modelContext: ctx, client: client, feeds: feeds, embedding: nil,
                                        searchLog: SearchTermLog(defaults: defaults),
                                        dismissed: DismissedShows(defaults: defaults))
        await svc.refresh(followedCategories: [])
        XCTAssertEqual(svc.recommendations.count, 1)
        svc.dismiss(svc.recommendations[0])
        XCTAssertTrue(svc.recommendations.isEmpty)
        XCTAssertTrue(DismissedShows(defaults: defaults).contains(chart), "dismissal persisted")
    }

    func test_service_showDifferent_excludesCurrentList() async throws {
        let ctx = try ctx()
        let first = dto("First Show", feed: "https://first.com/f.xml")
        let second = dto("Second Show", feed: "https://second.com/f.xml")
        let client = StubSearch(chartIds: [1, 2], chartLookup: [first, second])
        let feeds = StubFeeds(byURL: [
            URL(string: "https://first.com/f.xml")!: feed("First Show", episodes: [("A", "hi")]),
            URL(string: "https://second.com/f.xml")!: feed("Second Show", episodes: [("B", "hi")])
        ])
        let svc = RecommendationService(modelContext: ctx, client: client, feeds: feeds, embedding: nil,
                                        searchLog: SearchTermLog(defaults: freshDefaults()),
                                        dismissed: DismissedShows(defaults: freshDefaults()))
        await svc.refresh(followedCategories: [])
        XCTAssertEqual(Set(svc.recommendations.map(\.dto.collectionName)), ["First Show", "Second Show"])

        await svc.refreshShowingDifferent(followedCategories: [])
        XCTAssertTrue(svc.recommendations.isEmpty,
                      "both charts shows were on screen, so a 'different' rebuild has nothing left")

        // The exclusion is one-shot, not persisted: a plain refresh brings them back.
        await svc.refresh(followedCategories: [])
        XCTAssertEqual(svc.recommendations.count, 2, "plain refresh is unaffected by prior exclusion")
    }

    func test_dismiss_thenUndo_restoresRecAndUnpersists() async throws {
        let ctx = try ctx()
        let defaults = freshDefaults()
        let chart = dto("Top Show", feed: "https://top.com/f.xml")
        let client = StubSearch(chartIds: [1], chartLookup: [chart])
        let feeds = StubFeeds(byURL: [URL(string: "https://top.com/f.xml")!:
                                        feed("Top Show", episodes: [("Ep", "hi")])])
        let svc = RecommendationService(modelContext: ctx, client: client, feeds: feeds, embedding: nil,
                                        searchLog: SearchTermLog(defaults: defaults),
                                        dismissed: DismissedShows(defaults: defaults))
        await svc.refresh(followedCategories: [])
        XCTAssertEqual(svc.recommendations.count, 1)

        svc.dismiss(svc.recommendations[0])
        XCTAssertTrue(svc.recommendations.isEmpty)
        XCTAssertNotNil(svc.lastDismissed)

        svc.undoDismiss()
        XCTAssertEqual(svc.recommendations.map(\.dto.collectionName), ["Top Show"],
                       "undo restores the recommendation in place")
        XCTAssertFalse(DismissedShows(defaults: defaults).contains(chart),
                       "undo also removes the persisted dismissal")
        XCTAssertNil(svc.lastDismissed)
    }

    private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "rec-\(UUID().uuidString)")! }
}
