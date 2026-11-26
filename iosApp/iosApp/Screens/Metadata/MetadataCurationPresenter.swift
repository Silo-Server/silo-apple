#if os(iOS)
import SwiftUI

// MARK: - Detail Reload & Route-Replacement Observer (iOS & iPadOS)

private struct MetadataDetailReloadModifier: ViewModifier {
    let contentId: String
    let seriesId: String?
    let isEnabled: Bool
    let onReplaceContentId: ((String) -> Void)?
    let onReload: () -> Void

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .metadataItemDidChange)) { notification in
            guard isEnabled,
                  let event = notification.object as? MetadataItemChangeEvent else { return }
            let affectsThisPage = event.contentId == contentId
                || event.replacedByContentId == contentId
                || event.seriesId == contentId
                || (seriesId != nil && event.seriesId == seriesId)
            guard affectsThisPage else { return }

            // Only replace the page route when the page's own root item moved
            // to a new contentId. A child Season or Episode replacement reloads
            // the Series page in place instead of clobbering the Series route.
            if let replaced = event.replacedByContentId,
               event.contentId == contentId,
               replaced != contentId {
                onReplaceContentId?(replaced)
                return
            }
            onReload()
        }
    }
}

extension View {
    /// Observes `.metadataItemDidChange` for a detail screen, swapping the
    /// route only when the screen's root item migrated and otherwise reloading.
    func metadataDetailReload(
        contentId: String,
        seriesId: String?,
        isEnabled: Bool,
        onReplaceContentId: ((String) -> Void)?,
        onReload: @escaping () -> Void
    ) -> some View {
        modifier(
            MetadataDetailReloadModifier(
                contentId: contentId,
                seriesId: seriesId,
                isEnabled: isEnabled,
                onReplaceContentId: onReplaceContentId,
                onReload: onReload
            )
        )
    }
}

/// Coordinates sheets and refresh confirmation dialogs for a detail page or
/// the shared root card-triage host on iOS and iPadOS.
///
/// Refresh jobs and status toasts live on `MetadataRefreshCenter.shared` so
/// they survive detail navigation, card recycling, and `contentId` swaps.
@MainActor
@Observable
final class MetadataCurationController {
    /// Single app-level host used by `MediaCard` context menus on iOS and iPadOS
    /// so cards never mount per-card sheets, dialogs, or toast overlays.
    static let sharedCardHost = MetadataCurationController()

    var presentedSheet: MetadataSheetPresentation?
    var pendingRefreshTarget: MetadataCurationTarget?
    var preloadedDetail: ItemDetail?

    func open(_ presentation: MetadataSheetPresentation, detail: ItemDetail? = nil) {
        preloadedDetail = detail?.contentId == presentation.target.contentId ? detail : nil
        presentedSheet = presentation
    }

    func openFixMatch(_ target: MetadataCurationTarget, detail: ItemDetail? = nil) {
        open(.fixMatch(target), detail: detail)
    }

    func openChooseArtwork(
        _ target: MetadataCurationTarget,
        initialSlot: MetadataImageSlot = .poster,
        detail: ItemDetail? = nil
    ) {
        open(.chooseArtwork(target, initialSlot: initialSlot), detail: detail)
    }

    func openEditMetadata(_ target: MetadataCurationTarget, detail: ItemDetail? = nil) {
        open(.editMetadata(target), detail: detail)
    }

    func requestRefresh(_ target: MetadataCurationTarget) {
        pendingRefreshTarget = target
    }

    func reset() {
        presentedSheet = nil
        pendingRefreshTarget = nil
        preloadedDetail = nil
    }
}

private struct MetadataCurationControllerKey: EnvironmentKey {
    static let defaultValue: MetadataCurationController? = nil
}

extension EnvironmentValues {
    /// Active presentation's metadata curation host (`ItemDetailSheet` on iOS
    /// when inside a modal detail cover/sheet, or `ContentView`'s root host).
    var metadataCurationController: MetadataCurationController? {
        get { self[MetadataCurationControllerKey.self] }
        set { self[MetadataCurationControllerKey.self] = newValue }
    }
}

