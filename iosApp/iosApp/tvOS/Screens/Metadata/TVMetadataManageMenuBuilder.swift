#if os(tvOS)
import SwiftUI

/// Active full-screen metadata curation flow on tvOS.
enum TVMetadataSheetPresentation: Identifiable, Hashable {
    case chooseArtwork(MetadataCurationTarget)
    case fixMatch(MetadataCurationTarget)

    var id: String {
        switch self {
        case .chooseArtwork(let target): return "tv:artwork:\(target.contentId)"
        case .fixMatch(let target): return "tv:fixMatch:\(target.contentId)"
        }
    }
}

/// Coordinates tvOS metadata curation covers for a detail page or the shared
/// root card-triage host.
@MainActor
@Observable
final class TVMetadataCurationController {
    /// Single app-level host used by tvOS `MediaCard` context menus.
    static let sharedCardHost = TVMetadataCurationController()

    var presentedSheet: TVMetadataSheetPresentation?

    func reset() {
        presentedSheet = nil
    }
}

private struct TVMetadataCurationControllerKey: EnvironmentKey {
    static let defaultValue: TVMetadataCurationController? = nil
}

extension EnvironmentValues {
    var tvMetadataCurationController: TVMetadataCurationController? {
        get { self[TVMetadataCurationControllerKey.self] }
        set { self[TVMetadataCurationControllerKey.self] = newValue }
    }
}

/// Builds the `Manage` submenu inside tvOS `TVActionPopoverMenu` and dispatches
/// selections to `TVMetadataCurationController` and `MetadataRefreshCenter`.
enum TVMetadataManageMenuBuilder {
    enum ItemID {
        static let submenu = "meta:manage-submenu"
        static let chooseArtwork = "meta:choose-artwork"
        static let seasonArtwork = "meta:season-artwork"
        static let fixMatch = "meta:fix-match"
        static let refreshSubmenu = "meta:refresh-submenu"
        static let refreshQuick = "meta:refresh-quick"
        static let refreshComplete = "meta:refresh-complete"
        static let refreshSeasonQuick = "meta:refresh-season-quick"
        static let refreshSeasonComplete = "meta:refresh-season-complete"
        static let refreshEpisodeQuick = "meta:refresh-episode-quick"
        static let refreshEpisodeComplete = "meta:refresh-episode-complete"
    }

    @MainActor
    static func menuItem(
        for detail: ItemDetail,
        selectedSeason: Season? = nil,
        selectedEpisode: EpisodeListItem? = nil,
        locale: Locale = AppLanguage.formattingLocale
    ) -> TVActionPopoverItem? {
        let authority = MetadataCurationAuthorityStore.shared
        let target = MetadataCurationTarget.from(detail: detail)

        var children: [TVActionPopoverItem] = []

        if authority.canEditArtwork && target.supportsArtwork {
            children.append(TVActionPopoverItem(
                id: ItemID.chooseArtwork,
                title: MetadataStrings.chooseArtwork,
                systemImage: "photo.on.rectangle.angled"
            ))
        }

        if authority.canCurateMetadata && target.supportsFixMatch {
            children.append(TVActionPopoverItem(
                id: ItemID.fixMatch,
                title: MetadataStrings.fixMatch,
                systemImage: "magnifyingglass"
            ))
        }

        if authority.canCurateMetadata && target.supportsRefresh {
            children.append(TVActionPopoverItem(
                id: ItemID.refreshSubmenu,
                title: MetadataStrings.refreshMetadataTitle,
                systemImage: "arrow.clockwise",
                startsSection: !children.isEmpty,
                children: refreshModeItems(
                    quickId: ItemID.refreshQuick,
                    completeId: ItemID.refreshComplete
                )
            ))
        }

        if target.mediaType == "series", let season = selectedSeason {
            let label = season.displayName(locale: locale)
            var startedSeasonSection = false
            if authority.canEditArtwork {
                children.append(TVActionPopoverItem(
                    id: ItemID.seasonArtwork,
                    title: MetadataStrings.seasonArtwork(label),
                    systemImage: "photo",
                    startsSection: !children.isEmpty
                ))
                startedSeasonSection = true
            }
            if authority.canCurateMetadata {
                children.append(TVActionPopoverItem(
                    id: "meta:refresh-season-submenu",
                    title: MetadataStrings.refreshSeasonMenuTitle(label),
                    systemImage: "arrow.clockwise",
                    startsSection: !startedSeasonSection && !children.isEmpty,
                    children: refreshModeItems(
                        quickId: ItemID.refreshSeasonQuick,
                        completeId: ItemID.refreshSeasonComplete
                    )
                ))
            }
        }

        if target.mediaType == "series",
           authority.canCurateMetadata,
           let episode = selectedEpisode {
            let code = EpisodeLabel.code(
                season: episode.seasonNumber,
                episode: episode.episodeNumber,
                style: .dotted,
                locale: locale
            )
            children.append(TVActionPopoverItem(
                id: "meta:refresh-episode-submenu",
                title: MetadataStrings.refreshEpisodeMenuTitle(code),
                systemImage: "arrow.clockwise",
                startsSection: !children.isEmpty,
                children: refreshModeItems(
                    quickId: ItemID.refreshEpisodeQuick,
                    completeId: ItemID.refreshEpisodeComplete
                )
            ))
        }

        guard !children.isEmpty else { return nil }

        return TVActionPopoverItem(
            id: ItemID.submenu,
            title: MetadataStrings.manageMenuTitle,
            systemImage: "wrench.and.screwdriver",
            startsSection: true,
            children: children
        )
    }

