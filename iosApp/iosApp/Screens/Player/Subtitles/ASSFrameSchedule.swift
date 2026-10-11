import AetherEngine
import CoreMedia
import Foundation
import os

/// Presentation times of the video frames Aether has handed to the picture,
/// so the ASS overlay renders each frame at the exact instant that frame is
/// shown.
///
/// Typesetters time signs to frames, with event boundaries between two
/// frames' timestamps. Sampling a running clock instead lands on the
/// neighbouring frame's event for part of every frame interval, which is
/// visible on a tracked sign as a one-frame shake.
///
/// Fed from Aether's frame-time observers on their own threads; read by the
/// presenter actor.
final class ASSFrameSchedule: @unchecked Sendable {
    /// Which of Aether's playback paths reported a frame. Each runs on its own
    /// clock and numbers its epochs or generations from its own sequence, so
    /// the two are kept apart.
    enum Source: Sendable {
        /// The native path: frames as the producer muxes them, on the player
        /// item's axis.
        case native
        /// The software path: frames as the renderer enqueues them, on the
        /// source clock.
        case software
    }

    struct Frame: Equatable, Sendable {
        /// The frame's exact timestamp on the clock the overlay layer runs
        /// against: the player item's timebase on AVPlayer paths, the source
        /// clock on the software path. Canvases are stamped with it unrounded,
        /// so a canvas never shows a display refresh before its frame.
        let stamp: CMTime
        /// On the clock subtitle cues use.
        let source: Double

        var presentation: Double { stamp.seconds }

        init(stamp: CMTime, source: Double) {
            self.stamp = stamp
            self.source = source
        }

        init(presentation: Double, source: Double) {
            self.init(stamp: CMTime(seconds: presentation, preferredTimescale: 1_000_000_000), source: source)
        }
    }

    /// Ample for a few minutes of muxed-ahead video at high frame rates.
    static let capacity = 20_000

    /// One path's frames, ascending by presentation time, and the newest
    /// epoch or generation it has reported.
    private struct Table {
        var frames: [Frame] = []
        var generation: UInt64 = 0

        /// First index whose presentation time is after `time`.
        func firstIndex(after time: Double) -> Int {
            var low = 0, high = frames.count
            while low < high {
                let mid = (low + high) / 2
                if frames[mid].presentation <= time { low = mid + 1 } else { high = mid }
            }
            return low
        }

        /// Moves to a newer epoch or generation. A native restart re-muxes from
        /// `presentation` on, so the frames from there describe the new epoch
        /// only; nil drops every frame.
        mutating func restart(generation: UInt64, from presentation: Double?) {
            self.generation = generation
            guard let presentation else { return frames.removeAll() }
            frames.removeSubrange(firstIndex(after: presentation.nextDown)...)
        }

        mutating func insert(_ frame: Frame) {
            let time = frame.presentation
            // Decode order is presentation order apart from B-frame reordering,
            // so the slot is almost always at or near the end.
            var index = frames.count
            while index > 0, frames[index - 1].presentation > time { index -= 1 }
            if index > 0, frames[index - 1].presentation == time {
                frames[index - 1] = frame
            } else {
                frames.insert(frame, at: index)
            }
            // Nothing prunes while no overlay is showing, so trim in batches
            // rather than shifting every retained frame on each report.
            if frames.count > capacity { frames.removeFirst(frames.count - capacity * 3 / 4) }
        }
    }

    /// Each table is mutated in place through the dictionary: a copy taken out
    /// and written back would copy every retained frame on each report.
    private let state = OSAllocatedUnfairLock(initialState: [Source.native: Table(), .software: Table()])

    /// Native path: frames arrive in decode order as the producer muxes them,
    /// usually seconds ahead of display. A producer restart re-muxes from its
    /// start position onward, so the frames from there on describe the new
    /// epoch only.
    func record(_ time: NativeVideoFrameTime) {
        let frame = Frame(stamp: time.item, source: time.source.seconds)
        guard frame.presentation.isFinite, frame.source.isFinite else { return }
        state.withLock { tables in
            let generation = tables[.native, default: Table()].generation
            if time.epoch > generation {
                tables[.native, default: Table()].restart(generation: time.epoch, from: frame.presentation)
            } else if time.epoch < generation {
                return
            }
            tables[.native, default: Table()].insert(frame)
        }
    }

    /// Software path: frames arrive in presentation order at enqueue, on the
    /// source clock. A new generation means the renderer discarded its queue.
    func record(_ time: SoftwareVideoFrameTime) {
        let seconds = time.presentation.seconds
        guard seconds.isFinite else { return }
        state.withLock { tables in
            let generation = tables[.software, default: Table()].generation
            if time.generation > generation {
                tables[.software, default: Table()].restart(generation: time.generation, from: nil)
            } else if time.generation < generation {
                return
            }
            tables[.software, default: Table()].insert(Frame(stamp: time.presentation, source: seconds))
        }
    }

    /// Forgets every frame. Epochs and generations only ever rise, so a late
    /// report from the outgoing item still ranks as stale.
    func removeAll() {
        state.withLock { tables in
            for source in Array(tables.keys) { tables[source]?.frames.removeAll() }
        }
    }

    /// The frame on screen at `time`: the latest one presented at or before it.
    func frame(atOrBefore time: Double, in source: Source) -> Frame? {
        state.withLock { tables in
            guard let table = tables[source] else { return nil }
            let index = table.firstIndex(after: time)
            return index > 0 ? table.frames[index - 1] : nil
        }
    }

    /// Frames presented after `start`, through `end`, ascending.
    func frames(after start: Double, through end: Double, in source: Source) -> [Frame] {
        state.withLock { tables in
            guard let table = tables[source] else { return [] }
            var index = table.firstIndex(after: start)
            var frames: [Frame] = []
            while index < table.frames.count, table.frames[index].presentation <= end {
                frames.append(table.frames[index])
                index += 1
            }
            return frames
        }
    }

    /// Whether any frame is known after `time`.
    func hasFrames(after time: Double, in source: Source) -> Bool {
        state.withLock { ($0[source]?.frames.last?.presentation ?? -.infinity) > time }
    }

    /// Drops frames shown long before `time`.
    func prune(before time: Double, in source: Source) {
        state.withLock { tables in
            guard let index = tables[source]?.firstIndex(after: time), index > 1 else { return }
            tables[source]?.frames.removeFirst(index - 1)
        }
    }
}
