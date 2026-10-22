import Foundation

/// What the engine's reader receives from the Silo origin, for the buffering
/// controller: when the plan's media data last arrived, and the rate it
/// arrived at (the spec's *Playback samples*).
///
/// On direct play AVPlayer reads from Aether's server on 127.0.0.1, so its own
/// requests and their errors say nothing about the origin. The media requests
/// are the reader's: AetherEngine counts every byte it pulls from the source
/// (`LiveTelemetry.demuxerBytesFetched`) and publishes the total once a
/// second. The meter takes those ticks. Server HLS has no reader, and the
/// player feeds it nothing there.
///
/// That total is the pump's alone. The spec counts all of the plan's main
/// media reads, but a second reader of the same file, such as the engine's
/// subtitle prefetch, shares the link without a published count, and the
/// pump's share alone reads low (gauntlet V5: 2666 kbps learned on a 22 Mbps
/// link). A tick that such a reader may have shared stays out of the rate,
/// so the plan reports none rather than an under-read.
///
/// A tick that saw bytes counts as receiving for its whole interval, so the
/// rate is a lower bound: a reader that filled its window in part of a second
/// and then parked reads low, never high. The engine reads its counter before
/// it publishes, so a tick can arrive late and the next one early; each tick
/// is charged at least the interval before it, so a second's bytes are never
/// charged to a fraction of one. It holds no clock and performs no I/O.
struct UpstreamReadMeter {
    /// `OUTAGE_NO_DATA_MS`: a wait with no media data for this long is an
    /// outage, counted from the tick that saw the last byte. That tick comes
    /// up to a second after the byte, and the player checks again on each
    /// tick, so an outage is found 4 to 6 s after the last byte arrived.
    static let outageNoDataMs = 4_000
    /// A plan's rate needs at least this much receiving time.
    static let minReceivingMs = 1_000
    /// A tick this long after the one before, as after the app was suspended
    /// or the main thread held up, says nothing about how long its bytes
    /// took: it stays out of the rate.
    static let maxTickIntervalMs = 3_000

    /// The reader's total, when it was read and the interval before that
    /// (0 for a new reader or after a gap), and whether another reader of the
    /// source may have been receiving; nil while there is no reader.
    private var last: (bytes: Int64, atMs: Int, intervalMs: Int, shared: Bool)?
    /// When media data last arrived, or the reader appeared.
    private var lastDataAtMs: Int?

    // The playing plan's books.
    private var receivedBytes: Int64 = 0
    private var receivingMs = 0
    private var networkKey: String?
    private var networkChanged = false

    /// Takes one telemetry tick: the reader's lifetime total, or nil when the
    /// load has none. A total below the last one is a new reader. Bytes
    /// count toward the plan's rate only when `counts`: the playing plan's
    /// own source, not a replacement loading in its place; and only when
    /// neither this tick nor the one before was `shared`, with another reader
    /// of the source possibly receiving beside the counted one. True when
    /// media data arrived.
    @discardableResult
    mutating func note(
        totalBytes: Int64?,
        atMs now: Int,
        networkKey key: String,
        counts: Bool = true,
        shared: Bool = false
    ) -> Bool {
        if networkKey != nil, key != networkKey { networkChanged = true }
        guard let totalBytes else {
            last = nil
            lastDataAtMs = nil
            return false
        }
        guard let previous = last, totalBytes >= previous.bytes else {
            last = (totalBytes, now, 0, shared)
            lastDataAtMs = now
            return totalBytes > 0
        }
        let interval = max(0, now - previous.atMs)
        let inTime = interval <= Self.maxTickIntervalMs
        last = (totalBytes, now, inTime ? interval : 0, shared)
        let delta = totalBytes - previous.bytes
        guard delta > 0 else { return false }
        lastDataAtMs = now
        if counts, inTime, !shared, !previous.shared {
            receivedBytes += delta
            receivingMs += max(interval, previous.intervalMs)
        }
        return true
    }

    /// A plan was adopted: its books start empty on `networkKey`.
    mutating func planAdopted(networkKey key: String) {
        receivedBytes = 0
        receivingMs = 0
        networkKey = key
        networkChanged = false
    }

    /// The reader has received nothing for `OUTAGE_NO_DATA_MS`. False where
    /// there is no reader.
    func isSilent(atMs now: Int) -> Bool {
        guard last != nil, let lastDataAtMs else { return false }
        return now - lastDataAtMs >= Self.outageNoDataMs
    }

    /// The plan's `throughput_kbps`: the bytes it received over the time it
    /// spent receiving, once that reaches `minReceivingMs`. Nil when it has
    /// not, when the network changed under the plan, or below
    /// `MIN_ESTIMATE_KBPS`; capped at 1,000,000.
    var throughputKbps: Int? {
        guard !networkChanged, receivingMs >= Self.minReceivingMs else { return nil }
        return Self.reportable(kbps: receivedBytes * 8 / Int64(receivingMs))
    }

    /// A measured rate as the API takes it: nil below `MIN_ESTIMATE_KBPS`,
    /// capped at 1,000,000.
    static func reportable(kbps: Int64) -> Int? {
        guard kbps >= Int64(BufferingQualityController.minEstimateKbps) else { return nil }
        return Int(min(kbps, 1_000_000))
    }
}
