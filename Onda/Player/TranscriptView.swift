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
    @State private var selecting = false
    @State private var selStart: Int?
    @State private var selEnd: Int?
    @State private var showClipSheet = false

    // Plain-value snapshot of the cues, built ONCE per transcript. Rendering must never
    // touch (or re-sort) the SwiftData models per playback tick — that faulted thousands
    // of models twice a second and hung the main thread on device (watchdog kill).
    struct CueVM: Identifiable, Equatable {
        let id: Int
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        let speaker: String?
    }
    @State private var cueVMs: [CueVM] = []
    @State private var timeRanges: [(start: TimeInterval, end: TimeInterval)] = []
    @State private var lastUserScrollAt: Date = .distantPast

    // Highlight only applies when THIS episode is the one loaded in the player.
    private var isCurrentEpisode: Bool { playback.currentEpisode?.guid == episode.guid }
    // Auto-scroll only while it's actually playing, and never while the user is reading around.
    private var isFollowing: Bool { isCurrentEpisode && playback.isPlaying }

    private var activeIndex: Int? {
        guard isCurrentEpisode else { return nil }
        return ActiveCue.index(at: playback.positionSeconds, cues: timeRanges)
    }

    private func snapshotCues() {
        let sorted = (transcript?.cues ?? []).sorted { $0.startTime < $1.startTime }
        cueVMs = sorted.enumerated().map { i, c in
            CueVM(id: i, start: c.startTime, end: c.endTime, text: c.text, speaker: c.speaker)
        }
        timeRanges = cueVMs.map { ($0.start, $0.end) }
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
            .toolbar {
                if transcript != nil, !(transcript?.cues.isEmpty ?? true) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(selecting ? "Done" : "Select") {
                            selecting.toggle(); selStart = nil; selEnd = nil
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting, let lo = selectionRange?.lowerBound, let hi = selectionRange?.upperBound {
                    Button {
                        showClipSheet = true
                    } label: {
                        Text("Clip \(hi - lo + 1) line\(hi == lo ? "" : "s")")
                            .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(theme.color(.accent)).brutalBorder(width: 2)
                    }
                    .buttonStyle(.plain).padding(16)
                    .background(theme.color(.bg))
                }
            }
            .sheet(isPresented: $showClipSheet, onDismiss: { selecting = false; selStart = nil; selEnd = nil }) {
                if let r = selectionRange {
                    ClipEditSheet(episode: episode,
                                  requestedStart: cueVMs[r.lowerBound].start,
                                  requestedEnd: cueVMs[r.upperBound].end)
                }
            }
        }
        .task { await load() }
    }

    private var selectionRange: ClosedRange<Int>? {
        guard let s = selStart else { return nil }
        let e = selEnd ?? s
        return min(s, e)...max(s, e)
    }

    private func handleSelectionTap(_ i: Int) {
        if let s = selStart, selEnd == nil, i != s { selEnd = i }
        else { selStart = i; selEnd = nil }
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(cueVMs) { cue in
                        let i = cue.id
                        Button {
                            if selecting { handleSelectionTap(i) }
                            else { playback.seek(toFraction: cue.start / max(1, episode.duration)) }
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
                            .background(
                                (selecting && (selectionRange?.contains(i) ?? false))
                                    ? theme.color(.accentWash)
                                    : (i == activeIndex && !selecting ? theme.color(.accentWash) : .clear))
                        }
                        .buttonStyle(.plain).id(i)
                    }
                }.padding(20)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 10).onChanged { _ in lastUserScrollAt = .now }
            )
            .onChange(of: activeIndex) { _, new in
                guard let new, isFollowing,
                      Date.now.timeIntervalSince(lastUserScrollAt) > 4 else { return }
                withAnimation { proxy.scrollTo(new, anchor: .center) }
            }
            .onChange(of: cueVMs.count) { _, _ in
                // Jump to the currently-playing line as soon as cues are available.
                if let i = activeIndex { proxy.scrollTo(i, anchor: .center) }
            }
            .onAppear {
                if let i = activeIndex { proxy.scrollTo(i, anchor: .center) }
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
            if let failure = transcripts.lastFailure[episode.guid] {
                Text(failure)
                    .font(.system(size: 13)).multilineTextAlignment(.center)
                    .foregroundStyle(.red).padding(.horizontal, 24)
            }
            if transcripts.canTranscribeOnDevice(episode) {
                Button("Transcribe episode") { Task { await transcribe() } }
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(theme.color(.accent)).brutalBorder(width: 2)
            } else if transcripts.hasEngine {
                Text("Download this episode to transcribe it on device")
                    .font(.system(size: 13)).foregroundStyle(theme.color(.textTertiary))
            } else {
                Text("On-device transcription requires iOS 26 or later")
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
            snapshotCues()
            loading = false
        }
    }

    private func transcribe() async {
        guard await TranscriptService.requestSpeechAuthorization() else { return }
        transcribing = true
        transcript = await transcripts.transcript(for: episode)
        snapshotCues()
        transcribing = false
    }
}
