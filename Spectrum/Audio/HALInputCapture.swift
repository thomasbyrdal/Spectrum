import Accelerate
import CoreAudio
import Darwin
import Foundation
import OSLog
import Synchronization

/// Captures from a Core Audio device using an IOProc.
///
/// Input-only AUHAL (`EnableIO` output = 0 + `SetInputCallback`) often never
/// invokes the callback, which produced a blank spectrum for every live source.
/// `AudioDeviceStart` delivers input buffers directly to the IOProc instead.
final class HALInputCapture: @unchecked Sendable {
    private var deviceID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private let running = Atomic<Bool>(false)
    private let loggedFormatError = Atomic<Bool>(false)
    private let processor: AudioBufferProcessor
    private let ringBuffer: AudioRingBuffer

    private var convertScratch: UnsafeMutablePointer<Float>
    private var convertCapacity = 16_384
    private var ioBufferFrames = 512
    private var channels = 1
    private var bytesPerFrame = 4
    private var bitsPerChannel = 32
    private var isFloat = true
    private var isNonInterleaved = false
    private var context: IOProcContext?
    private var retiredContexts: [IOProcContext] = []

    private(set) var sampleRate: Double = 48_000
    private(set) var capturedChannelCount: Int = 1

    init(processor: AudioBufferProcessor, ringBuffer: AudioRingBuffer) {
        self.processor = processor
        self.ringBuffer = ringBuffer
        self.convertScratch = .allocate(capacity: convertCapacity)
        self.convertScratch.initialize(repeating: 0, count: convertCapacity)
    }

    deinit {
        stop()
        convertScratch.deinitialize(count: convertCapacity)
        convertScratch.deallocate()
    }

    func start(deviceID: AudioDeviceID, format: AudioStreamBasicDescription? = nil) throws {
        stop()

        var asbd = try format ?? readStreamFormat(deviceID)
        guard asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0, asbd.mBytesPerFrame > 0 else {
            throw AudioCaptureError.deviceHasNoInput
        }

        let bufferFrames = max(Int(readBufferFrameSize(deviceID)), 64)
        self.deviceID = deviceID
        sampleRate = asbd.mSampleRate
        channels = Int(asbd.mChannelsPerFrame)
        capturedChannelCount = channels
        bytesPerFrame = Int(asbd.mBytesPerFrame)
        bitsPerChannel = Int(asbd.mBitsPerChannel)
        isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        ioBufferFrames = bufferFrames
        ensureConvertCapacity(bufferFrames * max(channels, 2))
        loggedFormatError.store(false, ordering: .releasing)

        let ctx = IOProcContext(capture: self)
        context = ctx

        var procID: AudioDeviceIOProcID?
        try check(
            AudioDeviceCreateIOProcID(
                deviceID,
                Self.ioProc,
                Unmanaged.passUnretained(ctx).toOpaque(),
                &procID
            ),
            "create IOProc"
        )
        guard let procID else {
            throw AudioCaptureError.unableToStart("Unable to start audio capture.")
        }
        ioProcID = procID
        running.store(true, ordering: .releasing)

        let startStatus = AudioDeviceStart(deviceID, procID)
        if startStatus != noErr {
            teardownIOProc()
            try check(startStatus, "start device")
        }
    }

    func stop() {
        teardownIOProc()
    }

    /// Invalidate first so a leftover IOProc cannot write, then stop/destroy.
    /// If destroy fails, the context is retained so the callback cannot use-after-free
    /// or revive itself when a new context is allocated at the same address.
    private func teardownIOProc() {
        running.store(false, ordering: .releasing)
        context?.invalidate()
        if let procID = ioProcID, deviceID != 0 {
            let status = AudioDeviceStop(deviceID, procID)
            if status != noErr {
                AppLog.audio.error("AudioDeviceStop failed \(status, privacy: .public)")
            }
            let destroyed = AudioDeviceDestroyIOProcID(deviceID, procID)
            if destroyed != noErr {
                AppLog.audio.error("AudioDeviceDestroyIOProcID failed \(destroyed, privacy: .public)")
                if let context {
                    retiredContexts.append(context)
                }
            }
        }
        ioProcID = nil
        deviceID = 0
        context = nil
    }

