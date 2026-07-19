//  Episode.swift
import Foundation
import SwiftData

@Model
final class Episode {
    @Attribute(.unique) var guid: String
    var title: String
    var publishDate: Date
    var duration: TimeInterval
    var audioURL: URL
    var notes: String
    var noteLinks: [URL] = []   // hrefs from the feed description — Books Mentioned link tier
    var playbackPosition: TimeInterval
    var played: Bool
    var playedDate: Date?   // stamped when marked played; drives the auto-delete-after-N-days rule
    var isArchived: Bool = false   // soft-deleted: hidden everywhere, clips/transcript may remain
    var sourceType: String = "feed"   // "feed" | "article" — mirrors Chapter.source tagging
    var chaptersURL: URL?
    var transcriptURL: URL?
    var transcriptType: String?

    var podcast: Podcast?

    @Relationship(deleteRule: .cascade, inverse: \Chapter.episode)
    var chapters: [Chapter] = []

    @Relationship(deleteRule: .cascade, inverse: \DownloadedFile.episode)
    var downloadedFile: DownloadedFile?

    @Relationship(deleteRule: .cascade, inverse: \Transcript.episode)
    var transcript: Transcript?

    @Relationship(deleteRule: .cascade, inverse: \ArticleSource.episode)
    var articleSource: ArticleSource?

    @Relationship(deleteRule: .cascade, inverse: \Clip.episode)
    var clips: [Clip] = []

    init(guid: String, title: String, publishDate: Date, duration: TimeInterval,
         audioURL: URL, notes: String, noteLinks: [URL] = [], playbackPosition: TimeInterval = 0,
         played: Bool = false,
         chaptersURL: URL? = nil, transcriptURL: URL? = nil, transcriptType: String? = nil) {
        self.chaptersURL = chaptersURL
        self.transcriptURL = transcriptURL
        self.transcriptType = transcriptType
        self.guid = guid
        self.title = title
        self.publishDate = publishDate
        self.duration = duration
        self.audioURL = audioURL
        self.notes = notes
        self.noteLinks = noteLinks
        self.playbackPosition = playbackPosition
        self.played = played
    }
}
