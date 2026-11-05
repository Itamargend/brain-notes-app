import XCTest
@testable import BrainNotes

/// Pure rules for the black-hole delete: intensity and undo payload. No UI timing.
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
        // Intensity API is count-based; UI never starts a delete with zero paths.
        XCTAssertEqual(BlackHoleDeleteLogic.intensity(forPathCount: 0), .light)
    }

    func testLightIsShorterThanFull() {
        let light = BlackHoleIntensity.light.durationSeconds(reduceMotion: false)
        let full = BlackHoleIntensity.full.durationSeconds(reduceMotion: false)
        XCTAssertLessThan(light, full)
        XCTAssertEqual(light, 0.50, accuracy: 0.001)
        XCTAssertEqual(full, 0.90, accuracy: 0.001)
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

    func testFullHasMoreParticlesAndTurnsThanLight() {
        XCTAssertGreaterThan(BlackHoleIntensity.full.particleCount, BlackHoleIntensity.light.particleCount)
        XCTAssertGreaterThan(BlackHoleIntensity.full.swirlTurns, BlackHoleIntensity.light.swirlTurns)
    }
}