    private func readStreamFormat(_ deviceID: AudioDeviceID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &asbd)
        if status == noErr, asbd.mChannelsPerFrame > 0, asbd.mSampleRate > 0 {
            return asbd
        }

        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamSize: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamSize), "input stream list size")
        let streamCount = Int(streamSize) / MemoryLayout<AudioStreamID>.size
        guard streamCount > 0 else {
            throw AudioCaptureError.deviceHasNoInput
        }
        var streamID: AudioStreamID = 0
        var oneStream = UInt32(MemoryLayout<AudioStreamID>.size)
        try check(
            AudioObjectGetPropertyData(deviceID, &streamAddress, 0, nil, &oneStream, &streamID),
            "read first input stream"
        )
        var virtualAddress = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(streamID, &virtualAddress, 0, nil, &size, &asbd),
            "read stream virtual format"
        )
        return asbd
    }

    private func readBufferFrameSize(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var frames: UInt32 = 512
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &frames) == noErr, frames > 0 {
            return frames
        }
        return 512
    }

    private func ensureConvertCapacity(_ count: Int) {
        guard count > convertCapacity else { return }
        convertScratch.deinitialize(count: convertCapacity)
        convertScratch.deallocate()
        convertCapacity = 1 << (Int.bitWidth - (count - 1).leadingZeroBitCount)
        convertScratch = .allocate(capacity: convertCapacity)
        convertScratch.initialize(repeating: 0, count: convertCapacity)
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            AppLog.audio.error("Device \(operation, privacy: .public) failed \(status, privacy: .public)")
            throw AudioCaptureError.unableToStart("Unable to start audio capture.")
        }
    }

    private static let ioProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
        guard let clientData else { return noErr }
        let context = Unmanaged<IOProcContext>.fromOpaque(clientData).takeUnretainedValue()
        let capture = context.capture
        guard context.isAlive else { return noErr }
        guard capture.running.load(ordering: .acquiring) else { return noErr }

        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard list.count > 0, list[0].mData != nil, list[0].mDataByteSize > 0 else { return noErr }

        let frames = capture.framesInBufferList(list)
        guard frames > 0 else { return noErr }

        if capture.isFloat {
            capture.processor.writeMono(from: list, frames: frames, into: capture.ringBuffer, maxChannels: 2)
        } else {
            capture.convertIntegerToMono(list: list, frames: frames)
        }
        return noErr
    }

    private func framesInBufferList(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        let bytes = Int(list[0].mDataByteSize)
        let bytesPerSample = isFloat ? 4 : max(bitsPerChannel / 8, 1)
        let channelsInBuffer = max(Int(list[0].mNumberChannels), 1)
        let frames: Int
        if list.count == 1 && channelsInBuffer > 1 {
            frames = bytes / (bytesPerSample * channelsInBuffer)
        } else {
            frames = bytes / bytesPerSample
        }
        return min(max(frames, 0), ioBufferFrames)
    }

    private func convertIntegerToMono(list: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard frames <= convertCapacity else { return }

        if isNonInterleaved || list.count > 1 && list[0].mNumberChannels <= 1 {
            memset(convertScratch, 0, frames * MemoryLayout<Float>.stride)
            var mixed = 0
            let mixCount = min(list.count, 2)
            for index in 0..<mixCount {
                guard let data = list[index].mData else { continue }
                addIntegerChannel(data, frames: frames, into: convertScratch)
                mixed += 1
            }
            guard mixed > 0 else { return }
            if mixed > 1 {
                var scale = 1.0 / Float(mixed)
                vDSP_vsmul(convertScratch, 1, &scale, convertScratch, 1, vDSP_Length(frames))
            }
        } else {
            guard let data = list[0].mData else { return }
            mixInterleavedInteger(data, frames: frames, channels: min(channels, 2), into: convertScratch)
        }
        processor.writeMono(convertScratch, count: frames, into: ringBuffer)
    }

    private func addIntegerChannel(_ data: UnsafeMutableRawPointer, frames: Int, into destination: UnsafeMutablePointer<Float>) {
        if bitsPerChannel == 16 {
            let source = data.assumingMemoryBound(to: Int16.self)
            for index in 0..<frames {
                destination[index] += Float(source[index]) / 32_768.0
            }
        } else if bitsPerChannel >= 24 {
            let source = data.assumingMemoryBound(to: Int32.self)
            for index in 0..<frames {
                destination[index] += Float(source[index]) / Float(Int32.max)
            }
        } else {
            logUnsupportedFormatOnce()
        }
    }

    private func mixInterleavedInteger(
        _ data: UnsafeMutableRawPointer,
        frames: Int,
        channels: Int,
        into destination: UnsafeMutablePointer<Float>
    ) {
        let channels = max(channels, 1)
        let scale = 1.0 / Float(channels)
        if bitsPerChannel == 16 {
            let source = data.assumingMemoryBound(to: Int16.self)
            for frame in 0..<frames {
                var sum: Float = 0
                let base = frame * channels
                for channel in 0..<channels {
                    sum += Float(source[base + channel]) / 32_768.0
                }
                destination[frame] = sum * scale
            }
        } else if bitsPerChannel >= 24 {
            let source = data.assumingMemoryBound(to: Int32.self)
            for frame in 0..<frames {
                var sum: Float = 0
                let base = frame * channels
                for channel in 0..<channels {
                    sum += Float(source[base + channel]) / Float(Int32.max)
                }
                destination[frame] = sum * scale
            }
        } else {
            logUnsupportedFormatOnce()
        }
    }

    private func logUnsupportedFormatOnce() {
        if !loggedFormatError.exchange(true, ordering: .relaxed) {
            AppLog.audio.error("Unsupported input sample format: \(self.bitsPerChannel, privacy: .public)-bit")
        }
    }
}

/// Per-start callback token. `HALInputCapture.running` is shared across restarts;
/// a leftover IOProc must not start writing again when the next source sets it true.
private final class IOProcContext: @unchecked Sendable {
    unowned let capture: HALInputCapture
    private let alive = Atomic<Bool>(true)

    init(capture: HALInputCapture) {
        self.capture = capture
    }

    var isAlive: Bool {
        alive.load(ordering: .acquiring)
    }

    func invalidate() {
        alive.store(false, ordering: .releasing)
    }
}