    /// Handles a `TVActionPopoverItem` selection if it belongs to Manage.
    @MainActor
    @discardableResult
    static func handleSelection(
        _ itemId: String,
        detail: ItemDetail,
        libraryId: Int?,
        selectedSeason: Season? = nil,
        selectedEpisode: EpisodeListItem? = nil,
        locale: Locale = AppLanguage.formattingLocale,
        controller: TVMetadataCurationController
    ) -> Bool {
        let target = MetadataCurationTarget.from(detail: detail, libraryId: libraryId)
        switch itemId {
        case ItemID.chooseArtwork:
            controller.presentedSheet = .chooseArtwork(target)
            return true
        case ItemID.seasonArtwork:
            guard let season = selectedSeason else { return true }
            let seasonTarget = MetadataCurationTarget.from(
                season: season,
                seriesDetail: detail,
                libraryId: libraryId,
                locale: locale
            )
            controller.presentedSheet = .chooseArtwork(seasonTarget)
            return true
        case ItemID.fixMatch:
            controller.presentedSheet = .fixMatch(target)
            return true
        case ItemID.refreshQuick:
            MetadataRefreshCenter.shared.startRefresh(target: target, mode: .quick)
            return true
        case ItemID.refreshComplete:
            MetadataRefreshCenter.shared.startRefresh(target: target, mode: .complete)
            return true
        case ItemID.refreshSeasonQuick, ItemID.refreshSeasonComplete:
            guard let season = selectedSeason else { return true }
            let seasonTarget = MetadataCurationTarget.from(
                season: season,
                seriesDetail: detail,
                libraryId: libraryId,
                locale: locale
            )
            MetadataRefreshCenter.shared.startRefresh(
                target: seasonTarget,
                mode: itemId == ItemID.refreshSeasonQuick ? .quick : .complete
            )
            return true
        case ItemID.refreshEpisodeQuick, ItemID.refreshEpisodeComplete:
            guard let episode = selectedEpisode else { return true }
            let episodeTarget = MetadataCurationTarget.from(
                episode: episode,
                seriesDetail: detail,
                libraryId: libraryId,
                locale: locale
            )
            MetadataRefreshCenter.shared.startRefresh(
                target: episodeTarget,
                mode: itemId == ItemID.refreshEpisodeQuick ? .quick : .complete
            )
            return true
        default:
            return false
        }
    }

    private static func refreshModeItems(quickId: String, completeId: String) -> [TVActionPopoverItem] {
        [
            TVActionPopoverItem(
                id: quickId,
                title: MetadataStrings.quickRefresh,
                detail: MetadataStrings.quickRefreshDescription,
                systemImage: "bolt"
            ),
            TVActionPopoverItem(
                id: completeId,
                title: MetadataStrings.completeRefresh,
                detail: MetadataStrings.completeRefreshDescription,
                systemImage: "arrow.triangle.2.circlepath"
            ),
        ]
    }
}

// MARK: - tvOS Card & Season Context Menus

/// Context menu actions for tvOS poster cards (`FocusableMediaCard`).
struct TVMetadataCardManageMenu: View {
    let target: MetadataCurationTarget

    @Environment(\.tvMetadataCurationController) private var envController

    private var controller: TVMetadataCurationController {
        envController ?? .sharedCardHost
    }

    var body: some View {
        let capabilities = target.cardCapabilities()
        if capabilities.hasAny {
            Section(MetadataStrings.manageMenuTitle) {
                if capabilities.canChooseArtwork {
                    Button {
                        controller.presentedSheet = .chooseArtwork(target)
                    } label: {
                        Label(MetadataStrings.chooseArtwork, systemImage: "photo.on.rectangle.angled")
                    }
                }
                if capabilities.canFixMatch {
                    Button {
                        controller.presentedSheet = .fixMatch(target)
                    } label: {
                        Label(MetadataStrings.fixMatch, systemImage: "magnifyingglass")
                    }
                }
            }
        }
    }
}

/// Context menu actions for tvOS Season tabs in `TVSeriesDetailView`.
struct TVSeasonManageContextMenuSection: View {
    let season: Season
    let seriesDetail: ItemDetail
    let libraryId: Int?
    let controller: TVMetadataCurationController

