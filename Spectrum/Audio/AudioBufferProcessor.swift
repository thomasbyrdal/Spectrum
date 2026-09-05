import Accelerate
import AVFAudio
import CoreAudio
import Foundation

/// Writes incoming buffers as mono or split L/R Float32 and measures peak / RMS.
/// Scratch storage is preallocated so the audio callback never allocates.
final class AudioBufferProcessor: @unchecked Sendable {
    private var mixScratch: UnsafeMutablePointer<Float>
    private var leftScratch: UnsafeMutablePointer<Float>
    private var rightScratch: UnsafeMutablePointer<Float>
    private let mixCapacity: Int
    private var peak: Float = 0
    private var sumSquares: Float = 0
    private var frameCount: Int = 0

    init(capacity: Int = 16_384) {
        mixCapacity = capacity
        mixScratch = .allocate(capacity: capacity)
        mixScratch.initialize(repeating: 0, count: capacity)
        leftScratch = .allocate(capacity: capacity)
        leftScratch.initialize(repeating: 0, count: capacity)
        rightScratch = .allocate(capacity: capacity)
        rightScratch.initialize(repeating: 0, count: capacity)
    }

    deinit {
        mixScratch.deinitialize(count: mixCapacity)
        mixScratch.deallocate()
        leftScratch.deinitialize(count: mixCapacity)
        leftScratch.deallocate()
        rightScratch.deinitialize(count: mixCapacity)
        rightScratch.deallocate()
    }

    func resetMeters() {
        peak = 0
        sumSquares = 0
        frameCount = 0
    }

    /// Snapshot current meters. Safe to call from the DSP thread.
    func consumeMeters() -> (peak: Float, rms: Float, clipping: Bool) {
        let peakNow = peak
        let rms: Float = frameCount > 0 ? sqrt(sumSquares / Float(frameCount)) : 0
        peak *= 0.65
        sumSquares = 0
        frameCount = 0
        return (peakNow, rms, peakNow >= 0.99)
    }

    /// Writes mono Float32 into the ring buffer. Called from the audio I/O thread.
    func writeMono(from buffer: AVAudioPCMBuffer, into ringBuffer: AudioRingBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let channels = max(Int(buffer.format.channelCount), 1)

        if buffer.format.isInterleaved {
            guard let samples = buffer.floatChannelData?[0] else { return }
            writeInterleaved(samples, frames: frames, channelStride: channels, mixCount: channels, into: ringBuffer)
            return
        }

        guard let channelData = buffer.floatChannelData else { return }
        writeDeinterleaved(channelData, frames: frames, channels: channels, into: ringBuffer)
    }

