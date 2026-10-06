#if os(macOS)
import NukeUI
import SwiftUI

/// Hero for a Home section the server marks as featured.
///
/// The section's layout is defined on the server, so a featured section is a
/// hero on every client, not a poster row. The current title fills the
/// backdrop with its metadata, synopsis, and primary actions, and the
/// section's full list runs along the bottom with the current title
/// highlighted. Clicking a title in the list brings it up; the hero also
/// advances on its own and pauses while the pointer is over it.
struct MacFeaturedHero: View {
    let section: ResolvedSection

    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var index = 0
    @State private var isHovering = false
    /// The logo that has finished loading. Until a title's logo is in, its
    /// name is shown as text, so the hero is never untitled.
    @State private var loadedLogoURL: String?

    private var item: SectionItem? {
        guard !section.items.isEmpty else { return nil }
        return section.items[min(index, section.items.count - 1)]
    }

    var body: some View {
        if let item {
            ZStack(alignment: .bottomLeading) {
                backdrop(for: item)
                scrim
                VStack(alignment: .leading, spacing: SiloTheme.largePadding) {
                    details(for: item)
                    titleStrip
                }
                .padding(.bottom, SiloTheme.padding)
            }
            .frame(maxWidth: .infinity)
            // Fill the window down to the next row's heading, so the hero
            // owns the first screen and the row below peeks in under it.
            .containerRelativeFrame(.vertical) { length, _ in
                max(SiloTheme.macHeroMinHeight, length - SiloTheme.macHeroNextRowPeek)
            }
            .clipped()
            .onHover { isHovering = $0 }
            .task(id: AdvanceTrigger(index: index, isPaused: isPaused, ids: section.items.map(\.contentId))) {
                await advanceAfterDelay()
            }
            .onChange(of: section.items.map(\.contentId)) { _, ids in
                // A reload can shorten the section; keep the label and the
                // highlight on a title that still exists.
                if index >= ids.count { index = max(0, ids.count - 1) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Featured")
        }
    }

    // MARK: - Layers

    private func backdrop(for item: SectionItem) -> some View {
        Group {
            // An empty URL is no artwork: fall back as for a missing one.
            let backdropURL = item.backdropUrl?.nonEmpty
            if let url = backdropURL ?? item.posterUrl?.nonEmpty {
                AsyncImageView(
                    url: url,
                    thumbhash: backdropURL == nil ? item.posterThumbhash : item.backdropThumbhash,
                    contentMode: .fill
                )
            } else {
                Color.siloSurfaceElevated
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .id(item.contentId)
        .transition(.opacity)
        .accessibilityHidden(true)
    }

    /// Fades the artwork into the page canvas on the leading and bottom
    /// edges: the text stays legible, and the hero has no hard edge beside
    /// the sidebar or above the first row.
    private var scrim: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .siloPageCanvas, location: 0),
                    .init(color: Color.siloPageCanvas.opacity(0.7), location: 0.3),
                    .init(color: .clear, location: 0.7),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.45),
                    .init(color: .siloPageCanvas, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func details(for item: SectionItem) -> some View {
        VStack(alignment: .leading, spacing: SiloTheme.spacing) {
            Text("Featured — No. \(Self.twoDigit(index + 1))")
                .font(.siloCaption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(SiloTheme.macSidebarHeadingTracking)
                .foregroundStyle(Color.siloSecondaryText)

            title(for: item)

            if let metadata = Self.metadataLine(for: item) {
                Text(metadata)
                    .font(.siloBody.weight(.semibold))
                    .foregroundStyle(Color.siloOnSurface)
                    .lineLimit(1)
            }

            if let overview = item.overview, !overview.isEmpty {
                Text(overview)
                    .font(.siloBody)
                    .foregroundStyle(Color.siloSecondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: SiloTheme.spacing) {
                // A series has nothing to play directly; More Info opens it.
                if SiloMediaType.isDirectlyPlayable(item.type) {
                    Button { play(item) } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.siloBody.weight(.semibold))
                            .foregroundStyle(Color.siloBackground)
                            .padding(.horizontal, SiloTheme.largePadding)
                            .padding(.vertical, SiloTheme.spacing)
                            .background(Capsule().fill(Color.siloPrimary))
                            .contentShape(Capsule())
                    }
                }
                Button { openDetail(item) } label: {
                    Label("More Info", systemImage: "info.circle")
                        .font(.siloBody.weight(.semibold))
                        .foregroundStyle(Color.siloOnSurface)
                        .padding(.horizontal, SiloTheme.largePadding)
                        .padding(.vertical, SiloTheme.spacing)
                        .background(Capsule().fill(Color.siloChromeSelectedFill))
                        .overlay(Capsule().stroke(Color.siloChromeSelectedBorder))
                        .contentShape(Capsule())
                }
            }
            .buttonStyle(.siloFlat)
            .padding(.top, SiloTheme.smallPadding)
        }
        .frame(maxWidth: SiloTheme.macHeroTextWidth, alignment: .leading)
        .padding(.leading, HomeFeedMetrics.gutter)
    }

    /// The title's logo artwork where the server has one, otherwise its name.
    @ViewBuilder
    private func title(for item: SectionItem) -> some View {
        let name = Text(item.title)
            .font(.siloHeroTitle)
            .foregroundStyle(Color.siloOnSurface)
            .lineLimit(2)
            .minimumScaleFactor(0.7)

        if let logoURL = item.logoUrl, !logoURL.isEmpty {
            let isLoaded = loadedLogoURL == logoURL
            ZStack(alignment: .bottomLeading) {
                name.opacity(isLoaded ? 0 : 1)
                // Loaded directly so the artwork can be pinned to the leading
                // edge: the shared image view centres a fitted image, which
                // would float a narrow logo away from the text below it.
                LazyImage(request: logoRequest(logoURL)) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: .bottomLeading
                            )
                            .onAppear { loadedLogoURL = logoURL }
                    }
                }
                .frame(maxWidth: Self.logoSize.width, maxHeight: Self.logoSize.height)
                .opacity(isLoaded ? 1 : 0)
                .id(logoURL)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.title)
            .accessibilityAddTraits(.isHeader)
        } else {
            name.accessibilityAddTraits(.isHeader)
        }
    }