// MARK: - Detail Overflow "Manage" Submenu

/// Native `Manage` submenu for Movie and Series detail `More` menus.
/// Renders nothing when the acting profile holds no permitted action for `detail`.
struct MetadataManageMenu: View {
    let detail: ItemDetail
    let libraryId: Int?
    var selectedSeason: Season? = nil
    var selectedEpisode: EpisodeListItem? = nil
    let controller: MetadataCurationController

    @Environment(\.locale) private var locale
    private var authority: MetadataCurationAuthorityStore { .shared }

    private var itemTarget: MetadataCurationTarget {
        .from(detail: detail, libraryId: libraryId)
    }

    @MainActor
    static func hasActions(for detail: ItemDetail) -> Bool {
        let authority = MetadataCurationAuthorityStore.shared
        let target = MetadataCurationTarget.from(detail: detail)
        let canEdit = authority.canCurateMetadata && target.supportsEditMetadata
        let canMatch = authority.canCurateMetadata && target.supportsFixMatch
        let canRefresh = authority.canCurateMetadata && target.supportsRefresh
        let canArt = authority.canEditArtwork && target.supportsArtwork
        return canEdit || canMatch || canRefresh || canArt
    }

    var body: some View {
        if Self.hasActions(for: detail) {
            Divider()
            Menu {
                if authority.canCurateMetadata, itemTarget.supportsEditMetadata {
                    Button {
                        controller.openEditMetadata(itemTarget, detail: detail)
                    } label: {
                        Label(MetadataStrings.editMetadata, systemImage: "square.and.pencil")
                    }
                }

                if authority.canEditArtwork, itemTarget.supportsArtwork {
                    Button {
                        controller.openChooseArtwork(itemTarget, detail: detail)
                    } label: {
                        Label(MetadataStrings.chooseArtwork, systemImage: "photo.on.rectangle.angled")
                    }
                }

                if authority.canCurateMetadata, itemTarget.supportsFixMatch {
                    Button {
                        controller.openFixMatch(itemTarget, detail: detail)
                    } label: {
                        Label(MetadataStrings.fixMatch, systemImage: "magnifyingglass")
                    }
                }

                if authority.canCurateMetadata, itemTarget.supportsRefresh {
                    Button {
                        controller.requestRefresh(itemTarget)
                    } label: {
                        Label(MetadataStrings.refreshMetadata, systemImage: "arrow.clockwise")
                    }
                }

                if itemTarget.mediaType == "series", let season = selectedSeason {
                    let seasonTarget = MetadataCurationTarget.from(
                        season: season,
                        seriesDetail: detail,
                        libraryId: libraryId,
                        locale: locale
                    )
                    let seasonLabel = season.displayName(locale: locale)

                    Divider()
                    if authority.canEditArtwork {
                        Button {
                            controller.openChooseArtwork(seasonTarget)
                        } label: {
                            Label(MetadataStrings.seasonArtwork(seasonLabel), systemImage: "photo")
                        }
                    }
                    if authority.canCurateMetadata {
                        Button {
                            controller.openEditMetadata(seasonTarget)
                        } label: {
                            Label(MetadataStrings.editSeason(seasonLabel), systemImage: "pencil")
                        }
                        Button {
                            controller.requestRefresh(seasonTarget)
                        } label: {
                            Label(MetadataStrings.refreshSeason(seasonLabel), systemImage: "arrow.clockwise")
                        }
                    }
                }

                if itemTarget.mediaType == "series",
                   authority.canCurateMetadata,
                   let episode = selectedEpisode {
                    let episodeTarget = MetadataCurationTarget.from(
                        episode: episode,
                        seriesDetail: detail,
                        libraryId: libraryId,
                        locale: locale
                    )
                    let code = EpisodeLabel.code(
                        season: episode.seasonNumber,
                        episode: episode.episodeNumber,
                        style: .dotted,
                        locale: locale
                    )

                    Divider()
                    Button {
                        controller.openEditMetadata(episodeTarget)
                    } label: {
                        Label(MetadataStrings.editEpisode(code), systemImage: "pencil")
                    }
                    Button {
                        controller.requestRefresh(episodeTarget)
                    } label: {
                        Label(MetadataStrings.refreshEpisode(code), systemImage: "arrow.clockwise")
                    }
                }
            } label: {
                Label(MetadataStrings.manageMenuTitle, systemImage: "wrench.and.screwdriver")
            }
        }
    }
}

