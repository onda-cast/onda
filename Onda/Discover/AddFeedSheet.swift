//  AddFeedSheet.swift
//  Add a show by pasting its (typically private/paid, tokenized) RSS feed URL.
import SwiftUI

struct AddFeedSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(SubscriptionService.self) private var subscriptions
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var preview: ParsedFeed?
    @State private var previewURL: URL?
    @State private var loading = false
    @State private var errorText: String?
    @FocusState private var fieldFocused: Bool

    private var enteredURL: URL? {
        let t = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: t), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add by URL").brutalHeader(size: 24).foregroundStyle(theme.color(.text))
                Text("Paste the RSS link from your paid membership (Patreon, Supercast, and similar). Private links stay on this device.")
                    .font(.system(size: 13)).foregroundStyle(theme.color(.textTertiary))

                urlField
                if UIPasteboard.general.hasURLs && preview == nil {
                    Button {
                        if let pasted = UIPasteboard.general.url {
                            urlText = pasted.absoluteString
                            Task { await fetchPreview() }
                        }
                    } label: {
                        Label("Paste Link", systemImage: "doc.on.clipboard")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(theme.color(.textSecondary))
                            .padding(.horizontal, 14).frame(height: 44)
                            .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                    }.buttonStyle(.plain)
                }

                if let errorText {
                    Text(errorText).font(.system(size: 13))
                        .foregroundStyle(theme.color(.accent))
                }

                if loading {
                    HStack(spacing: 8) {
                        ProgressView().tint(theme.color(.accent))
                        Text("Loading feed…").font(.system(size: 13))
                            .foregroundStyle(theme.color(.textTertiary))
                    }.frame(maxWidth: .infinity).padding(.top, 8)
                } else if let preview {
                    previewCard(preview)
                } else {
                    fetchButton
                }
            }
            .padding(20)
        }
        .background(theme.color(.bg))
        .onAppear { fieldFocused = true }
    }

    private var urlField: some View {
        HStack(spacing: 8) {
            Image(systemName: "link").foregroundStyle(theme.color(.textTertiary))
            TextField("https://…", text: $urlText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .focused($fieldFocused)
                .onSubmit { Task { await fetchPreview() } }
                .accessibilityLabel("Feed URL")
        }
        .padding(.horizontal, 14).frame(height: 48)
        .background(theme.color(.bgElevated)).brutalBorder(width: 2.5)
        .onChange(of: urlText) { _, _ in preview = nil; errorText = nil }
    }

    private var fetchButton: some View {
        Button { Task { await fetchPreview() } } label: {
            Text("Fetch Feed").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(enteredURL == nil ? theme.color(.textTertiary) : theme.color(.accent))
                .brutalBorder(width: 2.5)
        }
        .buttonStyle(.plain)
        .disabled(enteredURL == nil)
        .accessibilityLabel("Fetch feed")
    }

    private func previewCard(_ feed: ParsedFeed) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ArtworkView(url: feed.artworkURL, seed: feed.title)
                    .frame(width: 72, height: 72).hardShadow(offset: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(feed.title).brutalHeader(size: 15).foregroundStyle(theme.color(.text))
                        .lineLimit(2)
                    Text(feed.author).font(.system(size: 12.5))
                        .foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
                    Text("\(feed.episodes.count) episodes · \(feed.category)")
                        .font(.system(size: 12)).foregroundStyle(theme.color(.textTertiary))
                }
                Spacer(minLength: 0)
            }
            Button { Task { await subscribe() } } label: {
                Text("Subscribe").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(theme.color(.accent)).brutalBorder(width: 2.5)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Subscribe to \(feed.title)")
        }
        .padding(14)
        .background(theme.color(.bgElevated)).brutalBorder(width: 2.5)
    }

    private func fetchPreview() async {
        guard let url = enteredURL else { return }
        loading = true; errorText = nil; defer { loading = false }
        do {
            preview = try await subscriptions.previewFeed(url)
            previewURL = url
            fieldFocused = false
        } catch {
            preview = nil
            errorText = "Couldn't load this feed — check that the URL is correct and your membership is active."
        }
    }

    private func subscribe() async {
        guard let url = previewURL else { return }
        loading = true; errorText = nil; defer { loading = false }
        do {
            _ = try await subscriptions.subscribeToFeedURL(url)
            dismiss()
        } catch {
            errorText = "Couldn't subscribe — check your connection and try again."
        }
    }
}
