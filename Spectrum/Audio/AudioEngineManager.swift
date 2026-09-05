import Accelerate
import Foundation
import Synchronization

/// Producer/consumer engine:
/// audio callback → lock-free ring buffer → DSP queue → `SpectrumData` → UI callback.
final class AudioEngineManager: @unchecked Sendable {
    let ringBuffer = AudioRingBuffer(minimumCapacity: 1 << 18)
    let ringRight = AudioRingBuffer(minimumCapacity: 1 << 18)
    let bufferProcessor = AudioBufferProcessor()
    let deviceManager = AudioDeviceManager()

    private static let dspQueueKey = DispatchSpecificKey<UInt8>()
    private let dspQueue: DispatchQueue
    private var dspTimer: DispatchSourceTimer?
    private var processor: SpectrumProcessor
    private var rightProcessor: SpectrumProcessor
    private var configuration: SpectrumConfiguration
    private var sampleRate: Double = 48_000
    private var channelCount: Int = 1
    private var sourceIsStereo = false
    private var showStereoSpectrum = false
    private var running = false
    private var readScratch: UnsafeMutablePointer<Float>
    private var readScratchRight: UnsafeMutablePointer<Float>
    private var mixScratch: UnsafeMutablePointer<Float>
    private var readCapacity = 8_192

    private var testCapture: TestSignalCapture
    private var physicalCapture: PhysicalAudioCapture
    private var systemCapture: SystemAudioCapture
    private var activeCapture: AudioCapture?

    private var onSpectrum: ((SpectrumPair) -> Void)?
    private var onActivity: ((Bool) -> Void)?
    private var lastUIPush: UInt64 = 0
    private var spectrumGeneration: UInt64 = 0
    private var dspLoopGeneration: UInt64 = 0
    private var analysisPhase: AnalysisPhase = .idle
    private var lastAudibleNanos: UInt64 = 0
    private var captureStartedNanos: UInt64 = 0
    private let startLock = AsyncStartLock()
    private let startGeneration = Atomic<UInt64>(0)

    /// Linear peak below this is treated as silence (~−66 dBFS).
    private static let audiblePeak: Float = 5e-4
    private static let silenceHoldNanos: UInt64 = 400_000_000
    private static let activeTickMs = 3
    private static let idleTickMs = 50

    private enum AnalysisPhase {
        case idle
        case analyzing
        case decaying
    }

    /// Generation stamped onto spectrum frames for the current source.
    var currentSpectrumGeneration: UInt64 { spectrumGeneration }

    init(configuration: SpectrumConfiguration) {
        let queue = DispatchQueue(label: "dk.byrdal.Spectrum.dsp", qos: .userInitiated)
        queue.setSpecific(key: Self.dspQueueKey, value: 1)
        self.dspQueue = queue
        self.configuration = configuration
        self.processor = SpectrumProcessor(configuration: configuration, sampleRate: 48_000)
        self.rightProcessor = SpectrumProcessor(configuration: configuration, sampleRate: 48_000)
        self.readScratch = .allocate(capacity: readCapacity)
        self.readScratch.initialize(repeating: 0, count: readCapacity)
        self.readScratchRight = .allocate(capacity: readCapacity)
        self.readScratchRight.initialize(repeating: 0, count: readCapacity)
        self.mixScratch = .allocate(capacity: readCapacity)
        self.mixScratch.initialize(repeating: 0, count: readCapacity)
        self.testCapture = TestSignalCapture(ringBuffer: ringBuffer, bufferProcessor: bufferProcessor)
        self.physicalCapture = PhysicalAudioCapture(
            ringBuffer: ringBuffer,
            ringRight: ringRight,
            bufferProcessor: bufferProcessor,
            deviceManager: deviceManager
        )
        self.systemCapture = SystemAudioCapture(
            ringBuffer: ringBuffer,
            ringRight: ringRight,
            bufferProcessor: bufferProcessor,
            deviceManager: deviceManager
        )
    }

    deinit {
        stop()
        readScratch.deinitialize(count: readCapacity)
        readScratch.deallocate()
        readScratchRight.deinitialize(count: readCapacity)
        readScratchRight.deallocate()
        mixScratch.deinitialize(count: readCapacity)
        mixScratch.deallocate()
    }