    @Environment(\.locale) private var locale
    private var authority: MetadataCurationAuthorityStore { .shared }

    var body: some View {
        if authority.canEditArtwork || authority.canCurateMetadata {
            let target = MetadataCurationTarget.from(
                season: season,
                seriesDetail: seriesDetail,
                libraryId: libraryId,
                locale: locale
            )
            Section(MetadataStrings.manageMenuTitle) {
                if authority.canEditArtwork {
                    Button {
                        controller.presentedSheet = .chooseArtwork(target)
                    } label: {
                        Label(MetadataStrings.chooseArtwork, systemImage: "photo.on.rectangle.angled")
                    }
                }
                if authority.canCurateMetadata {
                    Button {
                        MetadataRefreshCenter.shared.startRefresh(target: target, mode: .quick)
                    } label: {
                        Label(MetadataStrings.quickRefresh, systemImage: "bolt")
                    }
                    Button {
                        MetadataRefreshCenter.shared.startRefresh(target: target, mode: .complete)
                    } label: {
                        Label(MetadataStrings.completeRefresh, systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
        }
    }
}

/// Context menu actions for tvOS episode cards in `TVEpisodeRail`.
struct TVEpisodeManageContextMenuSection: View {
    let episode: EpisodeListItem
    let seriesDetail: ItemDetail
    let libraryId: Int?

    @Environment(\.locale) private var locale
    private var authority: MetadataCurationAuthorityStore { .shared }

    var body: some View {
        if authority.canCurateMetadata {
            let target = MetadataCurationTarget.from(
                episode: episode,
                seriesDetail: seriesDetail,
                libraryId: libraryId,
                locale: locale
            )
            Section(MetadataStrings.manageMenuTitle) {
                Button {
                    MetadataRefreshCenter.shared.startRefresh(target: target, mode: .quick)
                } label: {
                    Label(MetadataStrings.quickRefresh, systemImage: "bolt")
                }
                Button {
                    MetadataRefreshCenter.shared.startRefresh(target: target, mode: .complete)
                } label: {
                    Label(MetadataStrings.completeRefresh, systemImage: "arrow.triangle.2.circlepath")
                }
            }
        }
    }
}

/// Custom tvOS pill button style for metadata headers so SwiftUI does not
/// paint `.plain`'s grey rectangular focus backing plate behind capsules.
struct TVMetadataPillButtonStyle: ButtonStyle {
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        TVMetadataPillButtonBody(configuration: configuration, isActive: isActive)
    }
}

private struct TVMetadataPillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isActive: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .foregroundStyle(isFocused ? Color.black : Color.siloOnSurface)
            .padding(.horizontal, 26)
            .padding(.vertical, 14)
            .background(
                Capsule().fill(
                    isFocused
                        ? Color.siloPrimary
                        : (isActive ? Color.white.opacity(0.24) : Color.siloChromeRestingFill)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    isFocused
                        ? Color.clear
                        : (isActive ? Color.white.opacity(0.55) : Color.siloChromeRestingBorder),
                    lineWidth: isActive ? 2 : 1.5
                )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.05 : 1.0))
            .shadow(
                color: .black.opacity(isFocused ? 0.35 : 0),
                radius: isFocused ? 14 : 0,
                y: isFocused ? 6 : 0
            )
            .focusEffectDisabled()
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: configuration.isPressed)
    }
}

// MARK: - tvOS Full-Screen Curation Host Modifier

private struct TVMetadataCurationHostModifier: ViewModifier {
    @Bindable var controller: TVMetadataCurationController
    var showsStatusToast: Bool

    private var refreshCenter: MetadataRefreshCenter { .shared }

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $controller.presentedSheet) { presentation in
                switch presentation {
                case .chooseArtwork(let target):
                    TVChooseArtworkView(
                        target: target,
                        onArtworkApplied: {
                            refreshCenter.showTransientToast(MetadataStrings.artworkUpdatedToast)
                        }
                    )
                case .fixMatch(let target):
                    TVFixMatchView(
                        target: target,
                        onMatchApplied: {
                            refreshCenter.showTransientToast(MetadataStrings.matchAppliedToast)
                        }
                    )
                }
            }
            .overlay(alignment: .bottom) {
                if showsStatusToast, let toast = refreshCenter.toast {
                    MetadataStatusToastPill(state: toast)
                        .padding(.bottom, 48)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: refreshCenter.toast)
    }
}

extension View {
    func tvMetadataCurationHost(
        _ controller: TVMetadataCurationController,
        showsStatusToast: Bool = true
    ) -> some View {
        modifier(
            TVMetadataCurationHostModifier(
                controller: controller,
                showsStatusToast: showsStatusToast
            )
        )
    }
}
#endif
