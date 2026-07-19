//  DownloadsStorageView.swift
import SwiftUI
import SwiftData

struct DownloadsStorageView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Podcast> { $0.isSubscribed }) private var podcasts: [Podcast]

    @State private var refreshKey = 0
    @State private var bumpTask: Task<Void, Never>?
    @State private var confirmClearAudio = false
    @State private var confirmClearTranscripts = false
    @State private var pendingDelete: PendingDelete?

    private enum PendingDelete: Identifiable {
        case audio(String), transcripts(String)
        var id: String {
            switch self {
            case .audio(let i): return "a-\(i)"
            case .transcripts(let i): return "t-\(i)"
            }
        }
    }

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
        .confirmationDialog(pendingDeleteTitle,
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { pd in
            Button("Delete", role: .destructive) {
                switch pd {
                case .audio(let id): deleteAudio(id)
                case .transcripts(let id): deleteTranscripts(id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pd in
            switch pd {
            case .audio: Text("Frees the audio. Episodes stay and can be streamed or re-downloaded.")
            case .transcripts: Text("Removes this show's transcripts and makes them un-searchable.")
            }
        }
    }

    private var pendingDeleteTitle: String {
        switch pendingDelete {
        case .audio: return "Delete this show's downloads?"
        case .transcripts: return "Delete this show's transcripts?"
        case nil: return ""
        }
    }

    // MARK: Type bar

    private func typeBar(_ bd: StorageBreakdown) -> some View {
        BrutalCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Downloads & Transcripts").brutalHeader(size: 13)
                        .foregroundStyle(theme.color(.textTertiary))
                    Spacer()
                    // "~" because transcript bytes are estimated from cue text length
                    // (StorageBreakdown) — the legends below already mark them "~".
                    Text("~" + sizeStr(bd.totalBytes)).scaledFont(15, weight: .bold).monospacedDigit()
                        .foregroundStyle(theme.color(.text))
                }
                proportionBar(audio: bd.audioBytes, transcript: bd.transcriptBytes)
                HStack(spacing: 16) {
                    legend(color: theme.color(.accent), label: "Audio", bytes: bd.audioBytes)
                    legend(color: theme.color(.accent).opacity(0.45), label: "Transcripts",
                           bytes: bd.transcriptBytes, approx: true)
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

    private func legend(color: Color, label: String, bytes: Int64, approx: Bool = false) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(color).frame(width: 12, height: 12).brutalBorder(width: 1.5)
            Text("\(label) \(approx ? "~" : "")\(sizeStr(bytes))").scaledFont(12, weight: .semibold)
                .foregroundStyle(theme.color(.textSecondary))
        }
    }

    // MARK: Per-podcast

    private func podcastCard(_ row: StoragePodcastRow) -> some View {
        BrutalCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title).scaledFont(15, weight: .bold).lineLimit(1)
                        .foregroundStyle(theme.color(.text))
                    Text("Audio \(sizeStr(row.audioBytes)) · Transcripts ~\(sizeStr(row.transcriptBytes))")
                        .scaledFont(12).foregroundStyle(theme.color(.textTertiary))
                }
                Spacer()
                Menu {
                    if row.audioBytes > 0 {
                        Button(role: .destructive) { pendingDelete = .audio(row.id) } label: {
                            Label("Delete Downloads", systemImage: "trash")
                        }
                    }
                    if row.transcriptBytes > 0 {
                        Button(role: .destructive) { pendingDelete = .transcripts(row.id) } label: {
                            Label("Delete Transcripts", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").scaledFont(16, weight: .bold)
                        .foregroundStyle(theme.color(.textSecondary))
                        .frame(width: 40, height: 40)
                }
            }
            .padding(14)
        }
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).scaledFont(12, weight: .bold)
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

    // Recompute sizes right away — breakdown reads fileSizeBytes off the model, and the delete is
    // already applied+saved by the time we're here, so there's no need to wait 150ms (that fixed
    // guess is what let a stale size flash through). A single coalesced follow-up catches the
    // background actor's on-disk settle without stacking overlapping timers on fast re-entry.
    private func bump() {
        refreshKey += 1
        bumpTask?.cancel()
        bumpTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled { refreshKey += 1 }
        }
    }

    private func sizeStr(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
