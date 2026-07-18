//  PrivateFeedTokenStore.swift
import Foundation
import Security

/// Keychain-backed storage for the real (tokenized) URL of a private/paid feed, keyed by
/// `PrivateFeedIdentity.hash(for:)`. SwiftData never sees the real URL — see
/// docs/superpowers/specs/2026-07-18-private-feed-token-keychain-design.md.
protocol PrivateFeedTokenStoring: Sendable {
    func store(realURL: URL, hash: String) throws
    func realURL(forHash hash: String) throws -> URL?
    func delete(hash: String) throws
}

struct PrivateFeedTokenStoreError: Error {
    let status: OSStatus
}

final class PrivateFeedTokenStore: PrivateFeedTokenStoring {
    private let service: String

    init(service: String = "com.chasegilliam.onda.privateFeedTokens") {
        self.service = service
    }

    func store(realURL: URL, hash: String) throws {
        try? delete(hash: hash)   // overwrite semantics
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hash,
            kSecValueData as String: Data(realURL.absoluteString.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: true
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw PrivateFeedTokenStoreError(status: status) }
    }

    func realURL(forHash hash: String) throws -> URL? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hash,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let string = String(data: data, encoding: .utf8),
              let url = URL(string: string) else {
            throw PrivateFeedTokenStoreError(status: status)
        }
        return url
    }

    func delete(hash: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hash,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PrivateFeedTokenStoreError(status: status)
        }
    }
}
