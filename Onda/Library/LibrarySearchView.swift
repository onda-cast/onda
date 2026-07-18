//  LibrarySearchView.swift
import SwiftUI
import SwiftData

struct LibrarySearchView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(PlaybackManager.self) private var playback
    @Environment(\.modelContext) private var modelContext
    @Environment(SearchIndexBox.self) private var searchIndexBox
    @Query private var episodes: [Episode]
    @Query(filter: #Predicate<Podcast> { $0.isSubscribed }) private var subscribedShows: [Podcast]

    @State private var query = ""
    @State private var hits: [TranscriptHit] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                BrutalSearchField("Try: gold standard by Tracy in Odd Lots", text: $query)
                    .padding(20)

                List(hits) { hit in
                    Button { open(hit) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hit.showTitle).brutalHeader(size: 12).foregroundStyle(theme.color(.accent))
                            Text(hit.cueText).scaledFont(15).foregroundStyle(theme.color(.text))
                                .lineLimit(2)
                            Text(hit.episodeTitle + " · " + timeStr(hit.startTime))
                                .scaledFont(12).foregroundStyle(theme.color(.textTertiary))
                        }
                    }
                }
                .listStyle(.plain)
            }
            .background(theme.color(.bg))
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: query) { _, q in
                guard let index = searchIndexBox.index else {
                    hits = []
                    return
                }
                // Natural-language path: "book mentioned by michael in odd lots" —
                // parses show/speaker filters, lemmatizes terms, then FTS5 retrieval.
                hits = TranscriptSearch(modelContext: modelContext, index: index)
                    .smartSearch(q, knownShows: subscribedShows.map(\.title))
            }
        }
    }

    private func open(_ hit: TranscriptHit) {
        guard let ep = episodes.first(where: { $0.guid == hit.episodeGuid }) else { return }
        playback.play(ep)
        playback.seek(toFraction: hit.startTime / max(1, ep.duration))
    }

    private func timeStr(_ s: TimeInterval) -> String {
        let t = Int(s); return String(format: "%d:%02d", t / 60, t % 60)
    }
}
