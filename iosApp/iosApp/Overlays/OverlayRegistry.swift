import Foundation

/// Single source of truth for which overlays exist. Order within the
/// array determines the default render order within each corner. The
/// entries here mirror `web/src/lib/overlays/registry/*.ts` and the
/// contract's `card-overlays.json` id enum — adding/removing one here
/// MUST be mirrored there, and in the `OverlayId` enum, or stored
/// prefs from one platform will silently drop on another. (The two
/// planned ribbon ids, `imdb_top_250` and `rt_certified_fresh`, are
/// schema-legal but not yet in the web registry.)
enum OverlayRegistry {

    static let all: [OverlayDef] = tech + ratings + metadata + ribbons

    /// Whether `id` should be hidden because another enabled overlay
    /// already displays the same information. The combined
    /// `resolution_hdr` badge subsumes the standalone `resolution` and
    /// `hdr` badges — without this, enabling the combined view on top
    /// of the defaults produces "4K HDR 4K HDR" stacks. The user's
    /// stored prefs are left untouched so toggling the combined badge
    /// off restores the standalones automatically.
    static func isSuppressed(_ id: OverlayId, by prefs: CardOverlayPrefs) -> Bool {
        switch id {
        case .resolution, .hdr:
            return prefs.items[.resolutionHdr]?.enabled == true
        default:
            return false
        }
    }

