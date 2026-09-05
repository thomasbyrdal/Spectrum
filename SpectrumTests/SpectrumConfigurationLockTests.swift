import XCTest
@testable import Spectrum

/// Regression: changing Bars / FFT / Window used to deadlock the UI.
///
/// The DSP serial queue ran an infinite loop, and `applyConfiguration`
/// waited on that queue from the main thread (`sync`). This test fails if
/// those calls do not return while capture is running.
final class SpectrumConfigurationLockTests: XCTestCase {
    func testChangingBarsFFTSizeAndWindowDoesNotLockTheApplication() async throws {
        let engine = AudioEngineManager(configuration: SpectrumConfiguration())
        let probe = SpectrumFrameProbe()
        engine.setSpectrumHandler { probe.append($0.left) }
        defer { engine.stop() }

        try await engine.start(source: .testSignal(.sine1k))

        let started = await waitUntil(timeout: 2.0) { probe.count > 0 }
        XCTAssertTrue(started, "DSP never published a spectrum frame; deadlock test is invalid without a running engine.")

        let applyReturned = expectation(description: "bar, FFT, and window changes returned")
        let framesBeforeChanges = probe.count

        Task { @MainActor in
            var config = SpectrumConfiguration()

            config.barCount = 256
            engine.applyConfiguration(config)

            config.fftSize = 4_096
            engine.applyConfiguration(config)

            config.windowFunction = .blackmanHarris
            engine.applyConfiguration(config)

            applyReturned.fulfill()
        }

        await fulfillment(of: [applyReturned], timeout: 2.0)

        let barsUpdated = await waitUntil(timeout: 2.0) { probe.containsBarCount(256) }
        XCTAssertTrue(barsUpdated, "Engine accepted a bar-count change but never published 256-bar spectrum data.")

        let keepAlive = await waitUntil(timeout: 2.0) { probe.count > framesBeforeChanges + 3 }
        XCTAssertTrue(keepAlive, "DSP stopped publishing frames after Bars / FFT / Window changes.")
    }

    func testRepeatedControlChangesFromMainThreadStayResponsive() async throws {
        let engine = AudioEngineManager(configuration: SpectrumConfiguration())
        let probe = SpectrumFrameProbe()
        engine.setSpectrumHandler { probe.append($0.left) }
        defer { engine.stop() }

        try await engine.start(source: .testSignal(.sine1k))
        let started = await waitUntil(timeout: 2.0) { probe.count > 0 }
        XCTAssertTrue(started, "DSP never published a spectrum frame.")

        let applyReturned = expectation(description: "repeated control changes returned")

        Task { @MainActor in
            var config = SpectrumConfiguration()
            for bars in BarCount.allCases {
                config.barCount = bars.rawValue
                engine.applyConfiguration(config)
            }
            for fft in [FFTSize.n2048, .n4096, .n8192, .n16384, .n32768] {
                config.fftSize = fft.rawValue
                engine.applyConfiguration(config)
            }
            for window in WindowFunction.allCases {
                config.windowFunction = window
                engine.applyConfiguration(config)
            }
            applyReturned.fulfill()
        }

        await fulfillment(of: [applyReturned], timeout: 2.0)

        let stillRunning = await waitUntil(timeout: 2.0) {
            probe.lastBarCount == BarCount.allCases.last?.rawValue
        }
        XCTAssertTrue(stillRunning, "Final bar-count selection never appeared in spectrum data.")
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

private final class SpectrumFrameProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [SpectrumData] = []

    func append(_ data: SpectrumData) {
        lock.lock()
        frames.append(data)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }

    var lastBarCount: Int? {
        lock.lock()
        defer { lock.unlock() }
        return frames.last?.barCount
    }

    func containsBarCount(_ count: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return frames.contains { $0.barCount == count }
    }
}
