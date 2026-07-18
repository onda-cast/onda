//  AddArticleSheet.swift
import SwiftUI

struct AddArticleSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(ArticleConversionService.self) private var articles
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Paste a link and Onda reads the article aloud as an episode in your Articles show.")
                    .font(.system(size: 14)).foregroundStyle(theme.color(.textSecondary))
                TextField("https://…", text: $text)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.go).onSubmit { submit() }
                    .accessibilityIdentifier("add-article-url")
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(theme.color(.bgElevated)).brutalBorder(width: 2.5)
                if let error {
                    Text(error).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.color(.accent))
                }
                Button { submit() } label: {
                    Text("ADD ARTICLE")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(theme.color(.accent)).brutalBorder(width: 2)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(20)
            .background(theme.color(.bg))
            .navigationTitle("Add Article")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { focused = true }
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil else {
            error = "Enter a full link starting with http:// or https://"
            return
        }
        articles.add(url: url)
        dismiss()
    }
}
