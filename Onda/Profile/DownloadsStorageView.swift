//  DownloadsStorageView.swift
import SwiftUI
import SwiftData

struct DownloadsStorageView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(DownloadManager.self) private var downloads
    @Query private var episodes: [Episode]

    private var downloaded: [Episode] { episodes.filter { $0.downloadedFile != nil } }
    private var totalBytes: Int64 { downloaded.reduce(0) { $0 + ($1.downloadedFile?.fileSizeBytes ?? 0) } }
    private var totalStr: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Storage used").foregroundStyle(theme.color(.text))
                    Spacer()
                    Text(totalStr).foregroundStyle(theme.color(.textTertiary)).monospacedDigit()
                }
            }
            Section("Downloaded") {
                if downloaded.isEmpty {
                    Text("No downloads").foregroundStyle(theme.color(.textTertiary))
                } else {
                    ForEach(downloaded, id: \.guid) { ep in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ep.title).font(.system(size: 15, weight: .semibold))
                            Text(ep.podcast?.title ?? "").font(.system(size: 12.5))
                                .foregroundStyle(theme.color(.textTertiary))
                        }
                    }
                    .onDelete { idx in idx.map { downloaded[$0] }.forEach { downloads.delete($0) } }
                }
            }
        }
        .navigationTitle("Downloads & Storage")
    }
}
