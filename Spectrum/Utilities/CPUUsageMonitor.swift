import Darwin
import Foundation

/// Samples this process's CPU usage. Display-only; never called from the audio callback.
final class CPUUsageMonitor: @unchecked Sendable {
    private var previousUser: Double = 0
    private var previousSystem: Double = 0
    private var previousWall: CFAbsoluteTime = 0

    func sample() -> Double {
        var info = task_thread_times_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_thread_times_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let user = timeValueSeconds(info.user_time)
        let system = timeValueSeconds(info.system_time)
        let wall = CFAbsoluteTimeGetCurrent()

        defer {
            previousUser = user
            previousSystem = system
            previousWall = wall
        }

        guard previousWall > 0 else { return 0 }
        let wallDelta = wall - previousWall
        guard wallDelta > 0.001 else { return 0 }
        let cpuDelta = (user - previousUser) + (system - previousSystem)
        return min(max(cpuDelta / wallDelta, 0), Double(ProcessInfo.processInfo.processorCount))
    }

    private func timeValueSeconds(_ value: time_value_t) -> Double {
        Double(value.seconds) + Double(value.microseconds) / 1_000_000.0
    }
}
