//  FeedFetching.swift
import Foundation

protocol Searching: Sendable {
    func search(term: String) async throws -> [PodcastDTO]
    func lookup(ids: [Int]) async throws -> [PodcastDTO]
    func topChartIds(limit: Int) async throws -> [Int]
}
