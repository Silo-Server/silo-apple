#if os(iOS) || os(tvOS)
import Foundation
import os.lock

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
    private var lock = os_unfair_lock_s()

    init(capacity: Int = LogRing.defaultCapacity) {
        precondition(capacity > 0, "LogRing capacity must be positive")
        self.capacity = capacity
        self.lines = Array(repeating: nil, count: capacity)
    }

    func append(_ line: String) {
        os_unfair_lock_lock(&lock)
        lines[nextIndex] = line
        nextIndex = (nextIndex + 1) % capacity
        if count == capacity {
            droppedCount += 1
        } else {
            count += 1
        }
        os_unfair_lock_unlock(&lock)
    }

    func snapshot() -> LogRingSnapshot {
        os_unfair_lock_lock(&lock)
        let start = count == capacity ? nextIndex : 0
        let snapshotLines = (0..<count).compactMap { offset in
            lines[(start + offset) % capacity]
        }
        let dropped = droppedCount
        os_unfair_lock_unlock(&lock)
        return LogRingSnapshot(lines: snapshotLines, droppedCount: dropped)
    }
}
#endif
