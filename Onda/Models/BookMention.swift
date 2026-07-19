//  BookMention.swift
//  A VERIFIED book reference extracted from one episode (Books Mentioned feature).
//  Only catalog-verified books are ever persisted — see the design spec's precision rule.
import Foundation
import SwiftData

@Model
final class BookMention {
    var workKey: String          // OpenLibrary work key — per-episode dedupe key
    var title: String            // canonical title from the catalog, not the raw candidate
    var author: String?
    var coverURL: URL?
    var sourceTier: String       // "link" | "notes" | "transcript"
    var timestamp: TimeInterval? // feed-seconds; transcript-derived mentions only
    var createdAt: Date

    var episode: Episode?

    init(workKey: String, title: String, author: String?, coverURL: URL?,
         sourceTier: String, timestamp: TimeInterval?, createdAt: Date = .now) {
        self.workKey = workKey
        self.title = title
        self.author = author
        self.coverURL = coverURL
        self.sourceTier = sourceTier
        self.timestamp = timestamp
        self.createdAt = createdAt
    }
}
