//  BookCandidate.swift
//  An UNVERIFIED book reference from any extraction tier. Candidates only ever become
//  visible after the OpenLibrary verification gate (BookVerifier).
import Foundation

struct BookCandidate: Equatable, Sendable {
    var title: String?
    var author: String?
    var isbnOrASIN: String?
    var timestamp: TimeInterval?
    var sourceTier: String   // "link" | "notes" | "transcript"
}
