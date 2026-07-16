//  ClipsView.swift
import SwiftUI

struct ClipsView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(ClipService.self) private var clips
    @Environment(PlaybackManager.self) private var playback

    @State private var query = ""
    @State private var editing: Clip?
    @State private var refreshKey = 0

    private var results: [Clip] { _ = refreshKey; return clips.search(query) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(theme.color(.textTertiary))
                        TextField("Search clips", text: $query)
                            .textInputAutocapitalization(.never)
                    }
                    .padding(.horizontal, 14).frame(height: 48)
                    .background(theme.color(.bgElevated)).brutalBorder(width: 2.5)

                    if results.isEmpty {
                        Text(query.isEmpty ? "No clips yet — select transcript lines or tap the bookmark on your lock screen while listening."
                                           : "No clips match")
                            .foregroundStyle(theme.color(.textTertiary))
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        ForEach(results, id: \.createdAt) { clip in
                            ClipRow(clip: clip) { playback.playClip(clip) }
                                .onTapGesture { editing = clip }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        clips.delete(clip); refreshKey += 1
                                    } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                    }
                }
                .padding(20)
            }
            .background(theme.color(.bg))
            .navigationTitle("Clips")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editing) { ClipEditSheet(clip: $0) }
        }
    }
}

extension Clip: Identifiable {}
