import XCTest
@testable import Spectrum

final class SpectrumSmootherTests: XCTestCase {
    func testAttackIsFasterThanRelease() {
        let smoother = SpectrumSmoother(barCount: 1, attack: 0.5, release: 0.1, floorDB: -120)
        _ = smoother.process(levelsDB: [-60], timestamp: 1_000_000_000, enableSmoothing: true, enablePeakHold: false)
        let rising = smoother.process(levelsDB: [0], timestamp: 1_016_000_000, enableSmoothing: true, enablePeakHold: false)
        let falling = smoother.process(levelsDB: [-60], timestamp: 1_032_000_000, enableSmoothing: true, enablePeakHold: false)

        let riseDelta = abs(rising.levels[0] - -60)
        let fallDelta = abs(falling.levels[0] - rising.levels[0])
        XCTAssertGreaterThan(riseDelta, fallDelta)
    }

    func testPeakHoldRemainsUntilDecay() {
        let smoother = SpectrumSmoother(
            barCount: 1,
            attack: 1,
            release: 1,
            peakHoldSeconds: 1.5,
            peakDecayDBPerSecond: 20,
            floorDB: -120
        )
        _ = smoother.process(levelsDB: [-6], timestamp: 1_000_000_000, enableSmoothing: true, enablePeakHold: true)
        let held = smoother.process(levelsDB: [-40], timestamp: 1_200_000_000, enableSmoothing: true, enablePeakHold: true)
        XCTAssertEqual(held.peaks[0], -6, accuracy: 0.2)

        let decayed = smoother.process(levelsDB: [-40], timestamp: 3_000_000_000, enableSmoothing: true, enablePeakHold: true)
        XCTAssertLessThan(decayed.peaks[0], -6)
        XCTAssertGreaterThanOrEqual(decayed.peaks[0], decayed.levels[0] - 0.1)
    }

    func testDisabledSmoothingPassesThrough() {
        let smoother = SpectrumSmoother(barCount: 2, attack: 0.01, release: 0.01, floorDB: -120)
        let result = smoother.process(
            levelsDB: [-12, -24],
            timestamp: 1,
            enableSmoothing: false,
            enablePeakHold: false
        )
        XCTAssertEqual(result.levels[0], -12, accuracy: 0.001)
        XCTAssertEqual(result.levels[1], -24, accuracy: 0.001)
    }
}
