import Foundation

/// The file a detail page shows, and so the file Play and Download use.
/// Edition is the cut; Version is which of its files plays. Auto never
/// changes the cut. Web, Android and Roku resolve the same file for the
/// same inputs, so a rule change here needs the same change there.
enum DetailVersionSelection {
    /// The pinned file when the viewer picked one in Version. Otherwise Auto
    /// within the current edition: the one picked on the page (`editionId`),
    /// else the one last played (`lastEditionKey`, else the edition of
    /// `lastFileId`), else the edition whose Auto file compares best.
    ///
    /// While the item has a resume point (`lastFileInProgress`, from
    /// `LeafItemUserData.hasResumePoint`) and `lastFileId` is a later part of
    /// a multi-part presentation in the current edition, Auto stays on that
    /// part so Resume continues it. Otherwise a rewatch starts at part 1.
    static func displayVersion(
        versions: [FileVersion],
        selectedFileId: Int?,
        lastFileId: Int?,
        lastFileInProgress: Bool,
        preferredQualityId: String? = nil,
        editionId: String? = nil,
        lastEditionKey: String? = nil
    ) -> FileVersion? {
        if let selectedFileId,
           let selected = versions.first(where: { $0.fileId == selectedFileId }) {
            return selected
        }

        let cap = qualityCap(preferredQualityId)
        let editions = PlaybackEditions.editions(from: versions)
        let current = PlaybackEditions.edition(forKey: editionId, in: versions)
            ?? lastPlayedEdition(lastEditionKey, in: editions)
            ?? PlaybackEditions.edition(forFileId: lastFileId, in: versions)
        guard let current else {
            return openingFile(editions: editions, cap: cap)
        }
        if lastFileInProgress,
           let lastFileId,
           let last = current.versions.first(where: { $0.fileId == lastFileId }),
           (last.presentationPartIndex ?? 0) > 1 {
            return last
        }
        return autoFile(in: current.versions, cap: cap)
    }

    /// What a page's Play sends.
    struct PageStart: Equatable {
        let fileId: Int?
        let audioTrackIndex: Int?
        let subtitleTrackIndex: Int?
    }

    /// The start for a page's Play. The page shows Auto for its snapshot
    /// (`shownWith`), and the track picks name streams of that file. Play
    /// resolves Auto again for the watch state its resume position came
    /// from (`startsWith`), so a multipart position is applied to its own
    /// part, and Start Over moves a later part to part 1. When that start
    /// file is not the one shown, the track picks are dropped (Off stays)
    /// and the file's tracks resolve as on any fresh start.
    static func pageStart(
        versions: [FileVersion],
        pinnedFileId: Int?,
        editionId: String?,
        shownWith snapshot: LeafItemUserData?,
        startsWith watchState: LeafItemUserData?,
        preferredQualityId: String?,
        startFromBeginning: Bool,
        audioTrackIndex: Int?,
        subtitleTrackIndex: Int?
    ) -> PageStart {
        func auto(_ userData: LeafItemUserData?) -> FileVersion? {
            displayVersion(
                versions: versions,
                selectedFileId: pinnedFileId,
                lastFileId: userData?.lastFileId,
                lastFileInProgress: userData?.hasResumePoint ?? false,
                preferredQualityId: preferredQualityId,
                editionId: editionId,
                lastEditionKey: userData?.lastEditionKey
            )
        }
        let shown = auto(snapshot)
        guard let start = startFile(
            auto(watchState),
            startFromBeginning: startFromBeginning,
            pinned: pinnedFileId != nil,
            in: versions
        ) else {
            return PageStart(fileId: nil, audioTrackIndex: nil, subtitleTrackIndex: nil)
        }
        guard start.fileId != shown?.fileId else {
            return PageStart(
                fileId: start.fileId,
                audioTrackIndex: audioTrackIndex,
                subtitleTrackIndex: subtitleTrackIndex
            )
        }
        return PageStart(
            fileId: start.fileId,
            audioTrackIndex: nil,
            subtitleTrackIndex: DetailPlaybackFormatting.subtitleIndexAfterFileChange(subtitleTrackIndex) { nil }
        )
    }

    /// The file Play starts: `resolved`, except that Start Over on a later
    /// part Auto resumed starts that presentation's first part.
    private static func startFile(
        _ shown: FileVersion?,
        startFromBeginning: Bool,
        pinned: Bool,
        in versions: [FileVersion]
    ) -> FileVersion? {
        guard startFromBeginning, !pinned, let shown else { return shown }
        return PlayerMultipartPolicy.firstPart(for: shown, in: versions) ?? shown
    }