    private func logoRequest(_ logoURL: String) -> ImageRequest? {
        guard let url = URL(string: logoURL) else { return nil }
        return PosterImageCache.displayRequest(
            url: url,
            pointSize: Self.logoSize,
            scale: displayScale
        )
    }

    private static var logoSize: CGSize {
        CGSize(width: SiloTheme.macHeroLogoWidth, height: SiloTheme.macHeroLogoHeight)
    }

    /// Every title in the section, with the one on show highlighted.
    private var titleStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: HomeFeedMetrics.cardSpacing) {
                    ForEach(Array(section.items.enumerated()), id: \.element.contentId) { offset, entry in
                        Button { select(offset) } label: {
                            thumbnail(for: entry, isCurrent: offset == index)
                        }
                        .buttonStyle(.siloFlat)
                        .id(entry.contentId)
                        .accessibilityLabel(entry.title)
                        .accessibilityAddTraits(offset == index ? .isSelected : [])
                    }
                }
                .padding(.horizontal, HomeFeedMetrics.gutter)
                // Room for the highlight ring, which draws outside the art.
                .padding(.vertical, SiloTheme.smallPadding)
            }
            .onChange(of: index) { _, newIndex in
                guard section.items.indices.contains(newIndex) else { return }
                withAnimation(.easeInOut(duration: SiloTheme.slowDuration)) {
                    proxy.scrollTo(section.items[newIndex].contentId, anchor: .center)
                }
            }
        }
        .frame(height: Self.thumbnailSize.height + SiloTheme.smallPadding * 2)
    }

    private static var thumbnailSize: CGSize {
        CGSize(
            width: SiloTheme.macHeroThumbnailWidth,
            height: SiloTheme.macHeroThumbnailWidth * HomeFeedMetrics.posterAspect
        )
    }

    private func thumbnail(for entry: SectionItem, isCurrent: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: HomeFeedMetrics.posterRadius, style: .continuous)
        return Group {
            if let url = entry.posterUrl?.nonEmpty {
                AsyncImageView(
                    url: url,
                    thumbhash: entry.posterThumbhash,
                    targetSize: Self.thumbnailSize,
                    contentMode: .fill
                )
            } else {
                Color.siloSurfaceElevated
                    .overlay {
                        Text(entry.title)
                            .font(.siloSmall)
                            .foregroundStyle(Color.siloSecondaryText)
                            .multilineTextAlignment(.center)
                            .padding(SiloTheme.smallPadding)
                    }
            }
        }
        .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(
                isCurrent ? Color.siloPrimary : Color.clear,
                lineWidth: SiloTheme.macHeroSelectionRingWidth
            )
        }
        .opacity(isCurrent ? 1 : SiloTheme.macHeroUnselectedOpacity)
        .contentShape(shape)
    }

    // MARK: - Behaviour

    private struct AdvanceTrigger: Equatable {
        let index: Int
        let isPaused: Bool
        /// Any change to the section's titles restarts the timer, so a
        /// pending advance never acts on titles that have been replaced,
        /// and a section that grows from one title starts advancing.
        let ids: [String]
    }

    /// The title must not change under someone reading or operating the
    /// hero: under the pointer, with Reduce Motion, or with VoiceOver on.
    private var isPaused: Bool {
        isHovering || reduceMotion || voiceOverEnabled
    }

    private func advanceAfterDelay() async {
        guard !isPaused, section.items.count > 1 else { return }
        try? await Task.sleep(for: .seconds(SiloTheme.macHeroAdvanceSeconds))
        guard !Task.isCancelled else { return }
        step(1)
    }

    /// Brings a title up; clicking the one already on show opens it.
    private func select(_ offset: Int) {
        guard offset != index else {
            if let item { openDetail(item) }
            return
        }
        withAnimation(.easeInOut(duration: SiloTheme.slowDuration)) {
            index = offset
        }
    }

    private func step(_ delta: Int) {
        let count = section.items.count
        guard count > 1 else { return }
        withAnimation(.easeInOut(duration: SiloTheme.slowDuration)) {
            index = (index + delta + count) % count
        }
    }

    private func play(_ item: SectionItem) {
        router.presentPlayer(
            contentId: item.contentId,
            resumePosition: item.positionSeconds,
            // Resume sections reopen the version last watched, as their
            // cards do when the section is drawn as a row.
            prefersLastUsedVersion: HomeFeed.isResume(section),
            posterURL: item.posterUrl,
            backdropURL: item.backdropUrl
        )
    }

    private func openDetail(_ item: SectionItem) {
        router.navigate(
            to: .itemDetail(destinationContentId: item.contentId, sectionItem: item)
        )
    }

    // MARK: - Formatting

    static func twoDigit(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    /// "2015 · 2h 1m · IMDb 8.1 · Action · Adventure · R", skipping whatever
    /// the item does not carry.
    static func metadataLine(for item: SectionItem) -> String? {
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        if let runtime = MediaTextFormatting.runtime(minutes: item.runtime) { parts.append(runtime) }
        if let rating = item.ratingImdb, rating > 0 {
            parts.append("IMDb " + String(format: "%.1f", rating))
        }
        parts.append(contentsOf: (item.genres ?? []).prefix(2))
        if let contentRating = item.contentRating, !contentRating.isEmpty {
            parts.append(contentRating)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
#endif
