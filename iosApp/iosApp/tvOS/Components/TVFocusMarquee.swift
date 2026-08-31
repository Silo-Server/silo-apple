import Foundation

/// Pure artwork selection for the tvOS focus hero. Kept outside the tvOS
/// compilation guard so the iOS-hosted unit tests can exercise the transition
/// from section data to detail enrichment.
struct TVHeroArtwork: Equatable {
    let url: String
    let thumbhash: String?

    init?(url: String?, thumbhash: String?) {
        guard let url, !url.isEmpty else { return nil }
        self.url = url
        self.thumbhash = thumbhash
    }
}

enum TVHeroEnrichmentState: Equatable {
    case notStarted
    case loading
    case completed
    case failed

    var permitsFallback: Bool {
        self == .completed || self == .failed
    }
}

enum TVHeroArtworkResolver {
    static func resolve(
        sectionBackdrop: TVHeroArtwork?,
        fallback: TVHeroArtwork?,
        prefersEnrichedBackdrop: Bool,
        canLoadEnrichment: Bool,
        enrichmentState: TVHeroEnrichmentState,
        enrichedBackdrop: TVHeroArtwork?
    ) -> TVHeroArtwork? {
        if !prefersEnrichedBackdrop, let sectionBackdrop {
            return sectionBackdrop
        }

        guard canLoadEnrichment else {
            return sectionBackdrop ?? fallback
        }
        guard enrichmentState.permitsFallback else {
            // Do not paint the poster while detail enrichment is in flight:
            // that creates a conspicuous portrait-to-landscape flash. The
            // first image displayed should be the real backdrop.
            return nil
        }
        return enrichedBackdrop ?? sectionBackdrop ?? fallback
    }
}

#if os(tvOS)
import SwiftUI
import Nuke

// MARK: - Content payload

/// Display payload for the focus marquee (§5.4/§5.5), built from
/// section-item models only (§9): render whatever synopsis/badge/runtime
/// fields the payload already carries, omit what's missing, and never
/// block on a per-item detail fetch.
struct TVMarqueeContent: Equatable {
    /// Crossfade identity. Includes the source row so the same item
    /// focused from a different row still reads as a swap.
    let id: String
    /// The previewed item's content id — keys the low-priority detail
    /// enrichment (§9 backfill). `nil` for collections.
    let contentId: String?
    /// The source row's title (`Continue Watching`). Not rendered — the
    /// row's own header names the source — but kept for the VoiceOver
    /// description and crossfade identity.
    let eyebrow: String
    let title: String
    /// Optional server logo art that may replace the text title once
    /// cached — the title always renders as text first.
    let logoUrl: String?
    /// Codec/HDR + content-rating chips (`4K · DOLBY VISION · ATMOS · TV-MA`).
    let badges: [String]
    /// Dot-joined meta tokens after the badges: year · genre · runtime,
    /// or `S2 E7 · episode title · 45 min · 23 min left` for episodes.
    let metaParts: [String]
    let synopsis: String?
    /// A genuine landscape backdrop from the section payload. This must stay
    /// separate from the poster fallback so the hero can wait for detail
    /// enrichment without briefly painting a portrait poster first.
    let backdropUrl: String?
    let backdropThumbhash: String?
    let fallbackArtworkUrl: String?
    let fallbackArtworkThumbhash: String?
    /// Episodes carry only their low-res still in the section payload, so the
    /// root hero upgrades to the series backdrop from detail enrichment rather
    /// than blowing the still up full-width.
    let isEpisode: Bool
}