// MARK: - Season & Episode Context Menu Sections

struct MetadataSeasonContextMenuSection: View {
    let season: Season
    let seriesDetail: ItemDetail
    let libraryId: Int?
    let controller: MetadataCurationController

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
            Divider()
            Menu {
                if authority.canEditArtwork {
                    Button {
                        controller.openChooseArtwork(target)
                    } label: {
                        Label(MetadataStrings.chooseArtwork, systemImage: "photo.on.rectangle.angled")
                    }
                }
                if authority.canCurateMetadata {
                    Button {
                        controller.openEditMetadata(target)
                    } label: {
                        Label(MetadataStrings.editMetadata, systemImage: "square.and.pencil")
                    }
                    Button {
                        controller.requestRefresh(target)
                    } label: {
                        Label(MetadataStrings.refreshMetadata, systemImage: "arrow.clockwise")
                    }
                }
            } label: {
                Label(MetadataStrings.manageMenuTitle, systemImage: "wrench.and.screwdriver")
            }
        }
    }
}

struct MetadataEpisodeContextMenuSection: View {
    let episode: EpisodeListItem
    let seriesDetail: ItemDetail
    let libraryId: Int?
    let controller: MetadataCurationController

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
            Divider()
            Menu {
                Button {
                    controller.openEditMetadata(target)
                } label: {
                    Label(MetadataStrings.editMetadata, systemImage: "square.and.pencil")
                }
                Button {
                    controller.requestRefresh(target)
                } label: {
                    Label(MetadataStrings.refreshMetadata, systemImage: "arrow.clockwise")
                }
            } label: {
                Label(MetadataStrings.manageMenuTitle, systemImage: "wrench.and.screwdriver")
            }
        }
    }
}

// MARK: - MediaCard Quick-Triage "Manage" Submenu

/// Compact `Manage` submenu on poster cards (`MediaCard`): exposes only
/// Fix Match and Choose Artwork for rapid library triage without crowding
/// the card context menu.
struct MetadataCardManageMenu: View {
    let target: MetadataCurationTarget
    let capabilities: MetadataCurationTarget.CardCapabilities
    let onSelect: (MetadataSheetPresentation) -> Void

    var body: some View {
        if capabilities.hasAny {
            Divider()
            Menu {
                if capabilities.canFixMatch {
                    Button {
                        onSelect(.fixMatch(target))
                    } label: {
                        Label(MetadataStrings.fixMatch, systemImage: "magnifyingglass")
                    }
                }
                if capabilities.canChooseArtwork {
                    Button {
                        onSelect(.chooseArtwork(target))
                    } label: {
                        Label(MetadataStrings.chooseArtwork, systemImage: "photo.on.rectangle.angled")
                    }
                }
            } label: {
                Label(MetadataStrings.manageMenuTitle, systemImage: "wrench.and.screwdriver")
            }
        }
    }
}

// MARK: - Sheet, Refresh Dialog & Status Toast Host Modifier

private struct MetadataCurationHostModifier: ViewModifier {
    @Bindable var controller: MetadataCurationController
    var coordinatesDetailSheetRefit: Bool
    var showsRefreshDialog: Bool
    var showsStatusToast: Bool

    @Environment(AppRouter.self) private var router: AppRouter?
    @State private var hasDeferredRefit = false

