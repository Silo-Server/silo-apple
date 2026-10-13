import AetherEngine
import Foundation

/// A cue with a half-open display window, `startTime <= t < endTime`.
protocol SubtitleCueTiming {
    var startTime: Double { get }
    var endTime: Double { get }
}

extension SubtitleCue: SubtitleCueTiming {}
extension LiveSubtitleCue: SubtitleCueTiming {}

/// The cues showing at a clock time, without filtering every cue on every
/// playback tick.
///
/// Cues are indexed by start time. Normal playback advances a pointer past the
/// cues that have started and drops the ones that have ended; a backward seek
/// or a jump of more than `forwardStepLimit` rebuilds the active set with a
/// binary search. Overlapping cues are all returned, in the order of the cue
/// list, which is the order the overlay draws them in.
///
/// A reference type so a view can advance it while computing its body without
/// a state write; `active(at:)` returns the same array until the set changes.
final class SubtitleCueCursor<Cue: SubtitleCueTiming> {
    /// Larger forward moves rebuild instead of walking every cue in between.
    private static var forwardStepLimit: Double { 5 }

    private var cues: [Cue] = []
    /// Indices into `cues`, ordered by start time.
    private var startOrder: [Int] = []
    /// No cue lasts longer, so none starting earlier than `t - longest` can
    /// still be showing at `t`.
    private var longest: Double = 0
    /// Position in `startOrder` of the first cue starting after `clock`.
    private var next = 0
    /// Indices into `cues` of the cues showing at `clock`, ascending.
    private var activeIndices: [Int] = []
    private var clock: Double?
    /// `activeIndices` as cues, rebuilt only when that set changes.
    private var shown: [Cue] = []

    func reset(_ cues: [Cue]) {
        self.cues = cues
        // Ties keep list order; `sorted` alone is not stable.
        startOrder = cues.indices.sorted { (cues[$0].startTime, $0) < (cues[$1].startTime, $1) }
        longest = cues.reduce(0) { max($0, $1.endTime - $1.startTime) }
        reposition()
    }

    /// The next lookup rebuilds from scratch, for a clock that changed meaning
    /// (a subtitle delay change, a movie/engine timeline switch).
    func reposition() {
        clock = nil
        next = 0
        activeIndices = []
        shown = []
    }

    func active(at time: Double) -> [Cue] {
        let changed: Bool
        if let clock, time >= clock, time - clock <= Self.forwardStepLimit {
            changed = advance(to: time)
        } else {
            changed = rebuild(at: time)
        }
        clock = time
        if changed {
            shown = activeIndices.map { cues[$0] }
        }
        return shown
    }

    private func advance(to time: Double) -> Bool {
        let before = activeIndices
        activeIndices.removeAll { cues[$0].endTime <= time }
        while next < startOrder.count, cues[startOrder[next]].startTime <= time {
            let index = startOrder[next]
            next += 1
            if time < cues[index].endTime { activeIndices.append(index) }
        }
        activeIndices.sort()
        return activeIndices != before
    }

    private func rebuild(at time: Double) -> Bool {
        // First cue starting after `time`.
        var low = 0
        var high = startOrder.count
        while low < high {
            let middle = (low + high) / 2
            if cues[startOrder[middle]].startTime <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        next = low

        var rebuilt: [Int] = []
        var position = low - 1
        while position >= 0, cues[startOrder[position]].startTime >= time - longest {
            let index = startOrder[position]
            if time < cues[index].endTime { rebuilt.append(index) }
            position -= 1
        }
        rebuilt.sort()
        let changed = rebuilt != activeIndices
        activeIndices = rebuilt
        return changed
    }
}

extension SubtitleCueCursor where Cue: Equatable {
    /// For cue lists the caller does not hand over explicitly, such as live AI
    /// cues that grow while they show. An unchanged array compares by storage.
    func active(at time: Double, in cues: [Cue]) -> [Cue] {
        if cues != self.cues { reset(cues) }
        return active(at: time)
    }
}
