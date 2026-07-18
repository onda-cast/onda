//  ArticleSource.swift
import Foundation
import SwiftData

/// Where a TTS-converted article episode came from. 1:1 with Episode, same shape
/// as DownloadedFile/Transcript.
@Model
final class ArticleSource {
    var sourceURL: URL
    var siteName: String?
    var addedAt: Date
    var episode: Episode?

    init(sourceURL: URL, siteName: String?, addedAt: Date) {
        self.sourceURL = sourceURL
        self.siteName = siteName
        self.addedAt = addedAt
    }
}
