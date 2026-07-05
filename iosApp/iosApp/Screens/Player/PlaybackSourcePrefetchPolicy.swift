import Foundation

enum PlaybackSourcePrefetchPolicy {
    static func initialOffset(
        sourceStartTimeSeconds: Double,
        sourceBitrateBps: Double?
    ) -> Int64 {
        guard sourceStartTimeSeconds.isFinite,
              sourceStartTimeSeconds > 0,
              let sourceBitrateBps,
              sourceBitrateBps.isFinite,
              sourceBitrateBps > 0 else {
            return 0
        }

        let offset = (sourceStartTimeSeconds * sourceBitrateBps / 8).rounded(.down)
        guard offset.isFinite, offset > 0 else { return 0 }

        return Int64(min(offset, Double(Int64.max - 1)))
    }
}
