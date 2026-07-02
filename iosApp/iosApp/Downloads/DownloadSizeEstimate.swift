#if !os(tvOS)
import Foundation

/// Pre-flight size expectation for a download. When the user picks Auto the
/// server resolves the actual file, so the only honest disclosure is the
/// min–max range across the item's candidate versions; a chosen version is
/// exact. Sizes come from the catalog's original-file metadata, so for
/// transcoded qualities the estimate is an upper bound.
struct DownloadSizeEstimate {
    /// Downloads past this point warrant an explicit confirmation before the
    /// one-tap path proceeds. Decimal bytes so the threshold lines up with
    /// the `ByteCountFormatter` display ("5 GB", not 5 GiB).
    static let largeDownloadThresholdBytes: Int64 = 5_000_000_000

    let minBytes: Int64
    let maxBytes: Int64
    /// True when the estimate spans multiple candidate files (Auto with
    /// differing sizes); false means `maxBytes` is the exact file size.
    let isRange: Bool

    /// `nil` when the catalog reports no usable sizes — there is nothing
    /// truthful to disclose or guard against.
    static func estimate(versions: [FileVersion], fileId: Int?) -> DownloadSizeEstimate? {
        if let fileId {
            guard let size = versions.first(where: { $0.fileId == fileId })?.fileSize,
                  size > 0 else { return nil }
            return DownloadSizeEstimate(minBytes: size, maxBytes: size, isRange: false)
        }
        return estimate(fileSizes: versions.compactMap(\.fileSize))
    }

    /// Auto-quality disclosure from bare candidate sizes — episode cards only
    /// carry `EpisodeFile` metadata, not full versions, and their one-tap path
    /// never pins a specific file.
    static func estimate(fileSizes: [Int64]) -> DownloadSizeEstimate? {
        let sizes = fileSizes.filter { $0 > 0 }
        guard let smallest = sizes.min(), let largest = sizes.max() else { return nil }
        return DownloadSizeEstimate(
            minBytes: smallest,
            maxBytes: largest,
            isRange: smallest != largest
        )
    }

    /// "2.1–5.4 GB" for a range, "5.4 GB" when exact.
    var sizeLabel: String {
        guard isRange else { return DownloadFormatting.bytes(maxBytes) }
        return "\(DownloadFormatting.bytes(minBytes))–\(DownloadFormatting.bytes(maxBytes))"
    }

    var exceedsLargeThreshold: Bool { maxBytes > Self.largeDownloadThresholdBytes }

    /// Available space of 0 means the volume lookup failed, not a full disk,
    /// so it never triggers the insufficient-space warning.
    func exceedsAvailableSpace(_ availableBytes: Int64) -> Bool {
        availableBytes > 0 && maxBytes > availableBytes
    }

    /// Warning copy shared by the one-tap confirmation dialog and the
    /// options-sheet footer; `nil` when the size needs no caveat. The guard
    /// uses `maxBytes` because Auto commits the user to whichever candidate
    /// the server picks.
    func warningMessage(availableBytes: Int64) -> String? {
        let size = DownloadFormatting.bytes(maxBytes)
        if exceedsAvailableSpace(availableBytes) {
            let free = DownloadFormatting.bytes(availableBytes)
            return isRange
                ? "This download may be up to \(size), but only \(free) is free on this device."
                : "This download is \(size), but only \(free) is free on this device."
        }
        if exceedsLargeThreshold {
            return isRange
                ? "This download may be up to \(size)."
                : "This download is \(size)."
        }
        return nil
    }
}
#endif
