import Foundation
import Synchronization

/// Single-producer / single-consumer lock-free ring buffer for Float32 PCM.
/// The audio callback only writes; the DSP thread only reads. No allocations after init.
final class AudioRingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let mask: Int
    private let writeIndex = Atomic<UInt64>(0)
    private let readIndex = Atomic<UInt64>(0)

    init(minimumCapacity: Int) {
        let power = 1 << (Int.bitWidth - max(minimumCapacity, 16).leadingZeroBitCount)
        capacity = power
        mask = power - 1
        storage = .allocate(capacity: power)
        storage.initialize(repeating: 0, count: power)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    var availableToRead: Int {
        Int(writeIndex.load(ordering: .acquiring) &- readIndex.load(ordering: .acquiring))
    }

    func reset() {
        writeIndex.store(0, ordering: .releasing)
        readIndex.store(0, ordering: .releasing)
    }

    @discardableResult
    func write(_ samples: UnsafePointer<Float>, count: Int) -> Int {
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        let used = Int(write &- read)
        let free = capacity - used
        guard free > 0 else { return 0 }
        let toWrite = min(count, free)
        let start = Int(write) & mask
        let first = min(toWrite, capacity - start)
        memcpy(storage.advanced(by: start), samples, first * MemoryLayout<Float>.stride)
        if toWrite > first {
            memcpy(storage, samples.advanced(by: first), (toWrite - first) * MemoryLayout<Float>.stride)
        }
        writeIndex.store(write &+ UInt64(toWrite), ordering: .releasing)
        return toWrite
    }

    @discardableResult
    func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        let available = Int(write &- read)
        guard available > 0 else { return 0 }
        let toRead = min(count, available)
        let start = Int(read) & mask
        let first = min(toRead, capacity - start)
        memcpy(destination, storage.advanced(by: start), first * MemoryLayout<Float>.stride)
        if toRead > first {
            memcpy(destination.advanced(by: first), storage, (toRead - first) * MemoryLayout<Float>.stride)
        }
        readIndex.store(read &+ UInt64(toRead), ordering: .releasing)
        return toRead
    }
}
