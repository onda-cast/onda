//  DownloadsStorageView.swift
import SwiftUI
import SwiftData

struct DownloadsStorageView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Podcast> { $0.isSubscribed }) private var podcasts: [Podcast]

    @State private var refreshKey = 0
    @State private var confirmClearAudio = false
    @State private var confirmClearTranscripts = false

    private var breakdown: StorageBreakdown {
        _ = refreshKey
        return StorageCalculator.breakdown(podcasts: podcasts)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                let bd = breakdown
                typeBar(bd)
                if bd.podcasts.isEmpty {
                    Text("Nothing stored yet").foregroundStyle(theme.color(.textTertiary))
                        .frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    Text("By Podcast").brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
                    ForEach(bd.podcasts) { row in podcastCard(row) }
                }
            }
            .padding(20)
        }
        .background(theme.color(.bg))
        .navigationTitle("Downloads & Storage")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete all downloaded audio?", isPresented: $confirmClearAudio,
                            titleVisibility: .visible) {
            Button("Delete Audio", role: .destructive) { clearAllAudio() }
        } message: { Text("Frees storage. Episodes stay and can be streamed or re-downloaded.") }
        .confirmationDialog("Delete all transcripts?", isPresented: $confirmClearTranscripts,
                            titleVisibility: .visible) {
            Button("Delete Transcripts", role: .destructive) { clearAllTranscripts() }
        } message: { Text("Removes saved transcripts and makes them un-searchable.") }
    }

    // MARK: Type bar

    private func typeBar(_ bd: StorageBreakdown) -> some View {
        BrutalCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Storage Used").brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
                    Spacer()
                    Text(sizeStr(bd.totalBytes)).font(.system(size: 15, weight: .bold)).monospacedDigit()
                        .foregroundStyle(theme.color(.text))
                }
                proportionBar(audio: bd.audioBytes, transcript: bd.transcriptBytes)
                HStack(spacing: 16) {
                    legend(color: theme.color(.accent), label: "Audio", bytes: bd.audioBytes)
                    legend(color: theme.color(.accent).opacity(0.45), label: "Transcripts",
                           bytes: bd.transcriptBytes)
                }
                HStack(spacing: 10) {
                    smallButton("Clear Audio") { confirmClearAudio = true }
                        .opacity(bd.audioBytes > 0 ? 1 : 0.4).disabled(bd.audioBytes == 0)
                    smallButton("Clear Transcripts") { confirmClearTranscripts = true }
                        .opacity(bd.transcriptBytes > 0 ? 1 : 0.4).disabled(bd.transcriptBytes == 0)
                }
            }
            .padding(16)
        }
    }

    private func proportionBar(audio: Int64, transcript: Int64) -> some View {
        let total = max(1, audio + transcript)
        return GeometryReader { geo in
            HStack(spacing: 0) {
                Rectangle().fill(theme.color(.accent))
                    .frame(width: geo.size.width * CGFloat(audio) / CGFloat(total))
                Rectangle().fill(theme.color(.accent).opacity(0.45))
                    .frame(width: geo.size.width * CGFloat(transcript) / CGFloat(total))
                Rectangle().fill(theme.color(.separator))
            }
        }
        .frame(height: 16).brutalBorder(width: 2)
    }

    private func legend(color: Color, label: String, bytes: Int64) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(color).frame(width: 12, height: 12).brutalBorder(width: 1.5)
            Text("\(label) \(sizeStr(bytes))").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.color(.textSecondary))
        }
    }

    // MARK: Per-podcast

    private func podcastCard(_ row: StoragePodcastRow) -> some View {
        BrutalCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                        .foregroundStyle(theme.color(.text))
                    Text("Audio \(sizeStr(row.audioBytes)) · Transcripts \(sizeStr(row.transcriptBytes))")
                        .font(.system(size: 12)).foregroundStyle(theme.color(.textTertiary))
                }
                Spacer()
                Menu {
                    if row.audioBytes > 0 {
                        Button(role: .destructive) { deleteAudio(row.id) } label: {
                            Label("Delete Downloads", systemImage: "trash")
                        }
                    }
                    if row.transcriptBytes > 0 {
                        Button(role: .destructive) { deleteTranscripts(row.id) } label: {
                            Label("Delete Transcripts", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 16, weight: .bold))
                        .foregroundStyle(theme.color(.textSecondary))
                        .frame(width: 40, height: 40)
                }
            }
            .padding(14)
        }
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.color(.text))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(theme.color(.bg)).brutalBorder(width: 2)
        }.buttonStyle(.plain)
    }

    // MARK: Mutations

    private func podcast(_ id: String) -> Podcast? { podcasts.first { $0.feedURL.absoluteString == id } }

    private func deleteAudio(_ id: String) {
        guard let pod = podcast(id) else { return }
        for ep in pod.episodes where ep.downloadedFile != nil { downloads.delete(ep) }
        bump()
    }

    private func deleteTranscripts(_ id: String) {
        guard let pod = podcast(id) else { return }
        for ep in pod.episodes { removeTranscript(ep) }
        try? modelContext.save(); bump()
    }

    private func clearAllAudio() {
        for pod in podcasts { for ep in pod.episodes where ep.downloadedFile != nil { downloads.delete(ep) } }
        bump()
    }

    private func clearAllTranscripts() {
        for pod in podcasts { for ep in pod.episodes { removeTranscript(ep) } }
        try? modelContext.save(); bump()
    }

    private func removeTranscript(_ ep: Episode) {
        guard let tr = ep.transcript else { return }
        ep.transcript = nil
        modelContext.delete(tr)   // cascades cues
    }

    // Download deletes happen on a background actor; nudge the view to recompute sizes after.
    private func bump() {
        Task { try? await Task.sleep(for: .milliseconds(150)); refreshKey += 1 }
    }

    private func sizeStr(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