    /// HAL / IOProc path. Layout is taken from the buffer list, not from a stored ASBD,
    /// so interleaved stereo is not treated as a faster mono stream.
    func writeMono(
        from bufferList: UnsafeMutableAudioBufferListPointer,
        frames: Int,
        into ringBuffer: AudioRingBuffer,
        maxChannels: Int = 2
    ) {
        guard frames > 0, !bufferList.isEmpty else { return }
        let maxChannels = max(maxChannels, 1)

        if bufferList.count == 1 || bufferList[0].mNumberChannels > 1 {
            guard let data = bufferList[0].mData else { return }
            let stride = max(Int(bufferList[0].mNumberChannels), 1)
            writeInterleaved(
                data.assumingMemoryBound(to: Float.self),
                frames: frames,
                channelStride: stride,
                mixCount: min(stride, maxChannels),
                into: ringBuffer
            )
            return
        }

        let mixCount = min(bufferList.count, maxChannels)
        var remaining = frames
        var offset = 0
        while remaining > 0 {
            let chunk = min(remaining, mixCapacity)
            memset(mixScratch, 0, chunk * MemoryLayout<Float>.stride)
            var mixedChannels = 0
            for index in 0..<mixCount {
                guard let data = bufferList[index].mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self) + offset
                if mixedChannels == 0 {
                    memcpy(mixScratch, samples, chunk * MemoryLayout<Float>.stride)
                } else {
                    vDSP_vadd(mixScratch, 1, samples, 1, mixScratch, 1, vDSP_Length(chunk))
                }
                mixedChannels += 1
            }
            if mixedChannels == 0 { return }
            if mixedChannels > 1 {
                var scale = 1.0 / Float(mixedChannels)
                vDSP_vsmul(mixScratch, 1, &scale, mixScratch, 1, vDSP_Length(chunk))
            }
            updateMeters(mixScratch, count: chunk)
            commit(mixScratch, count: chunk, into: ringBuffer)
            remaining -= chunk
            offset += chunk
        }
    }

    func writeMono(_ samples: UnsafePointer<Float>, count: Int, into ringBuffer: AudioRingBuffer) {
        var remaining = count
        var pointer = samples
        while remaining > 0 {
            let chunk = min(remaining, mixCapacity)
            updateMeters(pointer, count: chunk)
            commit(pointer, count: chunk, into: ringBuffer)
            remaining -= chunk
            pointer += chunk
        }
    }

    /// HAL / IOProc path. When `right` is non-nil and the buffer has two channels,
    /// writes L and R separately and still meters the mix.
    func write(
        from bufferList: UnsafeMutableAudioBufferListPointer,
        frames: Int,
        intoLeft left: AudioRingBuffer,
        intoRight right: AudioRingBuffer?,
        maxChannels: Int = 2
    ) {
        guard let right else {
            writeMono(from: bufferList, frames: frames, into: left, maxChannels: maxChannels)
            return
        }
        guard frames > 0, !bufferList.isEmpty else { return }
        let maxChannels = max(maxChannels, 1)

        if bufferList.count == 1 || bufferList[0].mNumberChannels > 1 {
            guard let data = bufferList[0].mData else { return }
            let stride = max(Int(bufferList[0].mNumberChannels), 1)
            writeInterleavedStereo(
                data.assumingMemoryBound(to: Float.self),
                frames: frames,
                channelStride: stride,
                intoLeft: left,
                intoRight: right
            )
            return
        }

        writeDeinterleavedStereo(
            bufferList,
            frames: frames,
            maxChannels: maxChannels,
            intoLeft: left,
            intoRight: right
        )
    }

    func writeStereo(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        count: Int,
        intoLeft leftRing: AudioRingBuffer,
        intoRight rightRing: AudioRingBuffer
    ) {
        var remaining = count
        var leftPointer = left
        var rightPointer = right
        var scale: Float = 0.5
        while remaining > 0 {
            let chunk = min(remaining, mixCapacity)
            vDSP_vadd(leftPointer, 1, rightPointer, 1, mixScratch, 1, vDSP_Length(chunk))
            vDSP_vsmul(mixScratch, 1, &scale, mixScratch, 1, vDSP_Length(chunk))
            updateMeters(mixScratch, count: chunk)
            commit(leftPointer, count: chunk, into: leftRing)
            commit(rightPointer, count: chunk, into: rightRing)
            remaining -= chunk
            leftPointer += chunk
            rightPointer += chunk
        }
    }

    private func writeDeinterleaved(
        _ channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        frames: Int,
        channels: Int,
        into ringBuffer: AudioRingBuffer
    ) {
        var remaining = frames
        var offset = 0
        while remaining > 0 {
            let chunk = min(remaining, mixCapacity)
            if channels <= 1 {
                updateMeters(channelData[0] + offset, count: chunk)
                commit(channelData[0] + offset, count: chunk, into: ringBuffer)
            } else {
                memcpy(mixScratch, channelData[0] + offset, chunk * MemoryLayout<Float>.stride)
                for channel in 1..<channels {
                    vDSP_vadd(mixScratch, 1, channelData[channel] + offset, 1, mixScratch, 1, vDSP_Length(chunk))
                }
                var scale = 1.0 / Float(channels)
                vDSP_vsmul(mixScratch, 1, &scale, mixScratch, 1, vDSP_Length(chunk))
                updateMeters(mixScratch, count: chunk)
                commit(mixScratch, count: chunk, into: ringBuffer)
            }
            remaining -= chunk
            offset += chunk
        }
    }

    private func writeInterleaved(
        _ samples: UnsafePointer<Float>,
        frames: Int,
        channelStride: Int,
        mixCount: Int,
        into ringBuffer: AudioRingBuffer
    ) {
        let stride = max(channelStride, 1)
        let mixCount = min(max(mixCount, 1), stride)
        var remaining = frames
        var frameOffset = 0
        var scale = 1.0 / Float(mixCount)
        while remaining > 0 {
            let chunk = min(remaining, mixCapacity)
            let source = samples + frameOffset * stride
            if stride == 1, mixCount == 1 {
                updateMeters(source, count: chunk)
                commit(source, count: chunk, into: ringBuffer)
            } else {
                for frame in 0..<chunk {
                    var sum: Float = 0
                    let base = frame * stride
                    for channel in 0..<mixCount {
                        sum += source[base + channel]
                    }
                    mixScratch[frame] = sum
                }
                vDSP_vsmul(mixScratch, 1, &scale, mixScratch, 1, vDSP_Length(chunk))
                updateMeters(mixScratch, count: chunk)
                commit(mixScratch, count: chunk, into: ringBuffer)
            }
            remaining -= chunk
            frameOffset += chunk
        }
    }

    private func writeInterleavedStereo(
        _ samples: UnsafePointer<Float>,
        frames: Int,
        channelStride: Int,
        intoLeft left: AudioRingBuffer,
        intoRight right: AudioRingBuffer
    ) {
        let stride = max(channelStride, 1)
        var remaining = frames
        var frameOffset = 0
        var scale: Float = stride > 1 ? 0.5 : 1
        while remaining > 0 {
            let chunk = min(remaining, mixCapacity)
            let source = samples + frameOffset * stride
            if stride == 1 {
                updateMeters(source, count: chunk)
                commit(source, count: chunk, into: left)
                commit(source, count: chunk, into: right)
            } else {
                for frame in 0..<chunk {
                    let base = frame * stride
                    leftScratch[frame] = source[base]
                    rightScratch[frame] = source[base + 1]
                }
                vDSP_vadd(leftScratch, 1, rightScratch, 1, mixScratch, 1, vDSP_Length(chunk))
                vDSP_vsmul(mixScratch, 1, &scale, mixScratch, 1, vDSP_Length(chunk))
                updateMeters(mixScratch, count: chunk)
                commit(leftScratch, count: chunk, into: left)
                commit(rightScratch, count: chunk, into: right)
            }
            remaining -= chunk
            frameOffset += chunk
        }
    }

    private func writeDeinterleavedStereo(
        _ bufferList: UnsafeMutableAudioBufferListPointer,
        frames: Int,
        maxChannels: Int,
        intoLeft left: AudioRingBuffer,
        intoRight right: AudioRingBuffer
    ) {
        guard let first = bufferList[0].mData else { return }
        let leftSource = first.assumingMemoryBound(to: Float.self)
        let rightSource: UnsafeMutablePointer<Float>
        if bufferList.count > 1, maxChannels > 1, let second = bufferList[1].mData {
            rightSource = second.assumingMemoryBound(to: Float.self)
        } else {
            rightSource = leftSource
        }

        var remaining = frames
        var offset = 0
        var scale: Float = rightSource == leftSource ? 1 : 0.5
        while remaining > 0 {
            let chunk = min(remaining, mixCapacity)
            let leftChunk = leftSource + offset
            let rightChunk = rightSource + offset
            if rightSource == leftSource {
                updateMeters(leftChunk, count: chunk)
            } else {
                vDSP_vadd(leftChunk, 1, rightChunk, 1, mixScratch, 1, vDSP_Length(chunk))
                vDSP_vsmul(mixScratch, 1, &scale, mixScratch, 1, vDSP_Length(chunk))
                updateMeters(mixScratch, count: chunk)
            }
            commit(leftChunk, count: chunk, into: left)
            commit(rightChunk, count: chunk, into: right)
            remaining -= chunk
            offset += chunk
        }
    }

    private func commit(_ samples: UnsafePointer<Float>, count: Int, into ringBuffer: AudioRingBuffer) {
        _ = ringBuffer.write(samples, count: count)
    }

    private func updateMeters(_ samples: UnsafePointer<Float>, count: Int) {
        var maxValue: Float = 0
        vDSP_maxmgv(samples, 1, &maxValue, vDSP_Length(count))
        if maxValue > peak {
            peak = maxValue
        }
        var sqsum: Float = 0
        vDSP_svesq(samples, 1, &sqsum, vDSP_Length(count))
        sumSquares += sqsum
        frameCount += count
    }
}
