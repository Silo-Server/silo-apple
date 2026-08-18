#if os(iOS) || os(tvOS)
import Foundation
import os

struct LogRingSnapshot: Equatable {
    let lines: [String]
    let droppedCount: Int
}

final class LogRing {
    static let defaultCapacity = 4000

    private let capacity: Int
    private var lines: [String?]
    private var nextIndex = 0
    private var count = 0
    private var droppedCount = 0
    /// `OSAllocatedUnfairLock` owns stable allocated storage. A stored
    /// `os_unfair_lock_s` locked through `&lock` would not: the inout access may
    /// be satisfied with a temporary copy, so two threads can lock different
    /// memory and lose mutual exclusion entirely.
    private let lock = OSAllocatedUnfairLock()

    init(capacity: Int = LogRing.defaultCapacity) {
        precondition(capacity > 0, "LogRing capacity must be positive")
        self.capacity = capacity
        self.lines = Array(repeating: nil, count: capacity)
    }

    func append(_ line: String) {
        lock.lock()
        lines[nextIndex] = line
        nextIndex = (nextIndex + 1) % capacity
        if count == capacity {
            droppedCount += 1
        } else {
            count += 1
        }
        lock.unlock()
    }

    func snapshot() -> LogRingSnapshot {
        lock.lock()
        let start = count == capacity ? nextIndex : 0
        let snapshotLines = (0..<count).compactMap { offset in
            lines[(start + offset) % capacity]
        }
        let dropped = droppedCount
        lock.unlock()
        return LogRingSnapshot(lines: snapshotLines, droppedCount: dropped)
    }

    /// Drops every buffered line and resets the dropped-line counter. Used when
    /// the active diagnostics binding changes so a new binding's manual report
    /// or crash snapshot cannot include the previous binding's log lines.
    func clear() {
        lock.lock()
        for index in lines.indices {
            lines[index] = nil
        }
        nextIndex = 0
        count = 0
        droppedCount = 0
        lock.unlock()
    }
}
#endif