    /// Enabled overlays for a corner, in the user's chosen order. Any
    /// overlay not listed in `prefs.order` falls back to registry order
    /// (preserved deterministically via a secondary index, since
    /// `sorted` is not guaranteed stable).
    ///
    /// Duplicate IDs in `prefs.order` — possible when the wire JSON was
    /// hand-edited or written by an older client — are tolerated: the
    /// first occurrence wins, later ones are dropped, no trap.
    static func enabled(at position: OverlayPosition, in prefs: CardOverlayPrefs) -> [OverlayDef] {
        let candidates = all.enumerated().filter { _, def in
            guard let cfg = prefs.items[def.id] else { return false }
            if isSuppressed(def.id, by: prefs) { return false }
            return cfg.enabled && cfg.position == position
        }
        if prefs.order.isEmpty { return candidates.map(\.element) }

        // `uniquingKeysWith` keeps the first index a given ID appears
        // at, so a malformed `order` like `[a, b, a]` doesn't trap.
        let rank: [OverlayId: Int] = Dictionary(
            prefs.order.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return candidates
            .sorted { lhs, rhs in
                let lhsRank = rank[lhs.element.id] ?? Int.max
                let rhsRank = rank[rhs.element.id] ?? Int.max
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                // Equal ranks (typically both unranked at Int.max) →
                // fall back to registry order.
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

// MARK: - Tech

private extension OverlayRegistry {

    static func prettyResolution(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let v = value.lowercased()
        switch v {
        case "2160p", "4k", "uhd": return "4K"
        case "4320p", "8k":         return "8K"
        default:
            if v.range(of: #"^\d+p$"#, options: .regularExpression) != nil {
                return v
            }
            return value.uppercased()
        }
    }

    static func compactHdrSuffix(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value.contains("DV") ? "DV" : "HDR"
    }

    /// Mirrors web's `hdrIcon`: only exact wordmark matches get a brand
    /// mark; anything else (HLG, combined strings like "HDR10+") renders
    /// as plain text with no icon rather than a wrong generic mark.
    static func hdrIcon(_ value: String?) -> OverlayIconId? {
        guard let value, !value.isEmpty else { return nil }
        if value.contains("DV") { return .dolbyVision }
        if value == "HDR10" { return .hdr10 }
        if value == "HDR" { return .hdr }
        return nil
    }

    /// The combined badge's label already carries an "HDR" suffix, so the
    /// only icon worth doubling up is the Dolby Vision mark — mirrors
    /// web's `resolution_hdr.getIcon`.
    static func resolutionHdrIcon(_ value: String?) -> OverlayIconId? {
        guard let value, value.contains("DV") else { return nil }
        return .dolbyVision
    }

    static func audioIcon(_ value: String?) -> OverlayIconId? {
        guard let value, !value.isEmpty else { return nil }
        // `contains` instead of equality so "TrueHD Atmos" / "Dolby
        // TrueHD Atmos" (Blu-ray remux labelling) still picks the brand
        // mark. The server normalizes most strings to plain "Atmos",
        // but some passthrough surfaces preserve the upstream label.
        return value.lowercased().contains("atmos") ? .atmos : .volume
    }

    static func videoCodecIcon(_ value: String?) -> OverlayIconId? {
        guard let value, !value.isEmpty else { return nil }
        return value == "AV1" ? .av1 : .film
    }

    static let tech: [OverlayDef] = [
        OverlayDef(
            id: .resolution,
            defaultPosition: .topLeft,
            defaultEnabled: true,
            iconId: .monitor,
            iconCapable: true,
            // `prettyResolution`, not raw uppercase: web renders "4K" for a
            // `2160p` payload and the standalone badge must match it.
            getValue: { prettyResolution($0.resolution) }
        ),
        OverlayDef(
            id: .hdr,
            defaultPosition: .topLeft,
            defaultEnabled: true,
            iconCapable: true,
            getValue: { $0.hdr },
            getIcon: { hdrIcon($0.hdr) }
        ),
        OverlayDef(
            id: .resolutionHdr,
            defaultPosition: .topLeft,
            defaultEnabled: false,
            iconCapable: true,
            getValue: { data in
                guard let res = prettyResolution(data.resolution) else { return nil }
                if let hdr = compactHdrSuffix(data.hdr) { return "\(res) \(hdr)" }
                return res
            },
            getIcon: { resolutionHdrIcon($0.hdr) }
        ),
        OverlayDef(
            id: .audio,
            defaultPosition: .topLeft,
            defaultEnabled: true,
            iconCapable: true,
            getValue: { $0.audio },
            getIcon: { audioIcon($0.audio) }
        ),
        OverlayDef(
            id: .audioChannels,
            defaultPosition: .topLeft,
            defaultEnabled: false,
            iconId: .volume,
            iconCapable: true,
            getValue: { $0.audioChannels }
        ),
        OverlayDef(
            id: .videoCodec,
            defaultPosition: .topLeft,
            defaultEnabled: false,
            iconId: .film,
            iconCapable: true,
            getValue: { $0.videoCodec },
            getIcon: { videoCodecIcon($0.videoCodec) }
        ),
        OverlayDef(
            id: .container,
            defaultPosition: .bottomLeft,
            defaultEnabled: false,
            iconCapable: false,
            getValue: { $0.container }
        ),
        OverlayDef(
            id: .aspectRatio,
            defaultPosition: .bottomRight,
            defaultEnabled: false,
            iconId: .layout,
            iconCapable: true,
            getValue: { $0.aspectRatio }
        ),
        OverlayDef(
            id: .releaseType,
            defaultPosition: .bottomLeft,
            defaultEnabled: true,
            iconCapable: false,
            getValue: { $0.releaseType }
        ),
        OverlayDef(
            id: .edition,
            defaultPosition: .bottomLeft,
            defaultEnabled: false,
            iconCapable: false,
            getValue: { $0.edition }
        ),
        OverlayDef(
            id: .multiAudio,
            defaultPosition: .bottomRight,
            defaultEnabled: false,
            iconId: .languages,
            iconCapable: true,
            getValue: { ($0.multiAudio == true) ? "Multi-Audio" : nil }
        ),
        OverlayDef(
            id: .multiSub,
            defaultPosition: .bottomRight,
            defaultEnabled: false,
            iconId: .subtitles,
            iconCapable: true,
            getValue: { ($0.multiSub == true) ? "CC" : nil }
        ),
    ]
}

// MARK: - Ratings

private extension OverlayRegistry {

    static func formatRating(_ value: Double?) -> String? {
        value.map { String(format: "%.1f", $0) }
    }

    static func formatPercent(_ value: Int?) -> String? {
        value.map { "\($0)%" }
    }

    static let ratings: [OverlayDef] = [
        OverlayDef(
            id: .ratingImdb,
            defaultPosition: .topRight,
            defaultEnabled: false,
            iconId: .star,
            defaultAccent: "#f5c518",
            iconCapable: true,
            getValue: { formatRating($0.ratingImdb) }
        ),
        OverlayDef(
            id: .ratingTmdb,
            defaultPosition: .topRight,
            defaultEnabled: false,
            iconId: .star,
            defaultAccent: "#01b4e4",
            iconCapable: true,
            getValue: { formatRating($0.ratingTmdb) }
        ),
        OverlayDef(
            id: .ratingRt,
            defaultPosition: .topRight,
            defaultEnabled: false,
            iconId: .tomato,
            defaultAccent: "#fa320a",
            iconCapable: true,
            getValue: { formatPercent($0.ratingRtCritic) }
        ),
        OverlayDef(
            id: .ratingRtAudience,
            defaultPosition: .topRight,
            defaultEnabled: false,
            iconId: .tomato,
            defaultAccent: "#fa6400",
            iconCapable: true,
            getValue: { formatPercent($0.ratingRtAudience) }
        ),
        OverlayDef(
            id: .contentRating,
            defaultPosition: .bottomRight,
            defaultEnabled: false,
            iconId: .shield,
            iconCapable: true,
            getValue: { $0.contentRating }
        ),
    ]
}

// MARK: - Metadata

private extension OverlayRegistry {

    static func formatRuntime(_ minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        let h = minutes / 60
        let m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    /// English display name for a language tag, matching web's
    /// `formatLanguage` (English CLDR names, so "en" → "English" not
    /// "EN"). A tag CLDR can't name falls back to the uppercased code
    /// rather than web's "Unknown language (…)" sentence, which doesn't
    /// fit a badge.
    static func formatLanguageName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let english = Locale(identifier: "en")
        let name = english.localizedString(forIdentifier: trimmed)
            ?? english.localizedString(forLanguageCode: trimmed)
        return name?.capitalized ?? trimmed.uppercased()
    }

    static let metadata: [OverlayDef] = [
        OverlayDef(
            id: .year,
            defaultPosition: .bottomLeft,
            defaultEnabled: false,
            iconCapable: false,
            getValue: { data in
                guard let year = data.year, year > 0 else { return nil }
                return String(year)
            }
        ),
        OverlayDef(
            id: .runtime,
            defaultPosition: .bottomLeft,
            defaultEnabled: false,
            iconId: .clock,
            iconCapable: true,
            getValue: { formatRuntime($0.runtime) }
        ),
        OverlayDef(
            id: .originalLanguage,
            defaultPosition: .bottomLeft,
            defaultEnabled: false,
            iconId: .globe,
            iconCapable: true,
            getValue: { formatLanguageName($0.originalLanguage) }
        ),
        OverlayDef(
            id: .studio,
            defaultPosition: .bottomRight,
            defaultEnabled: false,
            iconId: .building,
            iconCapable: true,
            getValue: { $0.studio }
        ),
        OverlayDef(
            id: .network,
            defaultPosition: .bottomRight,
            defaultEnabled: false,
            iconId: .tv,
            iconCapable: true,
            getValue: { $0.network }
        ),
    ]
}

// MARK: - Ribbons

private extension OverlayRegistry {

    /// Mirrors web's `formatShowStatus` — the recognized spellings and
    /// the pass-through default must stay identical or the same library
    /// renders different ribbons per platform.
    static func formatShowStatus(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        switch value.lowercased() {
        case "returning", "returning series", "continuing", "in_production", "in production":
            return "Returning"
        case "ended":
            return "Ended"
        case "cancelled", "canceled":
            return "Cancelled"
        case "upcoming", "planned":
            return "Upcoming"
        default:
            return value
        }
    }

    static let ribbons: [OverlayDef] = [
        OverlayDef(
            id: .showStatus,
            defaultPosition: .topRight,
            defaultEnabled: false,
            iconId: .tv,
            iconCapable: true,
            getValue: { formatShowStatus($0.showStatus) }
        ),
        OverlayDef(
            id: .imdbTop250,
            defaultPosition: .topRight,
            defaultEnabled: false,
            iconId: .ribbon,
            defaultAccent: "#f5c518",
            iconCapable: true,
            getValue: { data in
                guard let rank = data.imdbTop250 else { return nil }
                return "#\(rank)"
            }
        ),
        OverlayDef(
            id: .rtCertifiedFresh,
            defaultPosition: .topRight,
            defaultEnabled: false,
            iconId: .tomato,
            defaultAccent: "#fa320a",
            iconCapable: true,
            getValue: { $0.rtCertifiedFresh == true ? "Certified Fresh" : nil }
        ),
    ]
}
