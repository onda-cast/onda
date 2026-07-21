//  ShowTranscriptsView.swift
//  Full-screen browser for a single show's transcripts: lists episodes that have a transcript,
//  searchable across the transcript text, tapping opens the transcript reader.
import SwiftUI

struct ShowTranscriptsView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(PlaybackManager.self) private var playback
    @Environment(\.dismiss) private var dismiss
    let podcast: Podcast

    @State private var query = ""
    @State private var reading: Episode?
    // Recomputed explicitly (task + onChange(of: query)) instead of as a plain computed
    // property — `results` used to re-scan every transcribed episode's cues on every render,
    // not just when the query actually changed.
    @State private var transcribed: [Episode] = []
    @State private var results: [(episode: Episode, snippet: String?)] = []

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    searchBar
                    if transcribed.isEmpty {
                        empty("No transcripts yet for this show")
                    } else if results.isEmpty {
                        empty("No transcripts match “\(query)”")
                    } else {
                        ForEach(results, id: \.episode.guid) { row in
                            Button { reading = row.episode } label: { card(row.episode, snippet: row.snippet) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
            }
            .background(theme.color(.bg))
            .navigationTitle("Transcripts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(item: $reading) { TranscriptView(episode: $0) }
            // A transcript jump opens the player; close this browser too so it can present.
            .onChange(of: playback.transcriptJumpNonce) { _, _ in dismiss() }
            .task { recomputeTranscribed() }
            .onChange(of: query) { _, _ in recomputeResults() }
        }
    }

    private func recomputeTranscribed() {
        transcribed = podcast.episodes
            .filter { !($0.transcript?.cues.isEmpty ?? true) }
            .sorted { $0.publishDate > $1.publishDate }
        recomputeResults()
    }

    private func recomputeResults() {
        guard isSearching else {
            results = transcribed.map { ($0, nil) }
            return
        }
        let needle = query.lowercased()
        results = transcribed.compactMap { ep in
            let cues = ep.transcript?.cues ?? []
            guard let hit = cues.first(where: { $0.text.lowercased().contains(needle) }) else { return nil }
            return (ep, hit.text)
        }
    }

    private var searchBar: some View {
        BrutalSearchField("Search transcripts", text: $query)
    }

    private func card(_ ep: Episode, snippet: String?) -> some View {
        BrutalCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(ep.title).scaledFont(15, weight: .bold).lineLimit(2)
                    .foregroundStyle(theme.color(.text))
                if let snippet {
                    Text(snippet).scaledFont(13).lineLimit(2)
                        .foregroundStyle(theme.color(.textSecondary))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).foregroundStyle(theme.color(.textTertiary))
            .frame(maxWidth: .infinity).padding(.top, 60)
    }
}
