//  ClipEditSheet.swift
import SwiftUI

struct ClipEditSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(ClipService.self) private var clips
    @Environment(\.dismiss) private var dismiss

    let episode: Episode?
    let requestedStart: TimeInterval
    let requestedEnd: TimeInterval
    let existing: Clip?
    @State private var note: String

    init(episode: Episode, requestedStart: TimeInterval, requestedEnd: TimeInterval) {
        self.episode = episode; self.requestedStart = requestedStart
        self.requestedEnd = requestedEnd; self.existing = nil
        _note = State(initialValue: "")
    }
    init(clip: Clip) {
        self.episode = clip.episode; self.requestedStart = clip.startTime
        self.requestedEnd = clip.endTime; self.existing = clip
        _note = State(initialValue: clip.note ?? "")
    }

    private var previewText: String {
        if let existing { return existing.text }
        guard let episode else { return "" }
        let cues = (episode.transcript?.cues ?? []).sorted { $0.startTime < $1.startTime }
            .map { CueSpan(start: $0.startTime, end: $0.endTime, text: $0.text) }
        return ClipTextSnapshot.snap(cues: cues, requestedStart: requestedStart,
                                     requestedEnd: requestedEnd).text
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Excerpt").brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
                    Text(previewText.isEmpty ? "(no transcript for this range)" : previewText)
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
        }
    }

    private func save() {
        if let existing {
            clips.updateNote(existing, note: note.isEmpty ? nil : note)
        } else if let episode {
            clips.makeClip(episode: episode, requestedStart: requestedStart,
                           requestedEnd: requestedEnd,
                           note: note.isEmpty ? nil : note, needsReview: false)
        }
        dismiss()
    }
}
