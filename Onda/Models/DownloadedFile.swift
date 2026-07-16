//  DownloadedFile.swift
import Foundation
import SwiftData

@Model
final class DownloadedFile {
    var localFileName: String     // filename only; resolved against Application Support at read time
    var fileSizeBytes: Int64
    var downloadedAt: Date
    var episode: Episode?

    init(localFileName: String, fileSizeBytes: Int64, downloadedAt: Date) {
        self.localFileName = localFileName
        self.fileSizeBytes = fileSizeBytes
        self.downloadedAt = downloadedAt
    }
}
