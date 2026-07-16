//  LibrarySearchView.swift
import SwiftUI
import SwiftData

struct LibrarySearchView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(PlaybackManager.self) private var playback
    @Environment(\.modelContext) private var modelContext
    @Query private var episodes: [Episode]

    @State private var query = ""
    @State private var hits: [TranscriptHit] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(theme.color(.textTertiary))
                    TextField("Search transcripts", text: $query)
                        .textInputAutocapitalization(.never)
                }
                .padding(.horizontal, 14).frame(height: 48)
                .background(theme.color(.bgElevated)).brutalBorder(width: 2.5)
                .padding(20)

                List(hits) { hit in
                    Button { open(hit) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hit.showTitle).brutalHeader(size: 12).foregroundStyle(theme.color(.accent))
                            Text(hit.cueText).font(.system(size: 15)).foregroundStyle(theme.color(.text))
                                .lineLimit(2)
                            Text(hit.episodeTitle + " · " + timeStr(hit.startTime))
                                .font(.system(size: 12)).foregroundStyle(theme.color(.textTertiary))
                        }
                    }
                }
                .listStyle(.plain)
            }
            .background(theme.color(.bg))
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: query) { _, q in
                hits = TranscriptSearch(modelContext: modelContext).search(q)
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
