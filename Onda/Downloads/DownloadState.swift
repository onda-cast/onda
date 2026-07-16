//  DownloadState.swift
import Foundation

enum DownloadState: Equatable, Sendable {
    case none
    case downloading(progress: Double)
    case downloaded
    case failed
}
