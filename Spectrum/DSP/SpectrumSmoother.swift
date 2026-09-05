import Foundation

/// First-order envelope follower with independent attack and release.
///
/// When the new level is higher, `attack` is used (fast). When it falls, `release`
/// is used (slower) so the display stays readable without flickering.
final class SpectrumSmoother: @unchecked Sendable {
    var attack: Float
    var release: Float
    private var state: [Float]
    private var peakState: [Float]
    private var peakHoldRemaining: [Float]
    var peakHoldSeconds: Float
    var peakDecayDBPerSecond: Float
    private(set) var lastTimestamp: UInt64?

    init(
        barCount: Int,
        attack: Float = 0.65,
        release: Float = 0.32,
        peakHoldSeconds: Float = 1.0,
        peakDecayDBPerSecond: Float = 28,
        floorDB: Float = -120
    ) {
        self.attack = min(max(attack, 0.01), 1)
        self.release = min(max(release, 0.01), 1)
        self.peakHoldSeconds = peakHoldSeconds
        self.peakDecayDBPerSecond = peakDecayDBPerSecond
        self.state = [Float](repeating: floorDB, count: barCount)
        self.peakState = [Float](repeating: floorDB, count: barCount)
        self.peakHoldRemaining = [Float](repeating: 0, count: barCount)
    }

    func reset(barCount: Int, floorDB: Float) {
        state = [Float](repeating: floorDB, count: barCount)
        peakState = [Float](repeating: floorDB, count: barCount)
        peakHoldRemaining = [Float](repeating: 0, count: barCount)
        lastTimestamp = nil
    }

    func process(levelsDB: [Float], timestamp: UInt64, enableSmoothing: Bool, enablePeakHold: Bool) -> (levels: [Float], peaks: [Float]) {
        let count = levelsDB.count
        if state.count != count {
            reset(barCount: count, floorDB: levelsDB.first ?? -120)
        }

        let dt: Float
        if let last = lastTimestamp, timestamp > last {
            dt = max(Float(timestamp - last) / 1_000_000_000.0, 1.0 / 240.0)
        } else {
            dt = 1.0 / 60.0
        }
        lastTimestamp = timestamp

        if !enableSmoothing {
            state = levelsDB
        } else {
            for i in 0..<count {
                let incoming = levelsDB[i]
                let coeff = incoming > state[i] ? attack : release
                state[i] += (incoming - state[i]) * coeff
            }
        }

        if enablePeakHold {
            for i in 0..<count {
                if state[i] >= peakState[i] {
                    peakState[i] = state[i]
                    peakHoldRemaining[i] = peakHoldSeconds
                } else {
                    peakHoldRemaining[i] -= dt
                    if peakHoldRemaining[i] <= 0 {
                        peakState[i] -= peakDecayDBPerSecond * dt
                        peakState[i] = max(peakState[i], state[i])
                    }
                }
            }
        } else {
            peakState = state
        }

        return (state, peakState)
    }
}
