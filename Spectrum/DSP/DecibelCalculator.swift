import Accelerate
import Foundation

/// Converts linear magnitude to dBFS.
///
/// `dB = 20 * log10(magnitude)`, with a floor so `log10(0)` is never evaluated.
enum DecibelCalculator {
    static func amplitudeToDB(_ magnitude: Float, minimumMagnitude: Float = 1.0e-12, floorDB: Float = -120) -> Float {
        let safe = max(magnitude, minimumMagnitude)
        let db = 20.0 * log10f(safe)
        return max(db, floorDB)
    }

    static func amplitudeToDB(
        _ magnitudes: [Float],
        minimumMagnitude: Float = 1.0e-12,
        floorDB: Float = -120
    ) -> [Float] {
        var output = magnitudes
        amplitudeToDB(magnitudes, result: &output, minimumMagnitude: minimumMagnitude, floorDB: floorDB)
        return output
    }

    static func amplitudeToDB(
        _ magnitudes: [Float],
        result: inout [Float],
        minimumMagnitude: Float = 1.0e-12,
        floorDB: Float = -120
    ) {
        let count = magnitudes.count
        guard count > 0 else {
            result = []
            return
        }
        if result.count != count {
            result = [Float](repeating: floorDB, count: count)
        }

        // Clamp to the minimum magnitude, convert to dB, then clamp to the display floor.
        var lower = minimumMagnitude
        vDSP_vthr(magnitudes, 1, &lower, &result, 1, vDSP_Length(count))
        var count32 = Int32(count)
        vvlog10f(&result, result, &count32)
        var twenty: Float = 20
        vDSP_vsmul(result, 1, &twenty, &result, 1, vDSP_Length(count))
        var floor = floorDB
        vDSP_vthr(result, 1, &floor, &result, 1, vDSP_Length(count))
    }
}