    var currentSampleRate: Double { sampleRate }
    var currentChannelCount: Int { channelCount }
    var isRunning: Bool { running }
    var isTestSignalRunning: Bool { testCapture.isRunning }

    func setSpectrumHandler(_ handler: @escaping (SpectrumPair) -> Void) {
        onSpectrum = handler
    }

    func setActivityHandler(_ handler: @escaping (Bool) -> Void) {
        onActivity = handler
    }

    func setShowStereoSpectrum(_ enabled: Bool) {
        dspQueue.async { [weak self] in
            guard let self, self.showStereoSpectrum != enabled else { return }
            self.showStereoSpectrum = enabled
            self.processor.reset()
            self.rightProcessor.reset()
            self.lastUIPush = 0
        }
    }

    func applyConfiguration(_ configuration: SpectrumConfiguration) {
        // Never `sync` onto the DSP queue from the UI thread. The DSP work must
        // remain finite so this block can actually run.
        dspQueue.async { [weak self] in
            guard let self else { return }
            self.configuration = configuration
            self.processor.reconfigure(configuration: configuration, sampleRate: self.sampleRate)
            self.rightProcessor.reconfigure(configuration: configuration, sampleRate: self.sampleRate)
        }
    }

    func start(source: AudioSource) async throws {
        try await startLock.withLock {
            let generation = self.startGeneration.wrappingAdd(1, ordering: .releasing).newValue
            try await self.performStart(source: source, generation: generation)
        }
    }

    private func performStart(source: AudioSource, generation: UInt64) async throws {
        // Always tear down every capture. The ring buffer is single-producer;
        // leaving the test-signal timer running mixes 1 kHz into live audio.
        stopCapturesAndDSP()
        try abortIfStale(generation)
        ringBuffer.reset()
        ringRight.reset()
        bufferProcessor.resetMeters()
        sourceIsStereo = false
        lastUIPush = 0
        analysisPhase = .idle
        lastAudibleNanos = 0
        captureStartedNanos = DispatchTime.now().uptimeNanoseconds
        let spectrumGeneration = bumpSpectrumGeneration()

        switch source {
        case .testSignal(let kind):
            testCapture.kind = kind
            try await testCapture.start(kind: kind, sampleRate: 48_000)
            try abortIfStale(generation)
            activeCapture = testCapture
            sampleRate = testCapture.sampleRate
            channelCount = testCapture.channelCount
        case .physical(let device):
            try await physicalCapture.start(device: device)
            try abortIfStale(generation)
            activeCapture = physicalCapture
            sampleRate = physicalCapture.sampleRate
            channelCount = physicalCapture.channelCount
        case .systemAudio:
            try await systemCapture.startSystemAudio()
            try abortIfStale(generation)
            activeCapture = systemCapture
            sampleRate = systemCapture.sampleRate
            channelCount = systemCapture.channelCount
        case .application(let process):
            try await systemCapture.start(process: process)
            try abortIfStale(generation)
            activeCapture = systemCapture
            sampleRate = systemCapture.sampleRate
            channelCount = systemCapture.channelCount
        }

        let work = { [weak self] in
            guard let self, self.stillCurrent(generation) else { return }
            self.sourceIsStereo = self.channelCount >= 2
            self.processor.reconfigure(configuration: self.configuration, sampleRate: self.sampleRate)
            self.rightProcessor.reconfigure(configuration: self.configuration, sampleRate: self.sampleRate)
            self.processor.reset()
            self.rightProcessor.reset()
            self.dspLoopGeneration = spectrumGeneration
            self.running = true
            self.startDSPLoop(intervalMs: Self.activeTickMs)
        }
        if DispatchQueue.getSpecific(key: Self.dspQueueKey) != nil {
            work()
        } else {
            dspQueue.sync(execute: work)
        }
    }

    func stop() {
        startGeneration.wrappingAdd(1, ordering: .releasing)
        stopCapturesAndDSP()
    }

    private func stillCurrent(_ generation: UInt64) -> Bool {
        startGeneration.load(ordering: .acquiring) == generation
    }

    private func abortIfStale(_ generation: UInt64) throws {
        guard stillCurrent(generation) else {
            throw CancellationError()
        }
    }

