//  AddByURLSheet.swift
//  The single "add content by link" entry point, reachable identically from Library and
//  Discover. Paste any URL: an RSS feed (typically a private/paid membership link) previews and
//  subscribes as a show; anything else is offered as an article-to-audio conversion. Detection is
//  one fetch — if the URL parses as a feed it's a podcast, otherwise the article path is offered
//  (with the feed error shown, so a typo'd feed URL isn't silently converted as an article).
import SwiftUI

struct AddByURLSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(SubscriptionService.self) private var subscriptions
    @Environment(ArticleConversionService.self) private var articles
    @Environment(\.dismiss) private var dismiss

    private enum Detection {
        case feed(ParsedFeed)
        case article
    }

    @State private var urlText = ""
    @State private var detection: Detection?
    @State private var checkedURL: URL?
    @State private var loading = false
    @State private var errorText: String?
    @FocusState private var fieldFocused: Bool

    private var enteredURL: URL? {
        let t = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: t), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil else { return nil }
        return url
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add by Link").brutalHeader(size: 24).foregroundStyle(theme.color(.text))
                Text("""
                Paste any link. A podcast RSS feed (including private/paid memberships) becomes \
                a show; a web article is read aloud as an episode in your Articles show. Links \
                stay on this device.
                """)
                    .scaledFont(13).foregroundStyle(theme.color(.textTertiary))

                urlField
                pasteButton

                if loading {
                    HStack(spacing: 8) {
                        ProgressView().tint(theme.color(.accent))
                        Text("Checking link…").scaledFont(13)
                            .foregroundStyle(theme.color(.textTertiary))
                    }.frame(maxWidth: .infinity).padding(.top, 8)
                } else {
                    switch detection {
                    case .feed(let feed): feedCard(feed)
                    case .article: articleCard
                    case nil: checkButton
                    }
                }

                if let errorText {
                    Text(errorText).scaledFont(13).foregroundStyle(theme.color(.accent))
                }
            }
            .padding(20)
        }
        .background(theme.color(.bg))
        .onAppear { fieldFocused = true }
    }

    // MARK: Input

    private var urlField: some View {
        HStack(spacing: 8) {
            Image(systemName: "link").foregroundStyle(theme.color(.textTertiary))
            TextField("https://…", text: $urlText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .focused($fieldFocused)
                .onSubmit { Task { await check() } }
                .accessibilityLabel("Link URL")
                .accessibilityIdentifier("add-by-url-field")
        }
        .padding(.horizontal, 14).frame(height: 48)
        .background(theme.color(.bgElevated)).brutalBorder(width: 2.5)
        .onChange(of: urlText) { _, _ in detection = nil; errorText = nil }
    }

    @ViewBuilder private var pasteButton: some View {
        if UIPasteboard.general.hasURLs && detection == nil {
            Button {
                if let pasted = UIPasteboard.general.url {
                    urlText = pasted.absoluteString
                    Task { await check() }
                }
            } label: {
                Label("Paste Link", systemImage: "doc.on.clipboard")
                    .scaledFont(13, weight: .bold)
                    .foregroundStyle(theme.color(.textSecondary))
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(theme.color(.bgElevated)).brutalBorder(width: 2)
            }.buttonStyle(.plain)
        }
    }

    private var checkButton: some View {
        Button { Task { await check() } } label: {
            Text("Check Link").scaledFont(14, weight: .bold).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(enteredURL == nil ? theme.color(.textTertiary) : theme.color(.accent))
                .brutalBorder(width: 2.5)
        }
        .buttonStyle(.plain)
        .disabled(enteredURL == nil)
        .accessibilityLabel("Check link")
    }

    // MARK: Results

    private func feedCard(_ feed: ParsedFeed) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PODCAST FEED").brutalHeader(size: 11).foregroundStyle(theme.color(.accent))
            HStack(spacing: 12) {
                ArtworkView(url: feed.artworkURL, seed: feed.title)
                    .frame(width: 72, height: 72).hardShadow(offset: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(feed.title).brutalHeader(size: 15).foregroundStyle(theme.color(.text))
                        .lineLimit(2)
                    Text(feed.author).scaledFont(12.5)
                        .foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
                    Text("\(feed.episodes.count) episodes · \(feed.category)")
                        .scaledFont(12).foregroundStyle(theme.color(.textTertiary))
                }
                Spacer(minLength: 0)
            }
            Button { Task { await subscribe() } } label: {
                Text("Subscribe").scaledFont(14, weight: .bold).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(theme.color(.accentStrong)).brutalBorder(width: 2.5)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Subscribe to \(feed.title)")
        }
        .padding(14)
        .background(theme.color(.bgElevated)).brutalBorder(width: 2.5)
    }

    private var articleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WEB ARTICLE").brutalHeader(size: 11).foregroundStyle(theme.color(.accent))
            Text("This isn't a podcast feed. Onda can read the page aloud as an episode in your Articles show.")
                .scaledFont(13).foregroundStyle(theme.color(.textSecondary))
            Button { addArticle() } label: {
                Text("Add as Article").scaledFont(14, weight: .bold).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(theme.color(.accentStrong)).brutalBorder(width: 2.5)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("add-as-article")
        }
        .padding(14)
        .background(theme.color(.bgElevated)).brutalBorder(width: 2.5)
    }

    // MARK: Actions

    private func check() async {
        guard let url = enteredURL else { return }
        loading = true; errorText = nil; defer { loading = false }
        do {
            let feed = try await subscriptions.previewFeed(url)
            detection = .feed(feed)
        } catch {
            // Didn't parse as a feed. Sniff the raw response so a BROKEN feed (XML content that
            // failed to parse — expired token, malformed feed) shows a feed error instead of
            // being silently offered as an article; only genuine web pages get the article path.
            await sniffNonFeed(url)
        }
        checkedURL = url
        fieldFocused = false
    }

    private func sniffNonFeed(_ url: URL) async {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
            let prefix = String(bytes: data.prefix(512), encoding: .utf8) ?? ""
            switch Self.classifyNonFeed(contentType: contentType, bodyPrefix: prefix) {
            case .webPage:
                detection = .article
            case .brokenFeed:
                detection = nil
                errorText = "This looks like a podcast feed, but it couldn't be read — check the URL and that your membership is still active."
            }
        } catch {
            detection = nil
            errorText = "Couldn't reach this link — check the address and your connection."
        }
    }

    enum NonFeedKind { case brokenFeed, webPage }

    /// Pure classifier for a URL that failed feed parsing: XML-ish content type or an XML/RSS/Atom
    /// body prefix means "broken feed"; everything else (HTML and friends) is a web page.
    static func classifyNonFeed(contentType: String?, bodyPrefix: String) -> NonFeedKind {
        let ct = (contentType ?? "").lowercased()
        if ct.contains("html") { return .webPage }   // incl. application/xhtml+xml
        if ct.contains("rss") || ct.contains("atom") || ct.contains("xml") { return .brokenFeed }
        let head = bodyPrefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if head.hasPrefix("<?xml") || head.hasPrefix("<rss") || head.hasPrefix("<feed") { return .brokenFeed }
        return .webPage
    }

    private func subscribe() async {
        guard let url = checkedURL else { return }
        loading = true; errorText = nil; defer { loading = false }
        do {
            _ = try await subscriptions.subscribeToFeedURL(url)
            dismiss()
        } catch {
            errorText = "Couldn't subscribe — check that the URL is correct and your membership is active."
        }
    }

    private func addArticle() {
        guard let url = checkedURL else { return }
        articles.add(url: url)
        dismiss()
    }
}
