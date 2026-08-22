import Foundation

enum SubtitleCodecClassifier {
    private static let bitmapCodecs: Set<String> = [
        "hdmv_pgs_subtitle", "pgssub", "pgs",
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
}
