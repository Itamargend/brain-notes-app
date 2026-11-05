import XCTest
@testable import BrainNotes

/// Pure rules for the black-hole delete: intensity, timeline, undo payload. No GPU.
final class BlackHoleDeleteTests: XCTestCase {
    func testOnePathUsesLightIntensity() {
        XCTAssertEqual(BlackHoleDeleteLogic.intensity(forPathCount: 1), .light)
        XCTAssertEqual(BlackHoleIntensity.forPathCount(1), .light)
    }

    func testTwoOrMorePathsUseFullIntensity() {
        XCTAssertEqual(BlackHoleDeleteLogic.intensity(forPathCount: 2), .full)
        XCTAssertEqual(BlackHoleDeleteLogic.intensity(forPathCount: 5), .full)
        XCTAssertEqual(BlackHoleIntensity.forPathCount(2), .full)
    }

    func testZeroPathsStillLight() {
        XCTAssertEqual(BlackHoleDeleteLogic.intensity(forPathCount: 0), .light)
    }

    func testLightIsShorterThanFull() {
        let light = BlackHoleIntensity.light.durationSeconds(reduceMotion: false)
        let full = BlackHoleIntensity.full.durationSeconds(reduceMotion: false)
        XCTAssertLessThan(light, full)
        XCTAssertEqual(light, 0.50, accuracy: 0.002)
        XCTAssertEqual(full, 0.90, accuracy: 0.002)
    }

    func testReduceMotionIsShortAndIgnoresIntensityLength() {
        let light = BlackHoleIntensity.light.durationSeconds(reduceMotion: true)
        let full = BlackHoleIntensity.full.durationSeconds(reduceMotion: true)
        XCTAssertEqual(light, full, accuracy: 0.001)
        XCTAssertLessThan(light, BlackHoleIntensity.light.durationSeconds(reduceMotion: false))
    }

    func testUndoSnapshotsRoundTripPathsAndTexts() {
        let snaps = BlackHoleDeleteLogic.snapshots(
            paths: ["Ideas/a.md", "Ideas/b.md"],
            texts: ["# A\n", ""]
        )
        XCTAssertEqual(snaps.count, 2)
        XCTAssertEqual(snaps[0].path, "Ideas/a.md")
        XCTAssertEqual(snaps[0].text, "# A\n")
        XCTAssertEqual(snaps[1].path, "Ideas/b.md")
        XCTAssertEqual(snaps[1].text, "")
    }

    func testUndoWindowIsFiveSeconds() {
        XCTAssertEqual(BlackHoleDeleteLogic.undoSeconds, 5, accuracy: 0.001)
    }

    func testFullHasMoreCardsThanLight() {
        XCTAssertGreaterThan(BlackHoleIntensity.full.cardCount, BlackHoleIntensity.light.cardCount)
    }

    func testTimelineOpensThenSwallowsThenCloses() {
        let config = BlackHoleRunConfig.forIntensity(.full)
        let early = BlackHoleTimeline.state(at: config.emergeDuration * 0.5, config: config)
        XCTAssertGreaterThan(early.presence, 0.2)
        XCTAssertLessThan(early.swallow, 0.5)

        let mid = BlackHoleTimeline.state(at: config.emergeDuration + config.swallowDuration * 0.5, config: config)
        XCTAssertGreaterThan(mid.swallow, 0.2)
        XCTAssertGreaterThan(mid.presence, 0.5)

        let end = BlackHoleTimeline.state(at: config.totalDuration + 0.01, config: config)
        XCTAssertTrue(end.finished)
        XCTAssertEqual(end.presence, 0, accuracy: 0.001)
    }

    func testHoleCenterUsesIslandWhenInsetLooksLikePhoneIsland() {
        let size = CGSize(width: 390, height: 844)
        let island = BlackHoleTimeline.holeCenter(in: size, safeTop: 59, prefersIsland: true)
        XCTAssertEqual(island.x, 195, accuracy: 0.1)
        XCTAssertGreaterThan(island.y, 0)

        let above = BlackHoleTimeline.holeCenter(in: size, safeTop: 0, prefersIsland: false)
        XCTAssertLessThan(above.y, 0)
    }

    func testRunConfigTotalsMatchIntensityDurations() {
        XCTAssertEqual(
            BlackHoleRunConfig.forIntensity(.light).totalDuration,
            BlackHoleIntensity.light.durationSeconds(reduceMotion: false),
            accuracy: 0.0001
        )
        XCTAssertEqual(
            BlackHoleRunConfig.forIntensity(.full).totalDuration,
            BlackHoleIntensity.full.durationSeconds(reduceMotion: false),
            accuracy: 0.0001
        )
    }
}
