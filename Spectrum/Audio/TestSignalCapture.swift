import Foundation
import Synchronization

/// Internal PCM generator that writes into the same ring buffer as hardware capture.
final class TestSignalCapture: AudioCapture, @unchecked Sendable {
    private static let queueKey = DispatchSpecificKey<UInt8>()

    private let ringBuffer: AudioRingBuffer
    private let bufferProcessor: AudioBufferProcessor
    private var generator: LiveSignalGenerator
    private var source: DispatchSourceTimer?
    private let queue: DispatchQueue
    private var scratch: UnsafeMutablePointer<Float>
    private let scratchCount = 2_048
    private let running = Atomic<Bool>(false)

    private(set) var sampleRate: Double
    private(set) var channelCount: Int = 1

    var isRunning: Bool { running.load(ordering: .acquiring) }

    var kind: TestSignalKind {
        didSet { generator.kind = kind }
    }

    var availableDevices: [AudioDevice] {
        [AudioDevice.testSignal(sampleRate: sampleRate)]
    }

    init(
        ringBuffer: AudioRingBuffer,
        bufferProcessor: AudioBufferProcessor,
        kind: TestSignalKind = .sine1k,
        sampleRate: Double = 48_000
    ) {
        self.ringBuffer = ringBuffer
        self.bufferProcessor = bufferProcessor
        self.kind = kind
        self.sampleRate = sampleRate
        self.generator = LiveSignalGenerator(kind: kind, sampleRate: sampleRate)
        self.scratch = .allocate(capacity: scratchCount)
        self.scratch.initialize(repeating: 0, count: scratchCount)
        let queue = DispatchQueue(label: "com.byrdal.Spectrum.test-signal", qos: .userInitiated)
        queue.setSpecific(key: Self.queueKey, value: 1)
        self.queue = queue
    }

    deinit {
        stop()
        scratch.deinitialize(count: scratchCount)
        scratch.deallocate()
    }

    func start(device: AudioDevice) async throws {
        stop()
        sampleRate = device.sampleRate > 0 ? device.sampleRate : 48_000
        generator.sampleRate = sampleRate
        generator.kind = kind
        generator.reset()
        running.store(true, ordering: .releasing)
        startTimer()
    }

    func start(kind: TestSignalKind, sampleRate: Double = 48_000) async throws {
        self.kind = kind
        try await start(device: AudioDevice.testSignal(sampleRate: sampleRate))
    }

    func stop() {
        running.store(false, ordering: .releasing)
        source?.cancel()
        source = nil
        drainTimerQueue()
    }

    private func drainTimerQueue() {
        // A cancelled DispatchSource can still deliver one in-flight handler.
        // Flush it so the SPSC ring buffer never has two producers.
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return
        }
        queue.sync {}
    }

    private func startTimer() {
        let frames = 512
        let interval = Double(frames) / sampleRate
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, self.running.load(ordering: .acquiring) else { return }
            self.generator.render(into: self.scratch, count: frames)
            self.bufferProcessor.writeMono(self.scratch, count: frames, into: self.ringBuffer)
        }
        source = timer
        timer.resume()
    }
}
