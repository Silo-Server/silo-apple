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
/// A tick that saw bytes counts as receiving for its whole interval, so the
/// rate is a lower bound: a reader that filled its window in part of a second
/// and then parked reads low, never high. It holds no clock and performs no
/// I/O.
struct UpstreamReadMeter {
    /// `OUTAGE_NO_DATA_MS`: a wait with no media data for this long is an
    /// outage, counted from the last byte.
    static let outageNoDataMs = 4_000
    /// A plan's rate needs at least this much receiving time.
    static let minReceivingMs = 1_000

    /// The reader's total and when it was read; nil while there is no reader.
    private var last: (bytes: Int64, atMs: Int)?
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
    /// own source, not a replacement loading in its place. True when media
    /// data arrived.
    @discardableResult
    mutating func note(totalBytes: Int64?, atMs now: Int, networkKey key: String, counts: Bool = true) -> Bool {
        if networkKey != nil, key != networkKey { networkChanged = true }
        guard let totalBytes else {
            last = nil
            lastDataAtMs = nil
            return false
        }
        guard let previous = last, totalBytes >= previous.bytes else {
            last = (totalBytes, now)
            lastDataAtMs = now
            return totalBytes > 0
        }
        last = (totalBytes, now)
        let delta = totalBytes - previous.bytes
        guard delta > 0 else { return false }
        lastDataAtMs = now
        if counts {
            receivedBytes += delta
            receivingMs += max(0, now - previous.atMs)
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
        let kbps = receivedBytes * 8 / Int64(receivingMs)
        guard kbps >= Int64(BufferingQualityController.minEstimateKbps) else { return nil }
        return Int(min(kbps, 1_000_000))
    }
}
