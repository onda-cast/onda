//  ITunesSearchClientBox.swift
import Foundation

@MainActor
@Observable
final class ITunesSearchClientBox {
    let client: any Searching
    init(client: any Searching) { self.client = client }
}