    /// Auto within one edition: the first known-resolution first-part file
    /// in server order that fits the cap, else the closest one above it. A
    /// file of unknown resolution plays only when nothing else can.
    private static func autoFile(in files: [FileVersion], cap: Int?) -> FileVersion? {
        let firstParts = files.filter { ($0.presentationPartIndex ?? 1) <= 1 }
        let candidates = serverOrder(firstParts.isEmpty ? files : firstParts)
        let known = candidates.filter { resolutionRank($0.resolution) > 0 }
        guard !known.isEmpty else { return candidates.first }
        guard let cap else { return known.first }
        if let fits = known.first(where: { resolutionRank($0.resolution) <= cap }) {
            return fits
        }
        let lowest = known.map { resolutionRank($0.resolution) }.min()
        return known.first { resolutionRank($0.resolution) == lowest }
    }

    /// With no history, each edition's Auto file competes: fitting the cap
    /// beats above it beats unknown; then the higher rank (the lower one
    /// above the cap); then HDR; then the standard cut, then a theatrical
    /// one; then server order. File size is not compared across cuts.
    private static func openingFile(editions: [PlaybackEditions.Edition], cap: Int?) -> FileVersion? {
        let picks = editions.enumerated().compactMap { order, edition in
            autoFile(in: edition.versions, cap: cap).map { (file: $0, edition: edition, order: order) }
        }
        func key(_ pick: (file: FileVersion, edition: PlaybackEditions.Edition, order: Int)) -> [Int] {
            let rank = resolutionRank(pick.file.resolution)
            let fit: Int
            if rank == 0 {
                fit = 2
            } else if let cap, rank > cap {
                fit = 1
            } else {
                fit = 0
            }
            return [
                fit,
                fit == 1 ? rank : -rank,
                pick.file.hdr == true ? 0 : 1,
                editionPreference(pick.edition),
                pick.order,
            ]
        }
        return picks.min { key($0).lexicographicallyPrecedes(key($1)) }?.file
    }

    /// 0 for the unnamed or standard cut, 1 for a theatrical one, 2 otherwise.
    private static func editionPreference(_ edition: PlaybackEditions.Edition) -> Int {
        let file = edition.versions.first
        let values = [file?.editionKey, file?.editionRaw]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        if values.isEmpty || values.contains(where: {
            $0 == "standard" || $0 == "default" || $0.hasPrefix("standard ") || $0.hasSuffix(" standard")
        }) {
            return 0
        }
        return values.contains { $0.contains("theatrical") } ? 1 : 2
    }

    /// The edition `last_edition_key` names. A present empty key names the
    /// unnamed edition.
    private static func lastPlayedEdition(
        _ key: String?,
        in editions: [PlaybackEditions.Edition]
    ) -> PlaybackEditions.Edition? {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        guard key.isEmpty else { return editions.first { $0.id == key } }
        return editions.first { edition in
            (edition.versions.first?.editionKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The server's file order (`sortFileVersions`): rank, then HDR, then
    /// the larger file, then list order.
    private static func serverOrder(_ files: [FileVersion]) -> [FileVersion] {
        files.enumerated().sorted { a, b in
            let rankA = resolutionRank(a.element.resolution)
            let rankB = resolutionRank(b.element.resolution)
            if rankA != rankB { return rankA > rankB }
            let hdrA = a.element.hdr == true
            let hdrB = b.element.hdr == true
            if hdrA != hdrB { return hdrA }
            let sizeA = a.element.fileSize ?? 0
            let sizeB = b.element.fileSize ?? 0
            if sizeA != sizeB { return sizeA > sizeB }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The quality as a resolution rank, or nil when it caps nothing: Auto,
    /// 4K, and anything whose resolution is unknown. An id outside the
    /// Settings list, such as a rung picked in the player (`1080p-low`),
    /// caps by the resolution it names.
    private static func qualityCap(_ quality: String?) -> Int? {
        let id = ApplePlaybackQuality.normalizeStoredId(quality)
        guard id != ApplePlaybackQuality.ultraHDId else { return nil }
        let resolution: String
        if id != ApplePlaybackQuality.autoId {
            resolution = AppleQualityAxes.split(id).resolution
        } else {
            let rung = ApplePlaybackQuality.protocolV3QualityId(quality)
            resolution = rung.split(separator: "-").first.map(String.init) ?? rung
        }
        let rank = resolutionRank(resolution)
        return rank > 0 ? rank : nil
    }

    /// The server's resolution rank (`internal/access/quality.go`), plus the
    /// 4k and 8k spellings. Anything else is unknown (0).
    private static func resolutionRank(_ value: String?) -> Int {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "480p": return 1
        case "720p": return 2
        case "1080p": return 3
        case "2160p", "4k": return 4
        case "4320p", "8k": return 5
        default: return 0
        }
    }
}
