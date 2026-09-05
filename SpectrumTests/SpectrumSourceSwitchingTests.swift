import XCTest
@testable import Spectrum

/// Regression: switching away from the 1 kHz test signal used to leave its
/// generator writing into the same ring buffer as the new capture.
final class SpectrumSourceSwitchingTests: XCTestCase {
    func testSwitchingTestSignalStopsThePreviousTone() async throws {
        var configuration = SpectrumConfiguration()
        configuration.smoothingEnabled = false
        configuration.peakHoldEnabled = false
        configuration.fftSize = 8_192
        configuration.barCount = 128

        let engine = AudioEngineManager(configuration: configuration)
        let probe = SpectrumLevelProbe()
        engine.setSpectrumHandler { probe.append($0) }
        defer { engine.stop() }

        try await engine.start(source: .testSignal(.sine1k))
        let saw1k = await waitUntil(timeout: 2.0) {
            probe.dominantFrequency(near: 1_000, window: 350) != nil
        }
        XCTAssertTrue(saw1k, "1 kHz test signal never appeared on the spectrum.")
        XCTAssertTrue(engine.isTestSignalRunning)

        try await engine.start(source: .testSignal(.sine100))
        XCTAssertTrue(engine.isTestSignalRunning)

        let movedTo100 = await waitUntil(timeout: 2.0) {
            guard let latest = probe.latest else { return false }
            let level100 = latest.level(near: 100, window: 40)
            let level1k = latest.level(near: 1_000, window: 200)
            return level100 > -20 && level100 > level1k + 12
        }
        XCTAssertTrue(
            movedTo100,
            "Spectrum did not follow the new 100 Hz source. 100 Hz=\(probe.latest?.level(near: 100, window: 40) ?? -120) dB, 1 kHz=\(probe.latest?.level(near: 1_000, window: 200) ?? -120) dB"
        )
    }

    func testFailedPhysicalStartDoesNotLeaveTheTestSignalRunning() async throws {
        let engine = AudioEngineManager(configuration: SpectrumConfiguration())
        defer { engine.stop() }

        try await engine.start(source: .testSignal(.sine1k))
        XCTAssertTrue(engine.isTestSignalRunning)

        let fake = AudioDevice(
            objectID: 0x7FFF_FFFE,
            uid: "spectrum.fake-input",
            name: "Fake Input",
            sampleRate: 48_000,
            inputChannelCount: 1,
            kind: .physical,
            hasInput: true
        )

        do {
            try await engine.start(source: .physical(fake))
            XCTFail("Fake physical device should not start.")
        } catch {
            // Expected: the device does not exist.
        }

        XCTAssertFalse(
            engine.isTestSignalRunning,
            "Test-signal generator kept running after a source change, which mixes 1 kHz into live audio."
        )
        XCTAssertFalse(engine.isRunning)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

private final class SpectrumLevelProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [SpectrumData] = []

    func append(_ data: SpectrumData) {
        lock.lock()
        frames.append(data)
        lock.unlock()
    }

    var latest: SpectrumData? {
        lock.lock()
        defer { lock.unlock() }
        return frames.last
    }

    func dominantFrequency(near frequency: Float, window: Float) -> Float? {
        lock.lock()
        defer { lock.unlock() }
        guard let frame = frames.last else { return nil }
        let peak = frame.peakFrequency()
        guard abs(peak - frequency) <= window else { return nil }
        return peak
    }
}

private extension SpectrumData {
    func level(near frequency: Float, window: Float) -> Float {
        let matches = zip(frequencies, magnitudesDB).filter { abs($0.0 - frequency) <= window }
        return matches.map(\.1).max() ?? -120
    }

    func peakFrequency() -> Float {
        zip(frequencies, magnitudesDB).max(by: { $0.1 < $1.1 })?.0 ?? 0
    }
}
