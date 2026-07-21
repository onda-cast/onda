//  ClipExporter.swift
import Foundation
import AVFoundation

enum ClipExportError: Error { case noEpisode, exportFailed }

@MainActor
struct ClipExporter {
    /// Resolves the best audio source for an episode: local file when downloaded, else stream URL.
    let sourceURL: (Episode) -> URL?

    static func shareText(for clip: Clip) -> String {
        var excerpt = clip.text
        if excerpt.count > 300 {
            excerpt = String(excerpt.prefix(300)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
        }
        let t = Int(max(0, clip.startTime))
        let stamp = String(format: "%d:%02d", t / 60, t % 60)
        let episode = clip.episode?.title ?? "Unknown episode"
        let show = clip.episode?.podcast?.title ?? "Unknown show"
        let attribution = "\u{2014} \(episode), \(show) @ \(stamp)"
        return excerpt.isEmpty ? attribution : "\u{201C}\(excerpt)\u{201D}\n\(attribution)"
    }

    func export(clip: Clip) async throws -> URL {
        guard let episode = clip.episode, let src = sourceURL(episode) else {
            throw ClipExportError.noEpisode
        }
        let asset = AVURLAsset(url: src)
        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetAppleM4A) else {
            throw ClipExportError.exportFailed
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OndaClips")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeTitle = (episode.title.prefix(40))
            .replacingOccurrences(of: "[^A-Za-z0-9 ]", with: "", options: .regularExpression)
            .replacingOccurrences(of: " ", with: "-")
        let out = dir.appendingPathComponent("\(safeTitle)-\(Int(clip.startTime)).m4a")
        try? FileManager.default.removeItem(at: out)

        let range = CMTimeRange(
            start: CMTime(seconds: clip.startTime, preferredTimescale: 600),
            end: CMTime(seconds: clip.endTime, preferredTimescale: 600)
        )
        session.timeRange = range

        if #available(iOS 18, *) {
            try await session.export(to: out, as: .m4a)
        } else {
            session.outputURL = out
            session.outputFileType = .m4a
            await session.export()
            guard session.status == .completed else { throw ClipExportError.exportFailed }
        }
        return out
    }
}
