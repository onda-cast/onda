//  Podcast.swift
import Foundation
import SwiftData

@Model
final class Podcast {
    @Attribute(.unique) var feedURL: URL
    var title: String
    var author: String
    var artworkURL: URL?
    var category: String
    var itunesId: Int?
    var isSubscribed: Bool
    /// True for shows added via a tokenized private/paid feed URL. The URL contains a secret,
    /// so private shows are kept out of anything that leaves the device (taste profile, future
    /// share/export surfaces).
    var isPrivateFeed: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \Episode.podcast)
    var episodes: [Episode] = []

    @Relationship(deleteRule: .cascade, inverse: \ShowSettings.podcast)
    var settings: ShowSettings?

    init(feedURL: URL, title: String, author: String, artworkURL: URL?,
         category: String, itunesId: Int?, isSubscribed: Bool = false,
         isPrivateFeed: Bool = false) {
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.artworkURL = artworkURL
        self.category = category
        self.itunesId = itunesId
        self.isSubscribed = isSubscribed
        self.isPrivateFeed = isPrivateFeed
    }
}
