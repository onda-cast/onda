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
    @State private var searchTask: Task<Void, Never>?

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                BrutalSearchField("Try: gold standard by Tracy in Odd Lots", text: $query)
                    .padding(.horizontal, 20).padding(.top, 20)
                // The search only reaches what's been transcribed — make that explicit up front
                // rather than leaving an empty result read as "broken."
                Text("Searches your transcripts \u{2014} shows without one won\u{2019}t appear here.")
                    .scaledFont(12).foregroundStyle(theme.color(.textTertiary))
                    .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 14)

                if !isSearching {
                    BrutalEmptyState(
                        "Search across every transcript",
                        detail: "Find a phrase, topic, or speaker from any episode you\u{2019}ve transcribed.")
                } else if hits.isEmpty {
                    BrutalEmptyState("No matches for \u{201C}\(query)\u{201D}",
                        detail: "Try a shorter phrase, or a different show/speaker name.")
                } else {
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
                        .listRowBackground(theme.color(.bg))
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            // Fill the sheet — a hugging VStack left the theme background as a floating band
            // centered in a white sheet (reported unstyled).
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(theme.color(.bg))
            .navigationTitle("Search Transcripts")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: query) { _, q in
                searchTask?.cancel()
                guard let index = searchIndexBox.index else {
                    hits = []
                    return
                }
                // Debounced like Discover's search: smartSearch spins up NLTagger POS/NER
                // tagging plus an FTS5 query — running it on every keystroke (no debounce)
                // could visibly stutter typing.
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    // Natural-language path: "book mentioned by michael in odd lots" —
                    // parses show/speaker filters, lemmatizes terms, then FTS5 retrieval.
                    hits = TranscriptSearch(modelContext: modelContext, index: index)
                        .smartSearch(q, knownShows: subscribedShows.map(\.title))
                }
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
