import AVFAudio
import XCTest
@testable import Spectrum

final class AudioBufferProcessorTests: XCTestCase {
    func testInterleavedStereoMixesToMonoWithoutCrashing() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        )
        XCTAssertNotNil(format)
        let buffer = AVAudioPCMBuffer(pcmFormat: format!, frameCapacity: 8)
        XCTAssertNotNil(buffer)
        buffer!.frameLength = 8

        let samples = buffer!.floatChannelData![0]
        for frame in 0..<8 {
            samples[frame * 2] = 0.50
            samples[frame * 2 + 1] = 0.25
        }

        let ring = AudioRingBuffer(minimumCapacity: 64)
        let processor = AudioBufferProcessor(capacity: 32)
        processor.writeMono(from: buffer!, into: ring)

        var output = [Float](repeating: 0, count: 8)
        let read = output.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 8) }
        XCTAssertEqual(read, 8)
        for sample in output {
            XCTAssertEqual(sample, 0.375, accuracy: 0.0001)
        }
    }

    func testDeinterleavedStereoStillMixesToMono() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        buffer.frameLength = 4
        for frame in 0..<4 {
            buffer.floatChannelData![0][frame] = 1.0
            buffer.floatChannelData![1][frame] = 0.0
        }

        let ring = AudioRingBuffer(minimumCapacity: 32)
        AudioBufferProcessor(capacity: 16).writeMono(from: buffer, into: ring)

        var output = [Float](repeating: 0, count: 4)
        XCTAssertEqual(output.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 4) }, 4)
        for sample in output {
            XCTAssertEqual(sample, 0.5, accuracy: 0.0001)
        }
    }

    func testHALStyleInterleavedBufferListIsNotSilent() {
        let frames = 8
        let channels = 2
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }
        let data = UnsafeMutablePointer<Float>.allocate(capacity: frames * channels)
        defer { data.deallocate() }
        for frame in 0..<frames {
            data[frame * 2] = 0.8
            data[frame * 2 + 1] = 0.2
        }
        list[0] = AudioBuffer(
            mNumberChannels: UInt32(channels),
            mDataByteSize: UInt32(frames * channels * MemoryLayout<Float>.stride),
            mData: UnsafeMutableRawPointer(data)
        )

        let ring = AudioRingBuffer(minimumCapacity: 32)
        AudioBufferProcessor(capacity: 16).writeMono(from: list, frames: frames, into: ring)

        var output = [Float](repeating: 0, count: frames)
        XCTAssertEqual(output.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: frames) }, frames)
        for sample in output {
            XCTAssertEqual(sample, 0.5, accuracy: 0.0001)
        }
    }

    func testExtraDeinterleavedChannelsAreIgnored() {
        let frames = 4
        let list = AudioBufferList.allocate(maximumBuffers: 4)
        defer { free(list.unsafeMutablePointer) }
        var allocations: [UnsafeMutablePointer<Float>] = []
        for channel in 0..<4 {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            allocations.append(data)
            for frame in 0..<frames {
                data[frame] = channel < 2 ? 0.4 : Float(frame) * 0.3
            }
            list[channel] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(frames * MemoryLayout<Float>.stride),
                mData: UnsafeMutableRawPointer(data)
            )
        }
        defer { allocations.forEach { $0.deallocate() } }

        let ring = AudioRingBuffer(minimumCapacity: 32)
        AudioBufferProcessor(capacity: 16).writeMono(from: list, frames: frames, into: ring, maxChannels: 2)

        var output = [Float](repeating: 0, count: frames)
        XCTAssertEqual(output.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: frames) }, frames)
        for sample in output {
            XCTAssertEqual(sample, 0.4, accuracy: 0.0001)
        }
    }

    func testHALStyleInterleavedStereoWritesSeparateChannels() {
        let frames = 8
        let channels = 2
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }
        let data = UnsafeMutablePointer<Float>.allocate(capacity: frames * channels)
        defer { data.deallocate() }
        for frame in 0..<frames {
            data[frame * 2] = 0.8
            data[frame * 2 + 1] = 0.2
        }
        list[0] = AudioBuffer(
            mNumberChannels: UInt32(channels),
            mDataByteSize: UInt32(frames * channels * MemoryLayout<Float>.stride),
            mData: UnsafeMutableRawPointer(data)
        )

        let left = AudioRingBuffer(minimumCapacity: 32)
        let right = AudioRingBuffer(minimumCapacity: 32)
        AudioBufferProcessor(capacity: 16).write(
            from: list,
            frames: frames,
            intoLeft: left,
            intoRight: right
        )

        var leftOut = [Float](repeating: 0, count: frames)
        var rightOut = [Float](repeating: 0, count: frames)
        XCTAssertEqual(leftOut.withUnsafeMutableBufferPointer { left.read(into: $0.baseAddress!, count: frames) }, frames)
        XCTAssertEqual(rightOut.withUnsafeMutableBufferPointer { right.read(into: $0.baseAddress!, count: frames) }, frames)
        for frame in 0..<frames {
            XCTAssertEqual(leftOut[frame], 0.8, accuracy: 0.0001)
            XCTAssertEqual(rightOut[frame], 0.2, accuracy: 0.0001)
        }
    }

    func testDeinterleavedStereoWritesSeparateChannels() {
        let frames = 4
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        let leftData = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let rightData = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer {
            leftData.deallocate()
            rightData.deallocate()
        }
        for frame in 0..<frames {
            leftData[frame] = 1.0
            rightData[frame] = 0.0
        }
        list[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(frames * MemoryLayout<Float>.stride),
            mData: UnsafeMutableRawPointer(leftData)
        )
        list[1] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(frames * MemoryLayout<Float>.stride),
            mData: UnsafeMutableRawPointer(rightData)
        )

        let left = AudioRingBuffer(minimumCapacity: 32)
        let right = AudioRingBuffer(minimumCapacity: 32)
        AudioBufferProcessor(capacity: 16).write(
            from: list,
            frames: frames,
            intoLeft: left,
            intoRight: right
        )

        var leftOut = [Float](repeating: 0, count: frames)
        var rightOut = [Float](repeating: 0, count: frames)
        XCTAssertEqual(leftOut.withUnsafeMutableBufferPointer { left.read(into: $0.baseAddress!, count: frames) }, frames)
        XCTAssertEqual(rightOut.withUnsafeMutableBufferPointer { right.read(into: $0.baseAddress!, count: frames) }, frames)
        for frame in 0..<frames {
            XCTAssertEqual(leftOut[frame], 1.0, accuracy: 0.0001)
            XCTAssertEqual(rightOut[frame], 0.0, accuracy: 0.0001)
        }
    }
}