    private func stopCapturesAndDSP() {
        stopAndDrainDSP()
        testCapture.stop()
        physicalCapture.stop()
        systemCapture.stop()
        activeCapture = nil
    }

    private func stopAndDrainDSP() {
        let work = { [weak self] in
            guard let self else { return }
            self.running = false
            if self.analysisPhase == .analyzing {
                self.onActivity?(false)
            }
            self.analysisPhase = .idle
            self.spectrumGeneration += 1
            self.dspTimer?.cancel()
            self.dspTimer = nil
        }
        if DispatchQueue.getSpecific(key: Self.dspQueueKey) != nil {
            work()
        } else {
            dspQueue.sync(execute: work)
        }
    }

    private func bumpSpectrumGeneration() -> UInt64 {
        var value: UInt64 = 0
        let work = { [weak self] in
            guard let self else { return }
            self.spectrumGeneration += 1
            value = self.spectrumGeneration
        }
        if DispatchQueue.getSpecific(key: Self.dspQueueKey) != nil {
            work()
        } else {
            dspQueue.sync(execute: work)
        }
        return value
    }

    private func startDSPLoop(intervalMs: Int) {
        dspTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: dspQueue)
        let leeway = max(1, intervalMs / 5)
        timer.schedule(deadline: .now(), repeating: .milliseconds(intervalMs), leeway: .milliseconds(leeway))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        dspTimer = timer
        timer.resume()
    }

    private func tick() {
        guard running else { return }
        var hops = 0
        var heardAudio = false
        while running, hops < 8 {
            let hop = max(processor.hopSize, 64)
            let available = sourceIsStereo
                ? min(ringBuffer.availableToRead, ringRight.availableToRead)
                : ringBuffer.availableToRead
            guard available >= hop else { break }
            if processAvailable(hop: hop) {
                heardAudio = true
            }
            hops += 1
        }

        let now = DispatchTime.now().uptimeNanoseconds
        if heardAudio {
            lastAudibleNanos = now
        } else {
            let reference = lastAudibleNanos == 0 ? captureStartedNanos : lastAudibleNanos
            if now &- reference >= Self.silenceHoldNanos {
                enterDecayIfNeeded()
            }
        }

        if analysisPhase == .decaying {
            publishDecayFrame()
        }
    }

    /// Returns true when the hop contained audible energy.
    @discardableResult
    private func processAvailable(hop: Int) -> Bool {
        ensureReadCapacity(hop)
        let count = ringBuffer.read(into: readScratch, count: hop)
        guard count > 0 else { return false }

        var hopPeak = peakMagnitude(readScratch, count: count)
        var analyzeLeft = readScratch
        var analyzeCount = count
        var rightCount = 0

        if sourceIsStereo {
            rightCount = ringRight.read(into: readScratchRight, count: hop)
            hopPeak = max(hopPeak, peakMagnitude(readScratchRight, count: rightCount))
            if !showStereoSpectrum, rightCount > 0 {
                mixHops(count: min(count, rightCount))
                analyzeLeft = mixScratch
                analyzeCount = min(count, rightCount)
            }
        }

        let audible = hopPeak >= Self.audiblePeak
        let meters = bufferProcessor.consumeMeters()

        if !audible {
            return false
        }
        if analysisPhase != .analyzing {
            enterAnalyzing()
        }

        let peakDB = DecibelCalculator.amplitudeToDB(meters.peak, floorDB: configuration.minimumDB)
        let rmsDB = DecibelCalculator.amplitudeToDB(meters.rms, floorDB: configuration.minimumDB)
        let publishStereo = showStereoSpectrum && sourceIsStereo && rightCount > 0

        let leftSnapshot = processor.push(
            samples: UnsafeBufferPointer(start: analyzeLeft, count: analyzeCount),
            peakDBFS: peakDB,
            rmsDBFS: rmsDB,
            isClipping: meters.clipping
        )
        let rightSnapshot = publishStereo
            ? rightProcessor.push(
                samples: UnsafeBufferPointer(start: readScratchRight, count: rightCount),
                peakDBFS: peakDB,
                rmsDBFS: rmsDB,
                isClipping: meters.clipping
            )
            : nil

        guard let leftSnapshot else { return true }

        let now = leftSnapshot.timestamp
        let minInterval = UInt64(1_000_000_000 / max(configuration.targetFrameRate, 15))
        if now &- lastUIPush >= minInterval || lastUIPush == 0 {
            lastUIPush = now
            let generation = dspLoopGeneration
            guard generation == spectrumGeneration else { return true }
            onSpectrum?(
                SpectrumPair(
                    left: leftSnapshot.withGeneration(generation),
                    right: rightSnapshot?.withGeneration(generation)
                )
            )
        }
        return true
    }

    private func mixHops(count: Int) {
        var scale: Float = 0.5
        vDSP_vadd(readScratch, 1, readScratchRight, 1, mixScratch, 1, vDSP_Length(count))
        vDSP_vsmul(mixScratch, 1, &scale, mixScratch, 1, vDSP_Length(count))
    }

    private func peakMagnitude(_ samples: UnsafeMutablePointer<Float>, count: Int) -> Float {
        var peak: Float = 0
        for index in 0..<count {
            let magnitude = abs(samples[index])
            if magnitude > peak {
                peak = magnitude
            }
        }
        return peak
    }

    private func enterAnalyzing() {
        let previous = analysisPhase
        guard previous != .analyzing else { return }
        analysisPhase = .analyzing
        if previous != .decaying {
            processor.reset()
            rightProcessor.reset()
        } else {
            processor.resetTimeWindow()
            rightProcessor.resetTimeWindow()
        }
        lastUIPush = 0
        startDSPLoop(intervalMs: Self.activeTickMs)
        onActivity?(true)
    }

    private func enterDecayIfNeeded() {
        guard analysisPhase == .analyzing else { return }
        analysisPhase = .decaying
        processor.resetTimeWindow()
        rightProcessor.resetTimeWindow()
        lastUIPush = 0
        startDSPLoop(intervalMs: decayTickMs)
        onActivity?(false)
    }

    private func enterIdle() {
        guard analysisPhase != .idle else { return }
        if analysisPhase == .analyzing {
            onActivity?(false)
        }
        analysisPhase = .idle
        startDSPLoop(intervalMs: Self.idleTickMs)
    }

    private var decayTickMs: Int {
        max(8, 1_000 / max(configuration.targetFrameRate, 15))
    }

    private func publishDecayFrame() {
        let now = DispatchTime.now().uptimeNanoseconds
        let minInterval = UInt64(1_000_000_000 / max(configuration.targetFrameRate, 15))
        guard now &- lastUIPush >= minInterval || lastUIPush == 0 else { return }

        let decayed = processor.decayTowardSilence()
        let rightDecayed = showStereoSpectrum && sourceIsStereo
            ? rightProcessor.decayTowardSilence()
            : nil
        lastUIPush = now
        let generation = dspLoopGeneration
        guard generation == spectrumGeneration else { return }
        onSpectrum?(
            SpectrumPair(
                left: decayed.data.withGeneration(generation),
                right: rightDecayed?.data.withGeneration(generation)
            )
        )
        if decayed.settled && (rightDecayed?.settled ?? true) {
            enterIdle()
        }
    }

    private func ensureReadCapacity(_ count: Int) {
        guard count > readCapacity else { return }
        readScratch.deinitialize(count: readCapacity)
        readScratch.deallocate()
        readScratchRight.deinitialize(count: readCapacity)
        readScratchRight.deallocate()
        mixScratch.deinitialize(count: readCapacity)
        mixScratch.deallocate()
        readCapacity = 1 << (Int.bitWidth - (count - 1).leadingZeroBitCount)
        readScratch = .allocate(capacity: readCapacity)
        readScratch.initialize(repeating: 0, count: readCapacity)
        readScratchRight = .allocate(capacity: readCapacity)
        readScratchRight.initialize(repeating: 0, count: readCapacity)
        mixScratch = .allocate(capacity: readCapacity)
        mixScratch.initialize(repeating: 0, count: readCapacity)
    }
}

/// Non-reentrant lock that stays held across `await`, unlike a Swift actor.
/// Two overlapping source changes must not both write the ring buffer.
private final class AsyncStartLock: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if busy {
                waiters.append(continuation)
                lock.unlock()
            } else {
                busy = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    private func release() {
        lock.lock()
        if waiters.isEmpty {
            busy = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}
