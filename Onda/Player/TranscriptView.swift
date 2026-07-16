//  TranscriptView.swift
import SwiftUI

struct TranscriptView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(PlaybackManager.self) private var playback
    @Environment(TranscriptService.self) private var transcripts
    let episode: Episode

    @State private var transcript: Transcript?
    @State private var loading = false
    @State private var transcribing = false

    private var cues: [TranscriptCue] {
        (transcript?.cues ?? []).sorted { $0.startTime < $1.startTime }
    }
    private var activeIndex: Int? {
        ActiveCue.index(at: playback.positionSeconds, cues: cues.map { ($0.startTime, $0.endTime) })
    }

    var body: some View {
        NavigationStack {
            Group {
                if let t = transcript, !t.cues.isEmpty { transcriptList }
                else if loading || transcribing { progressState }
                else { emptyState }
            }
            .background(theme.color(.bg))
            .navigationTitle("Transcript")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await load() }
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(cues.enumerated()), id: \.offset) { i, cue in
                        Button {
                            playback.seek(toFraction: cue.startTime / max(1, episode.duration))
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                if let s = cue.speaker {
                                    Text(s).font(.system(size: 12, weight: .bold)).textCase(.uppercase)
                                        .foregroundStyle(theme.color(.accent))
                                }
                                Text(cue.text).font(.system(size: 16))
                                    .foregroundStyle(i == activeIndex ? theme.color(.text) : theme.color(.textTertiary))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(i == activeIndex ? theme.color(.accentWash) : .clear)
                        }
                        .buttonStyle(.plain).id(i)
                    }
                }.padding(20)
            }
            .onChange(of: activeIndex) { _, new in
                if let new { withAnimation { proxy.scrollTo(new, anchor: .center) } }
            }
        }
    }

    private var progressState: some View {
        VStack(spacing: 12) {
            ProgressView(value: transcripts.progress[episode.guid] ?? 0)
                .tint(theme.color(.accent)).frame(maxWidth: 220)
            Text(transcribing ? "Transcribing on device…" : "Loading transcript…")
                .foregroundStyle(theme.color(.textTertiary))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("No transcript available").foregroundStyle(theme.color(.textTertiary))
            if transcripts.canTranscribeOnDevice(episode) {
                Button("Transcribe episode") { Task { await transcribe() } }
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(theme.color(.accent)).brutalBorder(width: 2)
            } else {
                Text("Available for downloaded episodes on iOS 26+")
                    .font(.system(size: 13)).foregroundStyle(theme.color(.textTertiary))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        guard transcript == nil else { return }
        // Only auto-load the cheap published path; on-device requires an explicit tap.
        if episode.transcript != nil || episode.transcriptURL != nil {
            loading = true
            transcript = await transcripts.transcript(for: episode)
            loading = false
        }
    }

    private func transcribe() async {
        guard await TranscriptService.requestSpeechAuthorization() else { return }
        transcribing = true
        transcript = await transcripts.transcript(for: episode)
        transcribing = false
    }
}
