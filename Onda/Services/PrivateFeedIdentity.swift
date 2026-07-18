//  PrivateFeedIdentity.swift
import Foundation
import CryptoKit

/// Derives a non-secret identity for a private/paid feed's real (tokenized) URL, and the
/// placeholder URL that stands in for it in SwiftData. See
/// docs/superpowers/specs/2026-07-18-private-feed-token-keychain-design.md.
enum PrivateFeedIdentity {
    static let placeholderScheme = "onda-private-feed"

    static func hash(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func placeholderURL(forHash hash: String) -> URL {
        URL(string: "\(placeholderScheme)://\(hash)")!
    }

    static func isPlaceholder(_ url: URL) -> Bool {
        url.scheme == placeholderScheme
    }
}