extension TVMarqueeContent {
    init(item: SectionItem, rowTitle: String) {
        let isEpisode = item.type.lowercased() == "episode"

        var meta: [String] = []
        if isEpisode {
            if let token = Self.episodeToken(season: item.seasonNumber, episode: item.episodeNumber) {
                meta.append(token)
            }
            meta.append(item.title)
            if let length = Self.lengthText(runtimeMinutes: item.runtime, durationSeconds: item.durationSeconds) {
                meta.append(length)
            }
            if let timeLeft = Self.timeLeftText(position: item.positionSeconds, duration: item.durationSeconds) {
                meta.append(timeLeft)
            }
        } else {
            if let year = item.year, year > 0 { meta.append(String(year)) }
            if let genre = item.genres?.first(where: { !$0.isEmpty }) { meta.append(genre) }
            if let length = Self.lengthText(runtimeMinutes: item.runtime, durationSeconds: item.durationSeconds) {
                meta.append(length)
            }
            if let rating = item.ratingImdb { meta.append(String(format: "%.1f", rating)) }
        }

        var badges = Self.badges(from: item.overlaySummary)
        if let contentRating = Self.nonEmpty(item.contentRating) {
            badges.append(contentRating.uppercased())
        }

        self.init(
            id: "\(rowTitle)#\(item.contentId)",
            contentId: item.contentId,
            eyebrow: rowTitle,
            // Episodes headline with their series (`SEVERANCE`); the
            // episode itself moves to the meta line per §5.4.
            title: isEpisode ? (item.seriesTitle ?? item.title) : item.title,
            logoUrl: item.logoUrl,
            badges: badges,
            metaParts: meta,
            synopsis: item.overview,
            backdropUrl: Self.nonEmpty(item.backdropUrl),
            backdropThumbhash: item.backdropThumbhash,
            fallbackArtworkUrl: Self.nonEmpty(item.posterUrl),
            fallbackArtworkThumbhash: item.posterThumbhash,
            isEpisode: isEpisode
        )
    }

    /// Collection preview (§6.2): name, count, poster-derived backdrop.
    init(collection: LibraryCollection, rowTitle: String) {
        var meta: [String] = []
        if let count = collection.itemCount, count > 0 {
            meta.append("\(count) \(count == 1 ? "item" : "items")")
        }
        if collection.kind == .userCollections {
            meta.append("User collection")
        }

        self.init(
            id: "\(rowTitle)#collection:\(collection.id)",
            contentId: nil,
            eyebrow: rowTitle,
            title: collection.name,
            logoUrl: nil,
            badges: [],
            metaParts: meta,
            synopsis: nil,
            backdropUrl: nil,
            backdropThumbhash: nil,
            fallbackArtworkUrl: collection.posterUrl,
            fallbackArtworkThumbhash: collection.posterThumbhash,
            isEpisode: false
        )
    }

    // MARK: Formatting

    /// Badge chips from the section payload's `OverlaySummary` — the
    /// marquee shows the headline trio (resolution, dynamic range,
    /// audio), uppercased to the §4.1 badge style.
    private static func badges(from summary: OverlaySummary?) -> [String] {
        guard let summary else { return [] }
        var badges: [String] = []
        if let resolution = prettyResolution(summary.resolution) {
            badges.append(resolution)
        }
        if let hdr = nonEmpty(summary.hdr) {
            badges.append(hdr.localizedCaseInsensitiveContains("dv") || hdr.localizedCaseInsensitiveContains("dolby")
                ? "DOLBY VISION"
                : hdr.uppercased())
        }
        if let audio = nonEmpty(summary.audio) {
            badges.append(audio.localizedCaseInsensitiveContains("atmos") ? "ATMOS" : audio.uppercased())
        }
        return badges
    }

    private static func prettyResolution(_ value: String?) -> String? {
        guard let value = nonEmpty(value) else { return nil }
        switch value.lowercased() {
        case "2160p", "4k", "uhd": return "4K"
        case "4320p", "8k": return "8K"
        default: return value.uppercased()
        }
    }

    private static func episodeToken(season: Int?, episode: Int?) -> String? {
        switch (season, episode) {
        case let (season?, episode?): return "S\(season) E\(episode)"
        case let (season?, nil): return "Season \(season)"
        case let (nil, episode?): return "Episode \(episode)"
        default: return nil
        }
    }

