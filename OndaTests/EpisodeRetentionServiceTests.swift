//  EpisodeRetentionServiceTests.swift
import XCTest
import SwiftData
@testable import Onda

@MainActor
final class EpisodeRetentionServiceTests: XCTestCase {
    private var ctx: ModelContext!
    private var settings: AppSettings!
    private var deleted: [String] = []
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        let container = try ModelContainer(for: Schema(ondaSchema),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        ctx = ModelContext(container)
        let defaults = UserDefaults(suiteName: "retention-tests-\(UUID().uuidString)")!
        settings = AppSettings(defaults: defaults)
        deleted = []
    }

    private func makeService() -> EpisodeRetentionService {
        EpisodeRetentionService(modelContext: ctx, appSettings: settings,
                                deleteDownload: { [self] ep in
                                    deleted.append(ep.guid)
                                    ep.downloadedFile = nil
                                },
                                now: { [clock] in clock })
    }

    private func makePodcast() -> Podcast {
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "S", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1)
        let s = ShowSettings.makeDefault(); s.podcast = pod; pod.settings = s
        ctx.insert(pod); ctx.insert(s)
        return pod
    }

    @discardableResult
    private func makeEpisode(_ pod: Podcast, guid: String, downloaded: Bool = true,
                             played: Bool = false, playedDaysAgo: Double = 0,
                             publishDaysAgo: Double = 0, withTranscript: Bool = false,
                             sourceType: String = "feed") -> Episode {
        let ep = Episode(guid: guid, title: guid, publishDate: clock.addingTimeInterval(-publishDaysAgo * 86_400),
                         duration: 100, audioURL: URL(string: "https://ex.com/\(guid).mp3")!, notes: "")
        ep.sourceType = sourceType
        ep.podcast = pod; pod.episodes.append(ep)
        ep.played = played
        if played { ep.playedDate = clock.addingTimeInterval(-playedDaysAgo * 86_400) }
        if downloaded {
            let f = DownloadedFile(localFileName: "\(guid).mp3", fileSizeBytes: 1, downloadedAt: clock)
            f.episode = ep; ep.downloadedFile = f; ctx.insert(f)
        }
        if withTranscript {
            let tr = Transcript(source: "published", language: "en")
            tr.episode = ep; ep.transcript = tr; ctx.insert(tr)
        }
        ctx.insert(ep)
        return ep
    }

    // MARK: Resolution

    func test_resolution_overrideWins_nilInherits() {
        let pod = makePodcast()
        let svc = makeService()
        settings.defaultMaxDownloadsKept = 5
        XCTAssertEqual(svc.resolvedMaxDownloadsKept(for: pod), 5, "nil override inherits global")
        pod.settings?.maxDownloadsKeptOverride = 2
        XCTAssertEqual(svc.resolvedMaxDownloadsKept(for: pod), 2, "override wins")
        pod.settings?.maxDownloadsKeptOverride = 0
        XCTAssertEqual(svc.resolvedMaxDownloadsKept(for: pod), 0, "0 = explicitly unlimited")

        settings.keepTranscriptsOnDelete = false
        XCTAssertFalse(svc.resolvedKeepTranscripts(for: pod))
        pod.settings?.keepTranscriptsOverride = true
        XCTAssertTrue(svc.resolvedKeepTranscripts(for: pod))
    }

    // MARK: Age rule

    func test_ageRule_deletesOldPlayed_archivesThem() {
        let pod = makePodcast()
        settings.defaultAutoDeleteListenedAfterDays = 3
        let old = makeEpisode(pod, guid: "old", played: true, playedDaysAgo: 5)
        let fresh = makeEpisode(pod, guid: "fresh", played: true, playedDaysAgo: 1)
        let unplayed = makeEpisode(pod, guid: "unplayed")
        makeService().evictEligibleEpisodes(for: pod)
        XCTAssertEqual(deleted, ["old"])
        XCTAssertTrue(old.isArchived, "age rule is a full delete, same as manual swipe")
        XCTAssertFalse(fresh.isArchived)
        XCTAssertFalse(unplayed.isArchived)
    }

    func test_ageRule_zeroDays_deletesImmediately_minusOneOff() {
        let pod = makePodcast()
        settings.defaultAutoDeleteListenedAfterDays = 0
        let ep = makeEpisode(pod, guid: "justPlayed", played: true, playedDaysAgo: 0)
        makeService().evictEligibleEpisodes(for: pod)
        XCTAssertTrue(ep.isArchived, "0 days = immediately")

        settings.defaultAutoDeleteListenedAfterDays = -1
        let pod2 = makePodcast()
        let ep2 = makeEpisode(pod2, guid: "kept", played: true, playedDaysAgo: 100)
        makeService().evictEligibleEpisodes(for: pod2)
        XCTAssertFalse(ep2.isArchived, "-1 = rule off")
    }

    func test_ageRule_neverEvictsArticleEpisodes_evictsEquivalentFeedEpisode() {
        let pod = makePodcast()
        settings.defaultAutoDeleteListenedAfterDays = 0   // most aggressive setting: evict immediately
        let article = makeEpisode(pod, guid: "article", played: true, playedDaysAgo: 5, sourceType: "article")
        let feedEp = makeEpisode(pod, guid: "feed", played: true, playedDaysAgo: 5, sourceType: "feed")
        makeService().evictEligibleEpisodes(for: pod)
        XCTAssertFalse(deleted.contains("article"),
                       "article audio has no re-download source — eviction would be permanent deletion")
        XCTAssertFalse(article.isArchived, "article episode must not be archived/evicted by the age rule")
        XCTAssertNotNil(article.downloadedFile, "article download must survive")
        XCTAssertEqual(deleted, ["feed"], "equivalent feed episode is evicted as before")
        XCTAssertTrue(feedEp.isArchived)
    }

    func test_capRule_neverEvictsArticleEpisodes_evictsEquivalentFeedEpisode() {
        let pod = makePodcast()
        settings.defaultMaxDownloadsKept = 1   // aggressive cap
        let article = makeEpisode(pod, guid: "article", played: true, publishDaysAgo: 10, sourceType: "article")
        let feedEp = makeEpisode(pod, guid: "feed", played: true, publishDaysAgo: 5, sourceType: "feed")
        makeService().evictEligibleEpisodes(for: pod)
        XCTAssertFalse(deleted.contains("article"),
                       "article audio has no re-download source — cap eviction would be permanent deletion")
        XCTAssertNotNil(article.downloadedFile, "article download must survive the cap sweep")
        XCTAssertEqual(deleted, ["feed"], "the newer feed episode is still evicted to respect the cap")
    }

    func test_ageRule_transcriptPurgedOnlyWhenKeepOff() {
        settings.defaultAutoDeleteListenedAfterDays = 0
        settings.keepTranscriptsOnDelete = false
        let pod = makePodcast()
        let ep = makeEpisode(pod, guid: "e", played: true, withTranscript: true)
        makeService().evictEligibleEpisodes(for: pod)
        XCTAssertNil(ep.transcript, "keep=false purges the transcript")

        settings.keepTranscriptsOnDelete = true
        let pod2 = makePodcast()
        let ep2 = makeEpisode(pod2, guid: "e2", played: true, withTranscript: true)
        makeService().evictEligibleEpisodes(for: pod2)
        XCTAssertNotNil(ep2.transcript, "keep=true retains the transcript")
    }

    // MARK: Cap rule

    func test_capRule_evictsOldestPlayedOnly_neverUnplayed() {
        let pod = makePodcast()
        settings.defaultMaxDownloadsKept = 2
        let oldPlayed = makeEpisode(pod, guid: "oldPlayed", played: true, publishDaysAgo: 10)
        makeEpisode(pod, guid: "newPlayed", played: true, publishDaysAgo: 5)
        makeEpisode(pod, guid: "unplayed1", publishDaysAgo: 20)
        makeEpisode(pod, guid: "unplayed2", publishDaysAgo: 15)
        // 4 downloaded, cap 2, overflow 2 — but only played episodes are evictable, and
        // evicting both played ones would still leave us at cap with the unplayed pair.
        makeService().evictEligibleEpisodes(for: pod)
        XCTAssertEqual(Set(deleted), ["oldPlayed", "newPlayed"],
                       "oldest played evicted; unplayed never touched despite being oldest")
        XCTAssertFalse(oldPlayed.isArchived, "cap eviction frees audio only, no archive")
    }

    func test_capRule_overflowSmallerThanPlayedPool_evictsOldestFirst() {
        let pod = makePodcast()
        settings.defaultMaxDownloadsKept = 2
        makeEpisode(pod, guid: "a", played: true, publishDaysAgo: 30)
        makeEpisode(pod, guid: "b", played: true, publishDaysAgo: 20)
        makeEpisode(pod, guid: "c", played: true, publishDaysAgo: 10)
        makeService().evictEligibleEpisodes(for: pod)
        XCTAssertEqual(deleted, ["a"], "one over cap → only the oldest played goes")
    }

    func test_capRule_zeroMeansUnlimited() {
        let pod = makePodcast()
        settings.defaultMaxDownloadsKept = 0
        for i in 0..<5 { makeEpisode(pod, guid: "e\(i)", played: true, publishDaysAgo: Double(i)) }
        makeService().evictEligibleEpisodes(for: pod)
        XCTAssertTrue(deleted.isEmpty)
    }

    // MARK: SubscriptionService integration

    func test_setPlayed_stampsPlayedDate_andTriggersSweep() throws {
        let subs = SubscriptionService(modelContext: ctx, feeds: RSSFeedClient())
        settings.defaultAutoDeleteListenedAfterDays = 0
        let svc = EpisodeRetentionService(modelContext: ctx, appSettings: settings,
                                          deleteDownload: { [self] in deleted.append($0.guid) })
        subs.retention = svc
        let pod = makePodcast()
        let ep = makeEpisode(pod, guid: "e", played: false)
        subs.setPlayed(ep, true)
        XCTAssertNotNil(ep.playedDate)
        XCTAssertTrue(ep.isArchived, "reactive sweep ran on mark-played (0 days = immediately)")
        subs.setPlayed(ep, false)
        XCTAssertNil(ep.playedDate, "un-playing clears the stamp")
    }

    func test_unsubscribe_freesDownloads_andPurgesTranscriptsWhenKeepOff() {
        let subs = SubscriptionService(modelContext: ctx, feeds: RSSFeedClient())
        settings.keepTranscriptsOnDelete = false
        subs.retention = makeService()
        subs.deleteDownload = { [self] ep in deleted.append(ep.guid); ep.downloadedFile = nil }
        let pod = makePodcast(); pod.isSubscribed = true
        let ep = makeEpisode(pod, guid: "e", withTranscript: true)
        subs.unsubscribe(pod)
        XCTAssertFalse(pod.isSubscribed)
        XCTAssertEqual(deleted, ["e"])
        XCTAssertNil(ep.transcript)
    }

    func test_unsubscribe_keepsTranscriptsWhenKeepOn() {
        let subs = SubscriptionService(modelContext: ctx, feeds: RSSFeedClient())
        settings.keepTranscriptsOnDelete = true
        subs.retention = makeService()
        subs.deleteDownload = { [self] ep in deleted.append(ep.guid); ep.downloadedFile = nil }
        let pod = makePodcast(); pod.isSubscribed = true
        let ep = makeEpisode(pod, guid: "e", withTranscript: true)
        subs.unsubscribe(pod)
        XCTAssertEqual(deleted, ["e"], "audio always freed on unsubscribe")
        XCTAssertNotNil(ep.transcript, "transcripts survive when keep is on")
    }
}
