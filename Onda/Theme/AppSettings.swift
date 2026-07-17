//  AppSettings.swift
import Foundation

@MainActor
@Observable
final class AppSettings {
    private static let keepTranscriptsKey = "keepTranscriptsOnDelete"
    private static let maxDownloadsKey = "defaultMaxDownloadsKept"
    private static let autoDeleteDaysKey = "defaultAutoDeleteListenedAfterDays"
    private static let autoTranscribeKey = "defaultAutoTranscribeOnDownload"

    private let defaults: UserDefaults

    // Default true: retaining searchable transcripts of deleted episodes is the point of Onda.
    var keepTranscriptsOnDelete: Bool {
        didSet { defaults.set(keepTranscriptsOnDelete, forKey: Self.keepTranscriptsKey) }
    }

    /// Per-show cap on TOTAL downloaded episodes. 0 = no limit (the default — no surprise
    /// deletions). The cap only ever evicts played episodes.
    var defaultMaxDownloadsKept: Int {
        didSet { defaults.set(defaultMaxDownloadsKept, forKey: Self.maxDownloadsKey) }
    }

    /// Auto-delete listened episodes after N days. -1 = off (default), 0 = immediately.
    var defaultAutoDeleteListenedAfterDays: Int {
        didSet { defaults.set(defaultAutoDeleteListenedAfterDays, forKey: Self.autoDeleteDaysKey) }
    }

    /// Auto-start on-device transcription when a download finishes (episodes without a
    /// published transcript, engine available, Speech authorization already granted).
    var defaultAutoTranscribeOnDownload: Bool {
        didSet { defaults.set(defaultAutoTranscribeOnDownload, forKey: Self.autoTranscribeKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keepTranscriptsOnDelete = defaults.object(forKey: Self.keepTranscriptsKey)
            .flatMap { $0 as? Bool } ?? true
        defaultMaxDownloadsKept = defaults.object(forKey: Self.maxDownloadsKey)
            .flatMap { $0 as? Int } ?? 0
        defaultAutoDeleteListenedAfterDays = defaults.object(forKey: Self.autoDeleteDaysKey)
            .flatMap { $0 as? Int } ?? -1
        defaultAutoTranscribeOnDownload = defaults.object(forKey: Self.autoTranscribeKey)
            .flatMap { $0 as? Bool } ?? false
    }
}
