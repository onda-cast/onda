//  ClipsView.swift
import SwiftUI
import SwiftData

struct ClipsView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(ClipService.self) private var clips
    @Environment(PlaybackManager.self) private var playback
    // Drive the list off @Query so clips created via transcript selection or the lock screen
    // appear immediately (the old cached fetch only refreshed on delete).
    @Query(sort: \Clip.createdAt, order: .reverse) private var allClips: [Clip]

    @State private var query = ""
    @State private var editing: Clip?
    @State private var shareItems: ShareItems?
    @State private var exporting = false
    @State private var exportError: String?

    struct ShareItems: Identifiable {
        let id = UUID()
        let fileURL: URL
        let text: String
    }

    private var results: [Clip] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return allClips }
        return allClips.filter {
            $0.text.localizedCaseInsensitiveContains(q) || ($0.note?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    BrutalSearchField("Search clips", text: $query)

                    if results.isEmpty {
                        Text(emptyStateText)
                            .foregroundStyle(theme.color(.textTertiary))
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        ForEach(results) { clip in
                            ClipRow(clip: clip,
                                    onPlay: { playback.playClip(clip) },
                                    onShare: { share(clip) })
                                .onTapGesture { editing = clip }
                                .contextMenu {
                                    Button {
                                        UIPasteboard.general.string = MarkdownExport.clipMarkdown(clip)
                                    } label: { Label("Copy as Markdown", systemImage: "doc.on.doc") }
                                    Button(role: .destructive) {
                                        clips.delete(clip)
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
                        do {
                            let url = try MarkdownExport.writeDocument(clips: allClips)
                            shareItems = ShareItems(fileURL: url, text: "Onda clips export")
                        } catch {
                            exportError = "Couldn't export clips: \(error.localizedDescription)"
                        }
                    } label: { Image(systemName: "square.and.arrow.up.on.square").accessibilityLabel("Export All") }
                    .disabled(allClips.isEmpty)
                }
            }
            .sheet(item: $editing) { ClipReviewSheet(clip: $0) }
            .sheet(item: $shareItems) { items in
                ActivityShareSheet(items: [items.fileURL, items.text])
            }
            .overlay {
                if exporting {
                    ProgressView("Exporting clip\u{2026}")
                        .padding(20).background(theme.color(.bgElevated)).brutalBorder(width: 2)
                }
            }
            .alert("Export failed", isPresented: Binding(get: { exportError != nil },
                                                         set: { if !$0 { exportError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(exportError ?? "") }
        }
    }

    private var emptyStateText: String {
        guard query.isEmpty else { return "No clips match" }
        let secs = Int(ClipService.quickClipWindow)
        return "No clips yet — tap the scissors in the player, select transcript lines, or tap "
            + "the bookmark on your lock screen to save the last \(secs)s."
    }

    private func share(_ clip: Clip) {
        guard !exporting else { return }
        exporting = true
        let exporter = ClipExporter(sourceURL: { [playback] ep in
            playback.localURL(for: ep) ?? ep.audioURL
        })
        Task {
            defer { exporting = false }
            do {
                let url = try await exporter.export(clip: clip)
                shareItems = ShareItems(fileURL: url, text: ClipExporter.shareText(for: clip))
            } catch {
                exportError = "Couldn't export this clip. If the episode isn't downloaded, try downloading it first."
            }
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
