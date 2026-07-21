//  TranscriptFollowProbeUITests.swift
//  Visual probe: transcript should highlight + scroll along with the seeded playing episode.
import XCTest

final class TranscriptFollowProbeUITests: XCTestCase {
    @MainActor
    func test_transcriptFollowsPlayback() {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_CLIP"] = "1"
        app.launch()

        app.staticTexts["UITest Show"].firstMatch.tap()
        let play = app.buttons["play-episode"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()

        // Open Now Playing via the mini player, then the transcript.
        sleep(1)
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'UITest Episode'")).firstMatch.tap()
        let transcriptButton = app.buttons["transcript-button"]
        XCTAssertTrue(transcriptButton.waitForExistence(timeout: 5))
        transcriptButton.tap()

        // Cue text renders via SelectableCueText (a UITextView-backed UIViewRepresentable, for
        // native Look Up/Search Web selection) — it surfaces through .value, not .label like a
        // plain SwiftUI Text, so the query must target textViews, not staticTexts.
        let firstCue = app.textViews.matching(
            NSPredicate(format: "value CONTAINS 'Hello world'")
        ).firstMatch
        XCTAssertTrue(firstCue.waitForExistence(timeout: 5), "transcript cues not shown")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(
            to: URL(fileURLWithPath: "/tmp/onda-follow-early.png")
        )
        sleep(6)   // playback advances ~2.5 cues
        try? XCUIScreen.main.screenshot().pngRepresentation.write(
            to: URL(fileURLWithPath: "/tmp/onda-follow-late.png")
        )
    }
}
