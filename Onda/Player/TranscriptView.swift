//  TranscriptView.swift
import SwiftUI
import UIKit   // UIColor / UIFont for the SelectableCueText attributed styling

struct TranscriptView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(PlaybackManager.self) private var playback
    @Environment(TranscriptService.self) private var transcripts
    @Environment(\.dismiss) private var dismiss
    let episode: Episode

    @State private var transcript: Transcript?
    @State private var loading = false
    @State private var transcribing = false
    @State private var selecting = false
    @State private var selStart: Int?
    @State private var selEnd: Int?
    @State private var showClipSheet = false
    @State private var searching = false
    @State private var query = ""
    @State private var matchIndices: [Int] = []
    @State private var currentMatch = 0
    @FocusState private var searchFocused: Bool

    // UIKit-side equivalent of .scaledFont(16): @ScaledMetric honors Dynamic Type and the
    // app-wide cap, and the resulting UIFont feeds the attributed cue text.
    @ScaledMetric(relativeTo: .body) private var cueFontSize: CGFloat = 16

    // Plain-value snapshot of the cues, built ONCE per transcript. Rendering must never
    // touch (or re-sort) the SwiftData models per playback tick — that faulted thousands
    // of models twice a second and hung the main thread on device (watchdog kill).
    struct CueVM: Identifiable, Equatable {
        let id: Int
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        let speaker: String?
        let words: [WordTiming]?
    }
    @State private var cueVMs: [CueVM] = []
    @State private var timeRanges: [(start: TimeInterval, end: TimeInterval)] = []
    // Parallel to cueVMs: per-cue word start/end tuples, precomputed once so activeWordIndex
    // never allocates on a playback tick. Tuples aren't Equatable, so this lives outside CueVM
    // (same idiom as `timeRanges` above).
    @State private var wordRanges: [[(start: TimeInterval, end: TimeInterval)]] = []
    @State private var lastUserScrollAt: Date = .distantPast

    // Highlight only applies when THIS episode is the one loaded in the player.
    private var isCurrentEpisode: Bool { playback.currentEpisode?.guid == episode.guid }
    // Auto-scroll only while it's actually playing, and never while the user is reading around.
    private var isFollowing: Bool { isCurrentEpisode && playback.isPlaying }

    private var activeIndex: Int? {
        guard isCurrentEpisode else { return nil }
        return ActiveCue.index(at: playback.positionSeconds, cues: timeRanges)
    }

    // Collapses runs of whitespace/newlines to single spaces so word-token reconstruction can be
    // compared against the cue's plain text regardless of incidental spacing differences.
    private func normalizedWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func snapshotCues() {
        let sorted = (transcript?.cues ?? []).sorted { $0.startTime < $1.startTime }
        cueVMs = sorted.enumerated().map { i, c in
            // Word tokens come from SpeechAnalyzer runs; runs without audioTimeRange are dropped,
            // which can make the joined tokens diverge from the cue's plain text (missing words,
            // detached punctuation). Only use word-level rendering when it reconstructs the text —
            // otherwise fall back to whole-cue highlighting.
            var words = c.words
            if let w = words, !w.isEmpty {
                let reconstructed = normalizedWhitespace(w.map(\.text).joined(separator: " "))
                let expected = normalizedWhitespace(c.text)
                if reconstructed != expected { words = nil }
            }
            return CueVM(id: i, start: c.startTime, end: c.endTime, text: c.text, speaker: c.speaker, words: words)
        }
        timeRanges = cueVMs.map { ($0.start, $0.end) }
        wordRanges = cueVMs.map { vm in
            (vm.words ?? []).map { ($0.startTime, $0.endTime) }
        }
    }

    private func activeWordIndex(for cue: CueVM) -> Int? {
        guard let words = cue.words, !words.isEmpty else { return nil }
        guard cue.id >= 0, cue.id < wordRanges.count else {
            return ActiveCue.index(at: playback.positionSeconds, cues: words.map { ($0.startTime, $0.endTime) })
        }
        return ActiveCue.index(at: playback.positionSeconds, cues: wordRanges[cue.id])
    }

    var body: some View {
        NavigationStack {
            Group {
                if let t = transcript, !t.cues.isEmpty { transcriptList } else if loading || transcribing { progressState } else { emptyState }
            }
            .background(theme.color(.bg))
            .navigationTitle("Transcript")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) {
                if searching { searchBar }
            }
            .toolbar {
                if transcript != nil, !(transcript?.cues.isEmpty ?? true) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            if searching { closeSearch() } else {
                                searching = true
                                resetSelection()          // search and clip-select are exclusive
                                selecting = false
                                searchFocused = true
                            }
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .accessibilityLabel(searching ? "Close search" : "Search transcript")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(selecting ? "Done" : "Select") {
                            selecting.toggle(); selStart = nil; selEnd = nil
                            if selecting { closeSearch() }   // entering select mode closes search
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
                            .scaledFont(15, weight: .bold).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(theme.color(.accent)).brutalBorder(width: 2)
                    }
                    .buttonStyle(.plain).padding(16)
                    .background(theme.color(.bg))
                } else if selecting {
                    Text("Tap the first and last line to clip.")
                        .scaledFont(13, weight: .semibold).foregroundStyle(theme.color(.textSecondary))
                        .frame(maxWidth: .infinity).padding(.vertical, 14).padding(.horizontal, 16)
                        .background(theme.color(.bg))
                }
            }
            .sheet(isPresented: $showClipSheet, onDismiss: resetSelection, content: {
                if let r = selectionRange {
                    ClipReviewSheet(episode: episode,
                                    start: cueVMs[r.lowerBound].start,
                                    end: cueVMs[r.upperBound].end)
                }
            })
        }
        .task { await load() }
        // A jump surfaces the player; close this transcript sheet so the player is visible.
        .onChange(of: playback.transcriptJumpNonce) { _, _ in dismiss() }
    }

    // Cue text/speaker/timestamp on the left; the jump-to-player control sits off to the right so
    // it never competes with tapping lines to select a clip.
    @ViewBuilder private func cueRow(_ cue: CueVM) -> some View {
        let i = cue.id
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let s = cue.speaker {
                    Text(s).scaledFont(12, weight: .bold).textCase(.uppercase)
                        .foregroundStyle(theme.color(.accent))
                }
                Text(timeStr(cue.start)).scaledFont(11, weight: .medium).monospacedDigit()
                    .foregroundStyle(theme.color(.textTertiary))
                cueText(cue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            if !selecting {
                Button { playback.jumpFromTranscript(episode: episode, to: cue.start) } label: {
                    Image(systemName: "play.fill").scaledFont(13, weight: .bold)
                        .foregroundStyle(theme.color(.accent))
                        .frame(width: 40, height: 40)
                        .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play from \(timeStr(cue.start))")
            }
        }
        .padding(10)
        .background(
            (selecting && (selectionRange?.contains(i) ?? false))
                ? theme.color(.accentWash)
                : (i == currentMatchCue || (i == activeIndex && !selecting && !searching)
                    ? theme.color(.accentWash) : .clear))
        .contentShape(Rectangle())
        // Read mode: tapping anywhere on the line jumps to the player (the side button reinforces
        // it). Select mode: tapping picks the clip range instead.
        .onTapGesture {
            if selecting {
                handleSelectionTap(i)
            } else {
                playback.jumpFromTranscript(episode: episode, to: cue.start)
            }
        }
        .id(i)
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(cueVMs) { cue in cueRow(cue) }
                }.padding(20)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 10).onChanged { _ in lastUserScrollAt = .now }
            )
            .onChange(of: activeIndex) { _, new in
                guard let new, isFollowing, !searching,
                      Date.now.timeIntervalSince(lastUserScrollAt) > 4 else { return }
                withAnimation { proxy.scrollTo(new, anchor: .center) }
            }
            .onChange(of: query) { _, _ in recomputeMatches() }
            .onChange(of: currentMatchCue) { _, new in
                // Search-driven scrolls always fire — they bypass the auto-follow throttle.
                guard let new else { return }
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

// MARK: - Cue text, search & clip-selection helpers
extension TranscriptView {
    // Read mode gets natively-selectable text (long-press → Look Up / Search Web); clip Select
    // mode gets plain Text so the row's range-tap gesture has no competing recognizer.
    @ViewBuilder func cueText(_ cue: CueVM) -> some View {
        let i = cue.id
        if selecting {
            Text(cue.text)
                .scaledFont(16)
                .foregroundStyle(i == activeIndex ? theme.color(.text) : theme.color(.textTertiary))
        } else {
            SelectableCueText(
                attributed: CueTextStyler.attributed(
                    text: cue.text,
                    words: i == activeIndex ? cue.words : nil,
                    activeWordIndex: i == activeIndex ? activeWordIndex(for: cue) : nil,
                    searchQuery: searching ? query : "",
                    style: .init(font: .systemFont(ofSize: cueFontSize),
                                 base: UIColor(theme.color(i == activeIndex ? .text : .textTertiary)),
                                 emphasis: UIColor(theme.color(.text)),
                                 accent: UIColor(theme.color(.accent)))),
                onTap: { playback.jumpFromTranscript(episode: episode, to: cue.start) })
        }
    }

    // Top find bar: search field + match counter + prev/next chevrons.
    var searchBar: some View {
        HStack(spacing: 10) {
            BrutalSearchField("Find in transcript", text: $query, focus: $searchFocused)
            Text(matchCounterText)
                .scaledFont(13, weight: .semibold).monospacedDigit()
                .foregroundStyle(theme.color(.textSecondary))
                .fixedSize()
            matchChevron(system: "chevron.up", label: "Previous match", action: prevMatch)
            matchChevron(system: "chevron.down", label: "Next match", action: nextMatch)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(theme.color(.bg))
    }

    private func matchChevron(system: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).scaledFont(14, weight: .bold)
                .foregroundStyle(theme.color(matchIndices.isEmpty ? .textTertiary : .accent))
                .frame(width: 36, height: 36)
                .background(theme.color(.bgElevated)).brutalBorder(width: 2)
        }
        .buttonStyle(.plain).disabled(matchIndices.isEmpty)
        .accessibilityLabel(label)
    }

    var matchCounterText: String {
        matchIndices.isEmpty ? "0 / 0" : "\(currentMatch + 1) / \(matchIndices.count)"
    }

    func closeSearch() {
        searching = false; query = ""; matchIndices = []; currentMatch = 0
    }

    // Recomputed on query change. cueVMs is built once per transcript (snapshotCues) and is not
    // re-snapshotted while a populated transcript — and thus the search bar — is on screen, so
    // matchIndices can't go stale against a regenerated snapshot.
    func recomputeMatches() {
        matchIndices = TranscriptFind.matchingIndices(query: query, in: cueVMs.map(\.text))
        currentMatch = 0
    }

    func nextMatch() {
        guard !matchIndices.isEmpty else { return }
        currentMatch = (currentMatch + 1) % matchIndices.count
    }

    func prevMatch() {
        guard !matchIndices.isEmpty else { return }
        currentMatch = (currentMatch - 1 + matchIndices.count) % matchIndices.count
    }

    /// Cue index of the current match (nil when not searching / no matches).
    var currentMatchCue: Int? {
        guard searching, !matchIndices.isEmpty, currentMatch < matchIndices.count else { return nil }
        return matchIndices[currentMatch]
    }

    var selectionRange: ClosedRange<Int>? {
        guard let s = selStart else { return nil }
        let e = selEnd ?? s
        return min(s, e)...max(s, e)
    }

    func handleSelectionTap(_ i: Int) {
        if let s = selStart, selEnd == nil, i != s { selEnd = i } else { selStart = i; selEnd = nil }
    }

    func resetSelection() {
        selecting = false; selStart = nil; selEnd = nil
    }

    func timeStr(_ s: TimeInterval) -> String {
        let t = Int(max(0, s))
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Progress & empty states
extension TranscriptView {
    private var progressState: some View {
        VStack(spacing: 12) {
            ProgressView(value: transcripts.progress[episode.guid] ?? 0)
                .tint(theme.color(.accent)).frame(maxWidth: 220)
            Text(transcribing ? "Transcribing on device…" : "Loading transcript…")
                .foregroundStyle(theme.color(.textTertiary))
            if transcribing {
                // The transcription task keeps running after dismissal; the service posts an
                // app-wide toast (RootView) when it finishes.
                Button {
                    transcripts.notifyOnCompletion(of: episode)
                    dismiss()
                } label: {
                    Text("Continue in Background")
                        .scaledFont(14, weight: .bold).foregroundStyle(theme.color(.textSecondary))
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                }
                .buttonStyle(.plain).padding(.top, 8)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("No transcript available").foregroundStyle(theme.color(.textTertiary))
            if let failure = transcripts.lastFailure[episode.guid] {
                Text(failure)
                    .scaledFont(13).multilineTextAlignment(.center)
                    .foregroundStyle(.red).padding(.horizontal, 24)
            }
            if transcripts.canTranscribeOnDevice(episode) {
                Button("Transcribe episode") { Task { await transcribe() } }
                    .scaledFont(15, weight: .bold).foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(theme.color(.accent)).brutalBorder(width: 2)
            } else if transcripts.hasEngine {
                Text("Download this episode to transcribe it on device")
                    .scaledFont(13).foregroundStyle(theme.color(.textTertiary))
            } else {
                Text("On-device transcription requires iOS 26 or later")
                    .scaledFont(13).foregroundStyle(theme.color(.textTertiary))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