    private var refreshCenter: MetadataRefreshCenter { .shared }

    func body(content: Content) -> some View {
        content
            .sheet(item: $controller.presentedSheet, onDismiss: handleSheetDismiss) { presentation in
                sheetContent(for: presentation)
            }
            .confirmationDialog(
                MetadataStrings.refreshMetadataTitle,
                isPresented: Binding(
                    get: { showsRefreshDialog && controller.pendingRefreshTarget != nil },
                    set: { if !$0 { controller.pendingRefreshTarget = nil } }
                ),
                titleVisibility: .visible,
                presenting: controller.pendingRefreshTarget
            ) { target in
                Button(MetadataStrings.quickRefresh) {
                    controller.pendingRefreshTarget = nil
                    refreshCenter.startRefresh(target: target, mode: .quick)
                }
                Button(MetadataStrings.completeRefresh) {
                    controller.pendingRefreshTarget = nil
                    refreshCenter.startRefresh(target: target, mode: .complete)
                }
                Button(.commonCancel, role: .cancel) {
                    controller.pendingRefreshTarget = nil
                }
            } message: { target in
                Text(MetadataStrings.refreshMessage(for: target))
            }
            .overlay(alignment: .bottom) {
                if showsStatusToast, let toast = refreshCenter.toast {
                    MetadataStatusToastPill(state: toast)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: refreshCenter.toast)
            .onChange(of: controller.presentedSheet != nil) { _, isPresented in
                guard coordinatesDetailSheetRefit, let router else { return }
                if isPresented, !hasDeferredRefit {
                    hasDeferredRefit = true
                    router.itemDetailDeferredRefitCount += 1
                } else if !isPresented, hasDeferredRefit {
                    hasDeferredRefit = false
                    router.itemDetailDeferredRefitCount = max(0, router.itemDetailDeferredRefitCount - 1)
                    router.refitItemDetail()
                }
            }
            .onDisappear {
                if hasDeferredRefit {
                    hasDeferredRefit = false
                    if let router {
                        router.itemDetailDeferredRefitCount = max(0, router.itemDetailDeferredRefitCount - 1)
                    }
                }
            }
    }

    private func handleSheetDismiss() {
        controller.preloadedDetail = nil
    }

    @ViewBuilder
    private func sheetContent(for presentation: MetadataSheetPresentation) -> some View {
        switch presentation {
        case .fixMatch(let target):
            FixMatchSheet(
                target: target,
                preloadedDetail: controller.preloadedDetail,
                onMatchApplied: {
                    refreshCenter.showTransientToast(MetadataStrings.matchAppliedToast)
                }
            )
        case .chooseArtwork(let target, let initialSlot):
            ChooseArtworkSheet(
                target: target,
                initialSlot: initialSlot,
                onArtworkApplied: {
                    refreshCenter.showTransientToast(MetadataStrings.artworkUpdatedToast)
                }
            )
        case .editMetadata(let target):
            EditMetadataSheet(
                target: target,
                preloadedDetail: controller.preloadedDetail,
                onSaved: {
                    refreshCenter.showTransientToast(MetadataStrings.metadataSavedToast)
                },
                onResetAndRefresh: {
                    refreshCenter.startRefresh(target: target, mode: .quick)
                }
            )
        }
    }
}

extension View {
    /// Hosts Fix Match, Choose Artwork, Edit Metadata sheets, optional Refresh
    /// confirmation dialog, and global status toasts for `controller`.
    func metadataCurationHost(
        _ controller: MetadataCurationController,
        coordinatesDetailSheetRefit: Bool = false,
        showsRefreshDialog: Bool = true,
        showsStatusToast: Bool = true
    ) -> some View {
        modifier(
            MetadataCurationHostModifier(
                controller: controller,
                coordinatesDetailSheetRefit: coordinatesDetailSheetRefit,
                showsRefreshDialog: showsRefreshDialog,
                showsStatusToast: showsStatusToast
            )
        )
    }
}
#endif