    /// `23 min left` for items with a live resume point, mirroring the
    /// progress rules MediaRow uses for its bars.
    private static func timeLeftText(position: Double?, duration: Double?) -> String? {
        guard let position, let duration,
              duration > 0, position > 60, position / duration < 0.95 else {
            return nil
        }
        let remaining = max(Int(((duration - position) / 60).rounded(.up)), 1)
        return "\(remaining) min left"
    }

    /// Episode/movie length: the metadata runtime when present, else
    /// derived from the file duration the payload already carries.
    private static func lengthText(runtimeMinutes: Int?, durationSeconds: Double?) -> String? {
        if let text = runtimeText(minutes: runtimeMinutes) { return text }
        guard let durationSeconds, durationSeconds > 0 else { return nil }
        return runtimeText(minutes: Int((durationSeconds / 60).rounded()))
    }

    private static func runtimeText(minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        if minutes >= 60 {
            let hours = minutes / 60
            let rest = minutes % 60
            return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
        }
        return "\(minutes) min"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - Detail enrichment

/// Fields the marquee wants but section payloads don't carry yet (§9:
/// air date, cast) — backfilled from a cached, low-priority item-detail
/// fetch that never blocks or delays the marquee itself.
struct TVMarqueeEnrichment: Equatable {
    /// `Aired Mar 12, 2026 · Pedro Pascal, Bella Ramsey, Anna Torv`
    let detailLine: String?
    /// The detail-level backdrop. For episodes this is the series backdrop —
    /// far higher-res than the episode still the section payload carries — so
    /// the root hero swaps to it once enrichment arrives.
    let backdropUrl: String?
    let backdropThumbhash: String?

    init(detail: ItemDetail) {
        backdropUrl = detail.backdropUrl
        backdropThumbhash = detail.backdropThumbhash
        var parts: [String] = []
        if let airDate = Self.airDateText(detail.airDate) {
            parts.append("Aired \(airDate)")
        }
        let cast = (detail.cast ?? [])
            .sorted { ($0.order ?? Int.max) < ($1.order ?? Int.max) }
            .prefix(3)
            .map(\.name)
            .filter { !$0.isEmpty }
        if !cast.isEmpty {
            parts.append(cast.joined(separator: ", "))
        }
        detailLine = parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Mirrors PlayerView's air-date formatting, with a date-only
    /// fallback for the server's `yyyy-MM-dd` strings.
    private static func airDateText(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let date = (try? Date(raw, strategy: .iso8601))
            ?? (try? Date(raw, strategy: .iso8601.year().month().day()))
        guard let date else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - Debounce model

/// Focused-card → marquee state shared by the tvOS Home and library
/// Browse landings. Rows report card focus immediately; the marquee and
/// backdrop swap only after focus has rested 150 ms (§4.2), so scrubbing
/// across a row never flashes intermediate backdrops. While focus is in
/// chrome the last previewed item is retained — rows never report focus
/// loss, only focus gain.
@Observable
@MainActor
final class TVFocusMarqueeModel {
    /// The rested, currently-displayed content. `nil` until the first
    /// row reports focus — the marquee region stays scrim-only (§8).
    private(set) var content: TVMarqueeContent?
    /// Detail backfill (§9: air date, cast) for the displayed content.
    /// Arrives after a low-priority fetch and fades in; `nil` until then.
    private(set) var enrichment: TVMarqueeEnrichment?
    /// Dominant-color wash behind the backdrop, sampled per displayed
    /// backdrop (same palette pipeline the hero carousel used).
    private(set) var tintColor: Color = .continuumBackground

    /// Backdrop art for the root hero. Episodes need their detail-level series
    /// backdrop, and any item missing a section backdrop gets one chance to
    /// obtain the real backdrop from detail. While that request is in flight
    /// the hero stays artwork-free instead of flashing the poster. Poster/still
    /// fallback is used only after detail confirms no backdrop exists (or for
    /// collections, which have no detail lookup).
    private var resolvedArtwork: TVHeroArtwork? {
        guard let content else { return nil }
        return TVHeroArtworkResolver.resolve(
            sectionBackdrop: TVHeroArtwork(
                url: content.backdropUrl,
                thumbhash: content.backdropThumbhash
            ),
            fallback: TVHeroArtwork(
                url: content.fallbackArtworkUrl,
                thumbhash: content.fallbackArtworkThumbhash
            ),
            prefersEnrichedBackdrop: content.isEpisode || content.backdropUrl?.isEmpty != false,
            canLoadEnrichment: content.contentId != nil,
            enrichmentState: enrichmentState,
            enrichedBackdrop: TVHeroArtwork(
                url: enrichment?.backdropUrl,
                thumbhash: enrichment?.backdropThumbhash
            )
        )
    }

    var backdropURL: String? { resolvedArtwork?.url }

    var backdropThumbhash: String? { resolvedArtwork?.thumbhash }

    private var debounceTask: Task<Void, Never>?
    private var tintTask: Task<Void, Never>?
    private var enrichTask: Task<Void, Never>?
    private var enrichmentState: TVHeroEnrichmentState = .notStarted
    private var lastSampledTintURL: String?
    /// Per-item enrichment cache so scrubbing back over a row never
    /// refetches details.
    private var enrichmentCache: [String: TVMarqueeEnrichment] = [:]

    /// Cold-entry seed: display a candidate immediately, skipping the rest
    /// debounce, so the page's first frame already carries a backdrop
    /// instead of fading one in after focus settles. Only applies before
    /// anything has displayed — later calls are no-ops and the focus-driven
    /// `preview` path stays authoritative.
    func seed(_ candidate: TVMarqueeContent) {
        guard content == nil else { return }
        debounceTask?.cancel()
        display(candidate)
    }

    /// Report card focus. Cancels any pending swap and schedules a new
    /// one at +150 ms; reporting the already-displayed content is a no-op.
    func preview(_ candidate: TVMarqueeContent) {
        debounceTask?.cancel()
        guard candidate != content else { return }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(ContinuumTheme.Skyline.marqueeRestDebounceMilliseconds))
            guard !Task.isCancelled else { return }
            self?.display(candidate)
        }
    }

    private func display(_ candidate: TVMarqueeContent) {
        content = candidate
        loadEnrichment(for: candidate)
        sampleTintIfNeeded(for: backdropURL)
    }

    /// The §9 backfill: fields the section payload doesn't carry (air
    /// date, cast) come from the item-detail endpoint after the marquee
    /// has already displayed — never blocking it, cached per item, and
    /// rate-limited by the rest debounce upstream.
    private func loadEnrichment(for candidate: TVMarqueeContent) {
        enrichTask?.cancel()
        guard let contentId = candidate.contentId else {
            enrichment = nil
            enrichmentState = .completed
            return
        }
        if let cached = enrichmentCache[contentId] {
            enrichment = cached
            enrichmentState = .completed
            sampleTintIfNeeded(for: backdropURL)
            return
        }

        enrichment = nil
        enrichmentState = .loading
        enrichTask = Task { [weak self] in
            do {
                let detail = try await ContinuumAPI.shared.itemDetail(contentId: contentId)
                guard !Task.isCancelled, let self else { return }
                // The marquee already paid for the same catalog request the
                // detail route needs. Keep the complete payload—not only the
                // tiny marquee projection—so pressing Select after resting on
                // a card opens the approved detail layout immediately.
                ResponseCache.shared.set(detail, for: CacheKey.itemDetail(contentId))
                let enrichment = TVMarqueeEnrichment(detail: detail)
                self.enrichmentCache[contentId] = enrichment
                if self.content?.contentId == contentId {
                    self.enrichment = enrichment
                    self.enrichmentState = .completed
                    self.sampleTintIfNeeded(for: self.backdropURL)
                }
            } catch {
                guard !Task.isCancelled, let self,
                      self.content?.contentId == contentId else { return }
                self.enrichment = nil
                self.enrichmentState = .failed
                self.sampleTintIfNeeded(for: self.backdropURL)
            }
        }
    }

    private func sampleTintIfNeeded(for urlString: String?) {
        guard let urlString, !urlString.isEmpty, let url = URL(string: urlString) else { return }
        guard urlString != lastSampledTintURL else { return }

        // A previously-sampled tint (startup prefetch, earlier focus visit)
        // applies synchronously, so a cold-entry seed paints the wash on the
        // same frame as the backdrop.
        if let cached = HeroBackdropPalette.cachedTint(for: url) {
            lastSampledTintURL = urlString
            tintTask?.cancel()
            tintColor = cached
            return
        }

        lastSampledTintURL = urlString
        tintTask?.cancel()
        tintTask = Task { [weak self] in
            let tint = await HeroBackdropPalette.tintColor(for: url)
            guard !Task.isCancelled, let self else { return }
            guard let tint else {
                if self.lastSampledTintURL == urlString {
                    self.lastSampledTintURL = nil
                }
                return
            }
            self.tintColor = tint
        }
    }
}

// MARK: - Marquee view

/// Passive billboard anchored bottom-left on Home and the library Browse
/// landings (§5.4/§5.5): always previews the card the user is focused on, never
/// participates in focus, has no buttons. Crossfades 240 ms (snaps under
/// Reduce Motion) and is exposed to VoiceOver as a polite, non-interrupting
/// description of the focused item.
struct TVFocusMarquee: View {
    enum Scale {
        /// Home — full-bleed scale (title 84), anchored bottom-left above
        /// the row band.
        case home
        /// Library landing — compact spotlight scale (title 66) so the block
        /// clears the pill row while sitting just above row 1.
        case library

        var bottomInset: CGFloat {
            switch self {
            case .home: ContinuumTheme.Skyline.marqueeBottomInsetHome
            case .library: ContinuumTheme.Skyline.marqueeBottomInsetLibrary
            }
        }

        var titleSize: CGFloat {
            switch self {
            case .home: ContinuumTheme.Skyline.marqueeTitleSizeHome
            case .library: ContinuumTheme.Skyline.marqueeTitleSizeLibrary
            }
        }

        var metaSize: CGFloat {
            switch self {
            case .home: ContinuumTheme.Skyline.marqueeMetaSizeHome
            case .library: ContinuumTheme.Skyline.marqueeMetaSizeLibrary
            }
        }

        /// Logo art height cap — the 2-line text-title equivalent for the
        /// scale, so a logo never pushes the block past the row slot.
        var logoMaxHeight: CGFloat {
            switch self {
            case .home: ContinuumTheme.Skyline.marqueeLogoMaxHeightHome
            case .library: ContinuumTheme.Skyline.marqueeLogoMaxHeightLibrary
            }
        }
    }

    let content: TVMarqueeContent?
    var enrichment: TVMarqueeEnrichment? = nil
    let scale: Scale

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// False until the first content has painted — the initial (seeded)
    /// block snaps in; only content→content swaps crossfade.
    @State private var hasDisplayedContent = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let content {
                TVMarqueeBlock(content: content, enrichment: enrichment, scale: scale)
                    .id(content.id)
                    .transition(.opacity)
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .bottomLeading
        )
        .padding(.leading, ContinuumTheme.Skyline.safeAreaX)
        .padding(.bottom, scale.bottomInset)
        .ignoresSafeArea(edges: [.top, .horizontal])
        .allowsHitTesting(false)
        .focusEffectDisabled()
        // The model swaps `content` outside any animation transaction, so
        // the crossfade is driven here, keyed on the item id (§4.2 240 ms).
        // Reduce Motion drops the animation entirely → the swap snaps. The
        // very first content (cold-entry seed) also snaps, so the marquee is
        // simply there on the page's first frame instead of fading in.
        .animation(
            reduceMotion || !hasDisplayedContent
                ? nil
                : .easeInOut(duration: ContinuumTheme.Skyline.marqueeCrossfadeDuration),
            value: content?.id
        )
        // The §9 detail line lands after the block; fade it in on its own.
        .animation(
            reduceMotion ? nil : .easeInOut(duration: ContinuumTheme.Skyline.marqueeCrossfadeDuration),
            value: enrichment?.detailLine
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.updatesFrequently)
        .onAppear {
            if content != nil { hasDisplayedContent = true }
        }
        .onChange(of: content) { _, newValue in
            guard let newValue else { return }
            hasDisplayedContent = true
            announce(newValue)
        }
    }

    private var accessibilityDescription: String {
        guard let content else { return "" }
        let parts = [content.eyebrow, content.title]
            + content.metaParts
            + [content.synopsis ?? "", enrichment?.detailLine ?? ""]
        return parts
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// Polite live region: queue a low-priority announcement that never
    /// interrupts in-progress speech while the user scrubs a row.
    private func announce(_ content: TVMarqueeContent) {
        var message = AttributedString(accessibilityDescription)
        message.accessibilitySpeechAnnouncementPriority = .low
        AccessibilityNotification.Announcement(message).post()
    }
}

// MARK: - Content block

/// One marquee "frame": title (text first, cached logo art may swap
/// in), badge + meta line, synopsis. The §5.4 eyebrow (source-row title)
/// was dropped by design revision — the row's own header already names
/// the source, and the marquee leads with the title. Identity is keyed
/// on the content id by the parent so a content change crossfades whole
/// blocks.
private struct TVMarqueeBlock: View {
    let content: TVMarqueeContent
    var enrichment: TVMarqueeEnrichment? = nil
    let scale: TVFocusMarquee.Scale

    /// Server logo art, swapped in only once decoded — the text title
    /// renders immediately and the crossfade never waits on this fetch.
    @State private var logoImage: UIImage?
    @State private var logoTask: Task<Void, Never>?
    /// When the text title wraps to two lines the synopsis drops to one
    /// (§5.4) so the block never collides with row 1.
    @State private var titleWrapsTwoLines = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        content: TVMarqueeContent,
        enrichment: TVMarqueeEnrichment? = nil,
        scale: TVFocusMarquee.Scale
    ) {
        self.content = content
        self.enrichment = enrichment
        self.scale = scale
        // A prefetched logo should be on the block's very first frame —
        // waiting for onAppear paints one frame of text title first, which
        // reads as a flash on cold entry. Synchronous memory-cache lookup.
        if let logoUrl = content.logoUrl, !logoUrl.isEmpty,
           let url = URL(string: logoUrl),
           let cached = ImagePipeline.shared.cache[ImageRequest(url: url)] {
            _logoImage = State(initialValue: cached.image)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            titleSlot

            metaLine

            if let synopsis = content.synopsis, !synopsis.isEmpty {
                Text(synopsis)
                    .font(.system(size: ContinuumTheme.Skyline.marqueeSynopsisSize, weight: .regular))
                    .lineSpacing(6)
                    .foregroundStyle(Color.continuumSecondaryText)
                    .lineLimit(synopsisLineLimit)
                    .frame(maxWidth: ContinuumTheme.Skyline.marqueeSynopsisMaxWidth, alignment: .leading)
            }

            detailLine
        }
        .frame(maxWidth: ContinuumTheme.Skyline.marqueeContentWidth, alignment: .leading)
        .onAppear { loadLogoIfCached() }
        .onDisappear {
            logoTask?.cancel()
            logoTask = nil
        }
    }

    /// Synopsis line budget. The library scale anchors a taller block lower,
    /// so it caps at two lines to clear the Browse pill row; Home affords
    /// three. A shown logo (or a wrapped title) fills part of the budget and
    /// drops one line either way.
    private var synopsisLineLimit: Int {
        let cap: Int
        switch scale {
        case .home: cap = 3
        case .library: cap = 2
        }
        return (titleWrapsTwoLines || logoImage != nil) ? min(cap, 2) : cap
    }

    /// Air date + top-billed cast (§9 backfill). For any item that can
    /// enrich (has a contentId) an invisible one-line sizer always holds the
    /// row's height, and the real line fades into an *overlay* on top of it.
    /// Because the overlay never contributes to layout, the bottom-anchored
    /// block can't reflow when the async detail lands — the text above stays
    /// put. Collections never enrich, so they reserve nothing.
    @ViewBuilder
    private var detailLine: some View {
        if content.contentId != nil {
            Text(verbatim: "Ag")
                .font(.system(size: scale.metaSize, weight: .medium))
                .lineLimit(1)
                .opacity(0)
                .frame(maxWidth: ContinuumTheme.Skyline.marqueeSynopsisMaxWidth, alignment: .leading)
                .overlay(alignment: .leading) {
                    if let line = enrichment?.detailLine, !line.isEmpty {
                        Text(line)
                            .font(.system(size: scale.metaSize, weight: .medium))
                            .foregroundStyle(Color.continuumOnSurface.opacity(0.5))
                            .lineLimit(1)
                            .frame(maxWidth: ContinuumTheme.Skyline.marqueeSynopsisMaxWidth, alignment: .leading)
                            .transition(reduceMotion ? .identity : .opacity)
                    }
                }
        }
    }

    @ViewBuilder
    private var titleSlot: some View {
        if let logoImage {
            Image(uiImage: logoImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(
                    maxWidth: ContinuumTheme.Skyline.marqueeLogoMaxWidth,
                    maxHeight: scale.logoMaxHeight,
                    alignment: .leading
                )
                .transition(reduceMotion ? .identity : .opacity.animation(.easeInOut(duration: 0.2)))
                .accessibilityHidden(true)
        } else {
            Text(content.title)
                .font(.system(size: scale.titleSize, weight: .heavy).leading(.tight))
                .foregroundStyle(.white)
                .lineLimit(2)
                .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    titleWrapsTwoLines = height > scale.titleSize * 1.4
                }
        }
    }

    @ViewBuilder
    private var metaLine: some View {
        if !content.badges.isEmpty || !content.metaParts.isEmpty {
            HStack(spacing: 10) {
                ForEach(content.badges, id: \.self) { badge in
                    badgeChip(badge)
                }

                if !content.metaParts.isEmpty {
                    Text(content.metaParts.joined(separator: " · "))
                        .font(.system(size: scale.metaSize, weight: .medium))
                        .foregroundStyle(Color.continuumSecondaryText)
                        .lineLimit(1)
                }
            }
        }
    }

    private func badgeChip(_ label: String) -> some View {
        Text(label)
            .font(.system(size: ContinuumTheme.Skyline.marqueeBadgeSize, weight: .semibold))
            .tracking(ContinuumTheme.Skyline.marqueeBadgeSize * 0.08)
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.continuumChromeRestingFill)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
            }
    }

    // MARK: Logo swap-in

    /// Show cached logo art instantly; otherwise fetch at low priority
    /// and swap in whenever it lands. The text title is never delayed.
    private func loadLogoIfCached() {
        guard let logoUrl = content.logoUrl, !logoUrl.isEmpty,
              let url = URL(string: logoUrl) else {
            return
        }

        let request = ImageRequest(url: url, priority: .low)
        if let cached = ImagePipeline.shared.cache[request] {
            logoImage = cached.image
            return
        }

        logoTask = Task { @MainActor in
            guard let image = try? await ImagePipeline.shared.image(for: request) else { return }
            guard !Task.isCancelled else { return }
            logoImage = image
        }
    }
}
#endif
