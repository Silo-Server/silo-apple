import Foundation

/// The technical details of one file version, as the label and value rows
/// of the title page's Media Info section.
///
/// A video or file row appears only when the server sent its value. A file
/// the server never probed arrives with "" and 0 in its required fields, so
/// empty text and numbers that are not positive count as missing.
enum DetailMediaInfo {
    /// Resolution, video, dynamic range, bit depth, frame rate, container,
    /// size and bitrate, in that order.
    static func videoAndFileFacts(
        _ version: FileVersion,
        locale: Locale = AppLanguage.displayedLocale
    ) -> [DetailFacts.Fact] {
        let track = version.videoTracks?.first
        var facts: [DetailFacts.Fact] = []
        func text(_ resource: LocalizedStringResource) -> String {
            AppLanguage.string(resource, locale: locale)
        }
        func add(_ label: LocalizedStringResource, _ value: String?) {
            guard let value else { return }
            facts.append(DetailFacts.Fact(label: text(label), value: value))
        }

        add(.filtersFacetResolution, TrackLabels.nonEmpty(version.resolution))
        add(.playerHudVideo, videoSummary(version, track: track))
        add(.playerStatsDynamicRange, dynamicRange(version, track: track, locale: locale))
        if let depth = track?.bitDepth, depth > 0 {
            let depthText = LocaleFormat.integer(depth, locale: locale)
            add(.webDetailMediaInfoRowBitDepthLabel, text(.webDetailMediaInfoBitDepth(depthText)))
        }
        // The server writes the rate as text: "23.976", "24.000".
        if let rate = TrackLabels.nonEmpty(track?.frameRate).flatMap({ Double($0) }), rate.isFinite, rate > 0 {
            let rateText = LocaleFormat.trimmed(rate, maxFractionDigits: 3, locale: locale)
            add(.webDetailMediaInfoRowFrameRateLabel, text(.webDetailMediaInfoFrameRate(rateText)))
        }
        add(.playerStatsContainer, TrackLabels.nonEmpty(version.container)?.uppercased())
        if let size = version.fileSize, size > 0 {
            add(.downloadsOfflineDetailFactSize, LocaleFormat.bytes(size, megabytesAndUp: true, locale: locale))
        }
        // Kilobits per second in the item detail and the watch detail alike,
        // as the scanner stores it.
        if let bitrate = version.bitrate, bitrate > 0 {
            add(.webDetailMediaInfoRowBitrate, ApplePlaybackQuality.formatBitrate(kbps: bitrate, locale: locale))
        }
        return facts
    }

    /// One row per audio track. The label is the track's language, or
    /// "Track 2" for a track without one. The value is what the audio picker
    /// says about it: its title when that adds to the label, then the codec,
    /// the channel layout and the file's default marker. The picker's
    /// formatters resolve the app's language themselves.
    static func audioFacts(_ version: FileVersion) -> [DetailFacts.Fact] {
        (version.audioTracks ?? []).enumerated().map { ordinal, track in
            // The picker's name: the language, else the title, else "Track 2".
            let name = DetailPlaybackFormatting.audioTitle(track, ordinal: ordinal)
            // No version: "Preferred" marks the profile's pick, not the file.
            let detail = DetailPlaybackFormatting.audioDetail(track, ordinal: ordinal, version: nil)
            let number = AppLanguage.string(.detailTrack(LocaleFormat.integer(ordinal + 1)))
            guard TrackLabels.languageName(track.language) == nil, name != number else {
                return DetailFacts.Fact(label: name, value: detail)
            }
            // A title standing in for the language is too long for the label
            // column, so it leads the value instead.
            let value = [name, detail].filter { !$0.isEmpty }.joined(separator: " · ")
            return DetailFacts.Fact(label: number, value: value)
        }
    }

    /// "HEVC · Main 10": the codec, then its profile.
    private static func videoSummary(_ version: FileVersion, track: VideoTrack?) -> String? {
        let tokens = [
            DetailPlaybackFormatting.normalizedVideoCodec(TrackLabels.nonEmpty(version.codecVideo)),
            TrackLabels.nonEmpty(track?.profile),
        ].compactMap { $0 }
        return tokens.isEmpty ? nil : tokens.joined(separator: " · ")
    }

    /// "Dolby Vision Profile 8", "HDR10", "HLG", or "HDR" when the server
    /// says no more than that; HDR10+ stands alone or follows Dolby Vision.
    /// Nil for SDR.
    private static func dynamicRange(_ version: FileVersion, track: VideoTrack?, locale: Locale) -> String? {
        // The server's class of the range: "HDR10", "HDR10Plus", "HLG",
        // "DOVIWithHDR10", … Older rows differ in case.
        let rangeClass = TrackLabels.nonEmpty(track?.videoRangeType)?.lowercased() ?? ""
        let hasHDR10Plus = track?.hdr10Plus == true || rangeClass.hasSuffix("hdr10plus")
        let range: String?
        if let dolbyVision = TrackLabels.nonEmpty(track?.dolbyVision) {
            // The server writes "Profile 8".
            if let profile = dolbyVision.split(separator: " ").last.flatMap({ Int($0) }) {
                let number = LocaleFormat.codeNumber(profile)
                range = AppLanguage.string(.playerStatsDolbyVisionProfile(number), locale: locale)
            } else {
                range = "Dolby Vision" // i18n-ignore: format brand name
            }
        } else if rangeClass.hasPrefix("dovi") {
            // An older row can name Dolby Vision only in its class.
            range = "Dolby Vision" // i18n-ignore: format brand name
        } else if hasHDR10Plus {
            range = nil
        } else if rangeClass == "hdr10" {
            range = "HDR10" // i18n-ignore: technical token
        } else if rangeClass == "hlg" {
            range = "HLG" // i18n-ignore: technical token
        } else {
            range = version.hdr == true ? "HDR" : nil // i18n-ignore: technical token
        }
        let tokens = [range, hasHDR10Plus ? "HDR10+" : nil].compactMap { $0 } // i18n-ignore: technical token
        return tokens.isEmpty ? nil : tokens.joined(separator: " · ")
    }
}
