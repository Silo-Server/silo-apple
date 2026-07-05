import Darwin
import Foundation
import QuartzCore

/// Calls the raw C symbol so the label of a queue owned by another thread
/// can be read without ARC retaining an object we do not own.
@_silgen_name("dispatch_queue_get_label")
private func cmpDispatchQueueGetLabel(_ queue: OpaquePointer) -> UnsafePointer<CChar>?

/// Temporary [CMP-CPU] instrumentation for the loopback route: attributes
/// app CPU to individual threads (by the dispatch queue label the thread is
/// draining where available, else its pthread name) and reports whole-device
/// per-core load, so an on-device capture distinguishes "our producer /
/// subtitle threads are hot" from "the SoC is saturated by out-of-process
/// decode (mediaserverd)". Percentages are exact averages over the interval
/// between samples (cumulative thread CPU-time deltas), not the kernel's
/// decayed `cpu_usage`. Main-thread only — sample state is unsynchronized.
enum PlayerCPUDiagnostics {
    private struct ThreadSample {
        let label: String
        let cpuTimeNs: UInt64
    }

    private static var lastSampleWall: Double = 0
    private static var lastThreadTimes: [UInt64: ThreadSample] = [:]
    private static var lastCoreTicks: [[UInt32]] = []

    private static let cpuStateUser = 0
    private static let cpuStateSystem = 1
    private static let cpuStateIdle = 2
    private static let cpuStateNice = 3
    private static let cpuStateMax = 4

    /// One formatted sample line (without the [CMP-CPU] prefix), or nil if
    /// the mach calls failed or this is the priming sample.
    static func sampleLine() -> String? {
        let now = CACurrentMediaTime()
        let elapsed = now - lastSampleWall
        let threads = sampleThreads()
        let cores = sampleCoreBusyPercents()
        defer { lastSampleWall = now }

        guard let threads else { return nil }
        let previous = lastThreadTimes
        lastThreadTimes = threads
        // Priming sample: no interval to average over yet.
        guard !previous.isEmpty, elapsed > 0.5 else { return nil }

        let elapsedNs = elapsed * 1_000_000_000
        var shares: [(label: String, percent: Double)] = []
        var totalPercent = 0.0
        for (tid, sample) in threads {
            let priorNs = previous[tid]?.cpuTimeNs ?? sample.cpuTimeNs
            guard sample.cpuTimeNs > priorNs else { continue }
            let percent = Double(sample.cpuTimeNs - priorNs) / elapsedNs * 100
            totalPercent += percent
            if percent >= 2 {
                shares.append((sample.label, percent))
            }
        }
        shares.sort { $0.percent > $1.percent }

        var line = String(format: "app=%.1f%% threads=%d", totalPercent, threads.count)
        if let cores {
            let coreList = cores.map { String(format: "%.0f", $0) }.joined(separator: "/")
            line += " cores=\(coreList)"
        }
        if !shares.isEmpty {
            let top = shares.prefix(8)
                .map { String(format: "%@=%.1f%%", $0.label, $0.percent) }
                .joined(separator: " ")
            line += " top: " + top
        }
        return line
    }

    /// Cumulative CPU time and best-effort label for every live thread,
    /// keyed by mach thread id.
    private static func sampleThreads() -> [UInt64: ThreadSample]? {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threadList else {
            return nil
        }
        defer {
            let size = vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadList)), size)
        }

        var samples: [UInt64: ThreadSample] = [:]
        samples.reserveCapacity(Int(threadCount))
        for index in 0..<Int(threadCount) {
            let thread = threadList[index]
            defer { mach_port_deallocate(mach_task_self_, thread) }

            var extended = thread_extended_info_data_t()
            var extendedCount = mach_msg_type_number_t(
                MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<integer_t>.size
            )
            let extendedKr = withUnsafeMutablePointer(to: &extended) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(extendedCount)) {
                    thread_info(thread, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &extendedCount)
                }
            }
            guard extendedKr == KERN_SUCCESS else { continue }

            var identifier = thread_identifier_info_data_t()
            var identifierCount = mach_msg_type_number_t(
                MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<integer_t>.size
            )
            let identifierKr = withUnsafeMutablePointer(to: &identifier) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(identifierCount)) {
                    thread_info(thread, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &identifierCount)
                }
            }
            guard identifierKr == KERN_SUCCESS else { continue }

            samples[identifier.thread_id] = ThreadSample(
                label: threadLabel(extended: extended, identifier: identifier),
                cpuTimeNs: extended.pth_user_time + extended.pth_system_time
            )
        }
        return samples
    }

    /// Prefer the dispatch queue the thread is currently draining (GCD
    /// workers carry no pthread name); fall back to the pthread name, then
    /// the thread id. Reading `dispatch_qaddr` is the crash-reporter
    /// technique: it can race a queue teardown, which is acceptable for a
    /// temporary diagnostic aimed at long-lived pipeline queues.
    private static func threadLabel(
        extended: thread_extended_info_data_t,
        identifier: thread_identifier_info_data_t
    ) -> String {
        if identifier.dispatch_qaddr != 0,
           let slot = UnsafeRawPointer(bitPattern: UInt(identifier.dispatch_qaddr)) {
            let queue = slot.assumingMemoryBound(to: OpaquePointer?.self).pointee
            if let queue,
               let labelPtr = cmpDispatchQueueGetLabel(queue) {
                let label = String(cString: labelPtr)
                if !label.isEmpty { return shortLabel(label) }
            }
        }
        var name = extended.pth_name
        let pthreadName = withUnsafeBytes(of: &name) { raw -> String in
            let bytes = raw.bindMemory(to: UInt8.self)
            let length = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[..<length], as: UTF8.self)
        }
        if !pthreadName.isEmpty { return shortLabel(pthreadName) }
        return String(format: "tid_0x%llx", identifier.thread_id)
    }

    /// Keep the distinctive tail of reverse-DNS labels so the 3s log line
    /// stays scannable.
    private static func shortLabel(_ label: String) -> String {
        guard label.count > 40 else { return label }
        return "…" + label.suffix(39)
    }

    /// Whole-device busy percent per core since the previous sample, from
    /// host tick counters (includes every process, e.g. mediaserverd).
    private static func sampleCoreBusyPercents() -> [Double]? {
        var coreCount = natural_t(0)
        var info: processor_info_array_t?
        var infoCount = mach_msg_type_number_t(0)
        guard host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &coreCount,
            &info,
            &infoCount
        ) == KERN_SUCCESS, let info else {
            return nil
        }
        defer {
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), size)
        }

        var ticksPerCore: [[UInt32]] = []
        ticksPerCore.reserveCapacity(Int(coreCount))
        for core in 0..<Int(coreCount) {
            let base = core * cpuStateMax
            ticksPerCore.append((0..<cpuStateMax).map { UInt32(bitPattern: info[base + $0]) })
        }

        let previous = lastCoreTicks
        lastCoreTicks = ticksPerCore
        guard previous.count == ticksPerCore.count else { return nil }

        var busyPercents: [Double] = []
        for (prior, current) in zip(previous, ticksPerCore) {
            let user = Double(current[cpuStateUser] &- prior[cpuStateUser])
            let system = Double(current[cpuStateSystem] &- prior[cpuStateSystem])
            let nice = Double(current[cpuStateNice] &- prior[cpuStateNice])
            let idle = Double(current[cpuStateIdle] &- prior[cpuStateIdle])
            let total = user + system + nice + idle
            busyPercents.append(total > 0 ? (user + system + nice) / total * 100 : 0)
        }
        return busyPercents
    }
}
