//  ClipsView.swift
import SwiftUI

struct ClipsView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(ClipService.self) private var clips
    @Environment(PlaybackManager.self) private var playback

    @State private var query = ""
    @State private var editing: Clip?
    @State private var refreshKey = 0
    @State private var shareItems: ShareItems?
    @State private var exporting = false

    struct ShareItems: Identifiable {
        let id = UUID()
        let fileURL: URL
        let text: String
    }

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
                            ClipRow(clip: clip,
                                    onPlay: { playback.playClip(clip) },
                                    onShare: { share(clip) })
                                .onTapGesture { editing = clip }
                                .contextMenu {
                                    Button {
                                        UIPasteboard.general.string = MarkdownExport.clipMarkdown(clip)
                                    } label: { Label("Copy as Markdown", systemImage: "doc.on.doc") }
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if let url = try? MarkdownExport.writeDocument(clips: clips.allClips()) {
                            shareItems = ShareItems(fileURL: url, text: "Onda clips export")
                        }
                    } label: { Image(systemName: "square.and.arrow.up.on.square").accessibilityLabel("Export All") }
                    .disabled(clips.allClips().isEmpty)
                }
            }
            .sheet(item: $editing) { ClipEditSheet(clip: $0) }
            .sheet(item: $shareItems) { items in
                ActivityShareSheet(items: [items.fileURL, items.text])
            }
            .overlay {
                if exporting {
                    ProgressView("Exporting clip\u{2026}")
                        .padding(20).background(theme.color(.bgElevated)).brutalBorder(width: 2)
                }
            }
        }
    }

    private func share(_ clip: Clip) {
        guard !exporting else { return }
        exporting = true
        let exporter = ClipExporter(sourceURL: { [playback] ep in
            playback.localURL(for: ep) ?? ep.audioURL
        })
        Task {
            defer { exporting = false }
            guard let url = try? await exporter.export(clip: clip) else { return }
            shareItems = ShareItems(fileURL: url, text: ClipExporter.shareText(for: clip))
        }
    }
}

// Minimal UIKit bridge — ShareLink can't take a lazily-exported file + text pair cleanly.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

extension Clip: Identifiable {}
