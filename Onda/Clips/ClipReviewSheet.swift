//  ClipReviewSheet.swift
//  The single clip editor: loop-listen to the range, adjust start/end (nudge buttons,
//  type-a-timecode, set-to-playhead), and annotate. Replaces the old note-only ClipEditSheet.
//  Opening pauses the listener's episode and snapshots their spot; closing restores it
//  (PlaybackManager.beginClipPreview/endClipPreview).
import SwiftUI

struct ClipReviewSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(ClipService.self) private var clips
    @Environment(PlaybackManager.self) private var playback
    @Environment(\.dismiss) private var dismiss

    /// A clip can never be shorter than this; every edit clamps against it.
    static let minLength: TimeInterval = 1

    let episode: Episode?
    let existing: Clip?
    @State private var start: TimeInterval
    @State private var end: TimeInterval
    @State private var note: String
    @State private var previewing = false
    @State private var editingField: TimeField?
    @State private var typedTime = ""

    enum TimeField { case start, end }

    init(episode: Episode, start: TimeInterval, end: TimeInterval) {
        self.episode = episode; self.existing = nil
        _start = State(initialValue: start)
        _end = State(initialValue: end)
        _note = State(initialValue: "")
    }

    init(clip: Clip) {
        self.episode = clip.episode; self.existing = clip
        _start = State(initialValue: clip.startTime)
        _end = State(initialValue: clip.endTime)
        _note = State(initialValue: clip.note ?? "")
    }

    // End-of-capture clamps can push `end` past a mis-reported feed duration; never clamp below it.
    private var duration: TimeInterval { max(episode?.duration ?? 0, end) }

    private var excerpt: String {
        guard let episode else { return "" }
        let cues = (episode.transcript?.cues ?? []).sorted { $0.startTime < $1.startTime }
            .map { CueSpan(start: $0.startTime, end: $0.endTime, text: $0.text) }
        return ClipTextSnapshot.text(cues: cues, start: start, end: end)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    previewButton
                    timeRow(label: "Start", field: .start)
                    timeRow(label: "End", field: .end)
                    Text("Excerpt").brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
                    Text(excerpt.isEmpty ? "(no transcript for this range)" : excerpt)
                        .scaledFont(14.5).foregroundStyle(theme.color(.textSecondary))
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                    Text("Note").brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
                    TextField("Why does this matter?", text: $note, axis: .vertical)
                        .lineLimit(3...6).padding(12)
                        .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                }.padding(20)
            }
            .background(theme.color(.bg))
            .navigationTitle(existing == nil ? "New Clip" : "Edit Clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .alert("Set \(editingField == .end ? "End" : "Start") Time",
                   isPresented: Binding(get: { editingField != nil },
                                        set: { if !$0 { editingField = nil } })) {
                TextField("1:23:45", text: $typedTime)
                    .keyboardType(.numbersAndPunctuation)
                Button("Set") {
                    if let field = editingField, let t = NowPlayingView.parseTimecode(typedTime) {
                        setTime(field, to: t)
                    }
                    editingField = nil
                }
                Button("Cancel", role: .cancel) { editingField = nil }
            } message: {
                Text("Enter a time like 12:34, 1:02:30, or seconds.")
            }
        }
        // No pause on open: playback keeps going until Preview is actually tapped (the first
        // previewRange call snapshots the listener's spot); dismissal restores it if it was taken.
        .onDisappear { playback.endClipPreview() }
        // Editing an edge mid-preview restarts the loop with the new bounds, so what you hear
        // always matches the range on screen.
        .onChange(of: start) { _, _ in restartPreviewIfActive() }
        .onChange(of: end) { _, _ in restartPreviewIfActive() }
    }

    private func restartPreviewIfActive() {
        guard previewing, let episode else { return }
        playback.previewRange(episode: episode, start: start, end: end)
    }

    private var previewButton: some View {
        Button {
            if previewing {
                playback.stopPreviewPlayback()
            } else if let episode {
                playback.previewRange(episode: episode, start: start, end: end)
            }
            previewing.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: previewing ? "stop.fill" : "play.fill")
                    .scaledFont(15, weight: .bold)
                Text(previewing ? "Stop" : "Preview Clip (\(Int(end - start))s)")
                    .scaledFont(15, weight: .bold)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(theme.color(.accentStrong)).brutalBorder(width: 2)
        }
        .buttonStyle(.plain)
        .disabled(episode == nil)
        .accessibilityIdentifier("clip-preview-button")
    }

    private func timeRow(label: String, field: TimeField) -> some View {
        let value = field == .start ? start : end
        return HStack(spacing: 8) {
            Text(label).brutalHeader(size: 13)
                .foregroundStyle(theme.color(.textTertiary))
                .frame(width: 44, alignment: .leading)
            // Tappable timecode → type an exact time (same parser as the scrubber's jump alert).
            Button { typedTime = ""; editingField = field } label: {
                Text(timecode(value))
                    .scaledFont(15, weight: .bold).monospacedDigit()
                    .foregroundStyle(theme.color(.text))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(theme.color(.bgElevated)).brutalBorder(width: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(label) time \(timecode(value)), tap to type a time")
            Spacer(minLength: 0)
            nudgeButton("minus", field: field, tap: -1, longPress: -5)
            nudgeButton("plus", field: field, tap: 1, longPress: 5)
            // Snap this edge to wherever the preview playhead is right now.
            Button { setTime(field, to: playback.positionSeconds) } label: {
                Image(systemName: "arrow.down.to.line")
                    .scaledFont(15, weight: .bold).foregroundStyle(theme.color(.accent))
                    .frame(width: 40, height: 40)
                    .background(theme.color(.accentWash)).brutalBorder(width: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Set \(label.lowercased()) to playhead")
        }
    }

    // Tap ±1s; a still long-press ±5s (same simultaneous-gesture trick as the scrubber).
    private func nudgeButton(_ symbol: String, field: TimeField,
                             tap: TimeInterval, longPress: TimeInterval) -> some View {
        Button { adjust(field, by: tap) } label: {
            Image(systemName: symbol)
                .scaledFont(15, weight: .bold).foregroundStyle(theme.color(.text))
                .frame(width: 40, height: 40)
                .background(theme.color(.bgElevated)).brutalBorder(width: 2)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
            adjust(field, by: longPress)
        })
        .accessibilityLabel("\(tap > 0 ? "Later" : "Earlier") by \(Int(abs(tap))) second")
        .accessibilityHint("Long press for \(Int(abs(longPress))) seconds")
    }

    private func adjust(_ field: TimeField, by delta: TimeInterval) {
        setTime(field, to: (field == .start ? start : end) + delta)
    }

    /// Clamps every edit so `0 ≤ start ≤ end − minLength` and `start + minLength ≤ end ≤ duration`.
    /// A running preview keeps looping its old range; the new range takes effect next Preview tap.
    private func setTime(_ field: TimeField, to value: TimeInterval) {
        switch field {
        case .start: start = max(0, min(value, end - Self.minLength))
        case .end:   end = min(duration, max(value, start + Self.minLength))
        }
    }

    private func timecode(_ s: TimeInterval) -> String {
        let t = Int(max(0, s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }

    private func save() {
        let text = excerpt
        if let existing {
            clips.updateClip(existing, start: start, end: end, text: text,
                             note: note.isEmpty ? nil : note)
        } else if let episode {
            clips.makeClipExact(episode: episode, start: start, end: end, text: text,
                                note: note.isEmpty ? nil : note, needsReview: false)
        }
        dismiss()
    }
}
