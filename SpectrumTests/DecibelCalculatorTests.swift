import XCTest
@testable import Spectrum

final class DecibelCalculatorTests: XCTestCase {
    func testFullScaleIsZero() {
        XCTAssertEqual(DecibelCalculator.amplitudeToDB(1.0, floorDB: -200), 0, accuracy: 0.0001)
    }

    func testHalfAmplitudeIsMinusSix() {
        XCTAssertEqual(DecibelCalculator.amplitudeToDB(0.5, floorDB: -200), -6.0206, accuracy: 0.01)
    }

    func testZeroUsesFloor() {
        XCTAssertEqual(DecibelCalculator.amplitudeToDB(0, minimumMagnitude: 1e-12, floorDB: -120), -120, accuracy: 0.001)
    }

    func testVectorPathMatchesScalar() {
        let values: [Float] = [1, 0.5, 0.1, 0]
        let vector = DecibelCalculator.amplitudeToDB(values, minimumMagnitude: 1e-12, floorDB: -120)
        for (value, db) in zip(values, vector) {
            XCTAssertEqual(db, DecibelCalculator.amplitudeToDB(value, floorDB: -120), accuracy: 0.01)
        }
    }
}
