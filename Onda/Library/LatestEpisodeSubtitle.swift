//  LatestEpisodeSubtitle.swift
import SwiftUI
import SwiftData

/// A show card's subtitle: its most recent episode's title. A scoped, limit-1 query sorted by
/// `publishDate` — NOT `podcast.episodes.first`, which faults the ENTIRE episodes relationship
/// array on every render (a real per-render cost at library scale) and isn't even guaranteed to
/// be the newest episode (relationship order is insertion order, not publish order).
struct LatestEpisodeSubtitle: View {
    @Environment(AppTheme.self) private var theme
    @Query private var latest: [Episode]

    init(podcast: Podcast) {
        let feedURL = podcast.feedURL
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { $0.podcast?.feedURL == feedURL },
            sortBy: [SortDescriptor(\.publishDate, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        _latest = Query(descriptor)
    }

    var body: some View {
        Text(latest.first?.title ?? "No episodes")
            .scaledFont(12.5).foregroundStyle(theme.color(.textTertiary))
            .lineLimit(1)
    }
}
