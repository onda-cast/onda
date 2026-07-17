//  AppSettings.swift
import Foundation

@MainActor
@Observable
final class AppSettings {
    private static let keepTranscriptsKey = "keepTranscriptsOnDelete"

    // Default true: retaining searchable transcripts of deleted episodes is the point of Onda.
    var keepTranscriptsOnDelete: Bool {
        didSet { UserDefaults.standard.set(keepTranscriptsOnDelete, forKey: Self.keepTranscriptsKey) }
    }

    init() {
        keepTranscriptsOnDelete = UserDefaults.standard.object(forKey: Self.keepTranscriptsKey)
            .flatMap { $0 as? Bool } ?? true
    }
}
