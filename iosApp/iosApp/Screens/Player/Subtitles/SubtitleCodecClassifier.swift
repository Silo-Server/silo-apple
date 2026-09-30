import Foundation

enum SubtitleCodecClassifier {
    /// `sup` is the PGS elementary-stream file format: offline manifests
    /// name PGS sidecars by it, so it classifies as PGS.
    private static let bitmapCodecs: Set<String> = [
        "hdmv_pgs_subtitle", "pgssub", "pgs", "sup",
        "dvd_subtitle", "dvdsub", "vobsub",
        "dvb_subtitle", "dvbsub", "xsub",
    ]

    static func isBitmap(_ rawCodec: String?) -> Bool {
        guard let codec = rawCodec?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !codec.isEmpty else { return false }
        return bitmapCodecs.contains(codec)
            || codec.contains("pgs")
            || codec.contains("dvdsub")
            || codec.contains("dvd_sub")
            || codec.contains("dvbsub")
            || codec.contains("dvb_sub")
            || codec.contains("vobsub")
    }

    /// The codec to publish for a host-registered sidecar. AetherEngine names
    /// an external track from its format hint and reports "subrip" for any
    /// hint it does not know, including `sup`; the declared format is the
    /// truth there, so a PGS sidecar still classifies and ranks as bitmap.
    static func externalTrackCodec(engineCodec: String?, declaredFormat: String?) -> String? {
        guard engineCodec?.lowercased() == "subrip",
              let declared = declaredFormat?
                  .trimmingCharacters(in: .whitespacesAndNewlines)
                  .lowercased(),
              !declared.isEmpty,
              !["srt", "subrip"].contains(declared) else {
            return engineCodec
        }
        return declared
    }
}
