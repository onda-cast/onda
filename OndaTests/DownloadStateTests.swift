//  DownloadStateTests.swift
import XCTest
@testable import Onda

@MainActor
final class DownloadStateTests: XCTestCase {
    func test_progressEquality() {
        XCTAssertEqual(DownloadState.downloading(progress: 0.5), .downloading(progress: 0.5))
        XCTAssertNotEqual(DownloadState.downloading(progress: 0.5), .downloading(progress: 0.6))
        XCTAssertNotEqual(DownloadState.none, .downloaded)
    }
}
