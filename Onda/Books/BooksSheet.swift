//  BooksSheet.swift
//  "What was that book in THIS episode?" — presented from the player for the current episode.
//  Strictly per-episode: the Find action runs the funnel for this one episode only.
import SwiftUI

struct BooksSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(BookMentionService.self) private var books
    @Environment(PlaybackManager.self) private var playback
    @Environment(\.dismiss) private var dismiss
    let episode: Episode

    @State private var readingTranscriptSearch: String?

    private var isPrivate: Bool {
        episode.podcast?.isPrivateFeed == true
    }

    private var running: Bool {
        books.inFlightGuid == episode.guid
    }

    private var mentions: [BookMention] {
        episode.bookMentions.sorted { ($0.timestamp ?? .infinity) < ($1.timestamp ?? .infinity) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isPrivate {
                        BrutalEmptyState("Not available for private shows",
                                         detail: "Verifying books needs a catalog lookup, and private shows' content never leaves this device.")
                    } else if running {
                        HStack(spacing: 8) {
                            ProgressView().tint(theme.color(.accent))
                            Text("Finding books\u{2026}").scaledFont(13)
                                .foregroundStyle(theme.color(.textTertiary))
                        }.frame(maxWidth: .infinity).padding(.top, 40)
                    } else if mentions.isEmpty {
                        BrutalEmptyState(books.lastFailure == nil
                            ? "Find the books mentioned in this episode"
                            : "No books found",
                            detail: books.lastFailure
                                ?? "Scans this episode's show notes and transcript; only books verified against a real catalog are shown.")
                        findButton
                    } else {
                        ForEach(mentions) { bookRow($0) }
                        findButton   // re-run replaces results
                    }
                }
                .padding(20)
            }
            .background(theme.color(.bg))
            .navigationTitle("Books Mentioned")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $readingTranscriptSearch) { search in
                TranscriptView(episode: episode, initialSearch: search)
            }
        }
    }

    private var findButton: some View {
        Button {
            Task { await books.findBooks(for: episode) }
        } label: {
            Text(mentions.isEmpty ? "Find Books" : "Find Again")
                .scaledFont(14, weight: .bold).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(theme.color(.accentStrong)).brutalBorder(width: 2.5)
        }
        .buttonStyle(.plain)
        .disabled(isPrivate || running)
        .accessibilityLabel("Find books mentioned in this episode")
    }

    private func bookRow(_ book: BookMention) -> some View {
        Button {
            if let t = book.timestamp {
                dismiss()
                playback.jumpFromTranscript(episode: episode, to: t)
            } else {
                readingTranscriptSearch = book.title
            }
        } label: {
            HStack(spacing: 12) {
                ArtworkView(url: book.coverURL, seed: book.title)
                    .frame(width: 44, height: 60).brutalBorder(width: 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title).scaledFont(15, weight: .bold)
                        .foregroundStyle(theme.color(.text)).lineLimit(2)
                    if let author = book.author {
                        Text(author).scaledFont(12.5)
                            .foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
                    }
                    if let t = book.timestamp {
                        Text("Mentioned at \(timeStr(t))").scaledFont(11.5, weight: .semibold)
                            .foregroundStyle(theme.color(.accent))
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: book.timestamp != nil ? "play.circle" : "text.magnifyingglass")
                    .scaledFont(16).foregroundStyle(theme.color(.textTertiary))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.color(.bgElevated)).brutalBorder(width: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(book.timestamp != nil
            ? "\(book.title): jump to where it was mentioned"
            : "\(book.title): search the transcript for it")
        .contextMenu {
            Button { UIPasteboard.general.string = [book.title, book.author].compactMap(\.self).joined(separator: " — ") } label: {
                Label("Copy Title & Author", systemImage: "doc.on.doc")
            }
            if let url = URL(string: "https://openlibrary.org\(book.workKey)") {
                Link(destination: url) { Label("Open in OpenLibrary", systemImage: "safari") }
            }
        }
    }

    private func timeStr(_ s: TimeInterval) -> String {
        let t = Int(max(0, s)); return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// .sheet(item:) needs Identifiable — a search string is its own identity here.
extension String: @retroactive Identifiable {
    public var id: String {
        self
    }
}
