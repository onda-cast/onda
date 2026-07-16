//  ParsedCue.swift
import Foundation

struct ParsedCue: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let speaker: String?
}
