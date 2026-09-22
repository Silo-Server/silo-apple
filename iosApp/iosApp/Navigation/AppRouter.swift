import SwiftUI

/// The ordered cards surrounding a detail presentation. iOS uses this to
/// turn the open detail sheet into a small, source-aware deck: horizontal
/// swipes move through the exact row/grid that launched it, while the source
/// view can keep its own scroll position synchronized underneath the sheet.
struct ItemDetailBrowseSource: Equatable {
    let originID: String
    let contentIDs: [String]

    init(originID: String, contentIDs: [String]) {
        self.originID = originID

        var seen = Set<String>()
        self.contentIDs = contentIDs.filter { contentID in
            !contentID.isEmpty && seen.insert(contentID).inserted
        }
    }
}

private struct BrowseLibraryIDKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

extension EnvironmentValues {
    /// Set only by library browse surfaces; detail destinations carry a copy in their route.
    var browseLibraryId: Int? {
        get { self[BrowseLibraryIDKey.self] }
        set { self[BrowseLibraryIDKey.self] = newValue }
    }
}

private struct ItemDetailBrowseSourceKey: EnvironmentKey {
    static let defaultValue: ItemDetailBrowseSource? = nil
}

extension EnvironmentValues {
    var itemDetailBrowseSource: ItemDetailBrowseSource? {
        get { self[ItemDetailBrowseSourceKey.self] }
        set { self[ItemDetailBrowseSourceKey.self] = newValue }
    }
}

extension Notification.Name {
    /// Posted by `HTTPClient` when a token refresh fails against the
    /// active server. `ContentView` observes it and drops to the login
    /// screen — the registry entry is preserved so the user only has to
    /// re-enter credentials.
    static let siloSessionExpired = Notification.Name("siloSessionExpired")
    /// Posted when a playback-only remote handoff session expires. The TV
    /// restores its persistent identity instead of routing the app to login.
    static let temporaryRemoteAuthExpired = Notification.Name("temporaryRemoteAuthExpired")
    /// Posted when the account remains valid but the selected profile was
    /// removed or its saved PIN proof is no longer accepted.
    static let siloProfileSelectionRequired = Notification.Name(
        "siloProfileSelectionRequired"
    )
}

/// Central navigation controller for the Silo iOS app.
///
/// Manages the authentication state machine and the navigation stack.
/// Observed by ContentView to decide which screen tree to present.
@Observable
class AppRouter {

    // MARK: - Auth State Machine

    enum AuthState: Equatable {
        /// App is launching; checking for stored credentials.
        case loading
        /// No server URL has been configured yet.
        case needsServerSetup
        /// Server known but user is not signed in.
        case needsLogin
        /// A remembered server responded authoritatively but cannot safely use
        /// the restored session. Credentials remain until an explicit removal
        /// or the existing terminal refresh-rejection path clears them.
        case serverRecovery(ServerRecoveryReason)
        /// Signed in but no profile has been selected.
        case needsProfile
        /// Fully authenticated with an active profile.
        case authenticated

        /// Stable diagnostics token. Spelled out rather than derived from
        /// `String(describing:)` so a future case rename can't silently break
        /// comparisons against previously collected reports. Carries no
        /// account, profile, or server identity — only which screen tree the
        /// app is showing.
        var diagnosticsState: String {
            switch self {
            case .loading: return "loading"
            case .needsServerSetup: return "needsServerSetup"
            case .needsLogin: return "needsLogin"
            case .serverRecovery(let reason): return "serverRecovery.\(reason.rawValue)"
            case .needsProfile: return "needsProfile"
            case .authenticated: return "authenticated"
            }
        }
    }

    /// Every auth-state transition funnels through this one property, whether
    /// it originates here or in a screen that assigns it directly (cold-launch
    /// resolution in `ContentView`, the server list, the tvOS tab bar). The
    /// observer is therefore the complete session timeline — the single most
    /// useful artifact for "I got logged out" and "it won't let me in", which
    /// are otherwise unreproducible. Transitions that leave the state
    /// unchanged are dropped so a re-entrant reset can't pad the timeline.
    var authState: AuthState = .loading {
        didSet {
            // Consume the cause unconditionally: a no-op assignment must not
            // leave a stale reason to be misattributed to the next transition.
            let reason = pendingAuthStateReason ?? "external"
            pendingAuthStateReason = nil
            guard oldValue != authState else { return }
            recordAuthStateBreadcrumb(from: oldValue, to: authState, reason: reason)
            // Leaving the authenticated state is an identity boundary: a video
            // still playing in PiP belongs to the old identity and must not
            // survive into the next one, so its engagement (engine + server
            // session) is ended here rather than waiting on a view callback
            // that treats engaged PiP as a presentation handoff.
            if authState != .authenticated {
                watchPartySheetPresented = false
                pendingWatchPartyPresentation = nil
                PlayerIdentityBoundary.endEngagedVideoPictureInPicture()
                dismissItemDetail()
            }
        }
    }

    /// Why the next `authState` assignment is happening, staged by the router
    /// action about to perform it and consumed by the observer above. Assigns
    /// made from outside this type leave it nil and are recorded as
    /// `external`; the destination state still tells the story.
    @ObservationIgnored private var pendingAuthStateReason: String?

    // MARK: - Navigation Stack

    /// Navigation path for push/pop within the current flow.
    private(set) var isSigningOut = false
    var accountActionError: String?

    var path = NavigationPath()

    /// Zoom-transition source id of the most recently tapped card, handed to
    /// the item-detail destination so the iOS 26 poster→detail zoom animates
    /// from the exact card tapped. A bare `contentId` collides when the same
    /// item is visible in two rows; each card uses a unique per-instance id and
    /// records it here on tap. Transient hand-off, not observable UI state.
    @ObservationIgnored var pendingZoomSourceID: String?

    // MARK: - Item Detail Presentation

    /// iPhone and iPad present catalog details as a native bottom sheet instead
    /// of pushing them into the tab or split-view navigation stack. A fresh UUID
    /// makes reopening the same title after dismissal a new presentation while
    /// keeping the content id itself available to the sheet root.
    struct ItemDetailPresentation: Identifiable, Equatable {
        let id = UUID()
        var contentId: String
        let browseSource: ItemDetailBrowseSource?
        let libraryId: Int?
        let resumeContext: SeriesDetailContext?

        init(contentId: String, libraryId: Int? = nil, browseSource: ItemDetailBrowseSource? = nil,
             resumeContext: SeriesDetailContext? = nil) {
            self.contentId = contentId
            self.browseSource = browseSource
            self.libraryId = libraryId
            self.resumeContext = resumeContext
        }
    }

    #if os(iOS)
    var presentedItemDetail: ItemDetailPresentation?
    var itemDetailPath = NavigationPath()
    #endif

    // MARK: - Player Presentation

    /// Identifiable payload for presenting the player as a full-screen cover.
    /// Used on iOS/iPadOS where pushing into the detail pane would box video
    /// into split-view navigation chrome.
    struct PlayerPresentation: Identifiable, Equatable {
        var libraryId: Int? = nil
        let id = UUID()
        let contentId: String
        let fileId: Int?
        let audioTrackIndex: Int?
        let subtitleTrackIndex: Int?
        let startFromBeginning: Bool
        let resumePosition: Double?
        /// Continue Watching asks playback to prefer the exact last-used
        /// source version over the profile's general automatic quality rule.
        let prefersLastUsedVersion: Bool
        /// Optional detail destination to install behind the full-screen
        /// player once playback has actually started.
        let returnToContentId: String?
        /// Set for offline playback of a completed download.
        var offlineDownloadId: String? = nil
        /// The iOS detail sheet that owns this cover. Nil means the app root.
        /// Keep ownership stable while the player is presented, rather than
        /// attaching competing covers to the root and the sheet.
        var detailPresentationID: UUID? = nil
        var watchPartyContext: WatchPartyPlaybackContext? = nil
        /// Hints supplied by the originating screen (e.g. the detail page,
        /// which has just loaded the catalog item) so the player's now-
        /// playing widget can publish artwork without re-fetching the
        /// catalog item solely for poster URLs. Either may be nil.
        let posterURL: String?
        let backdropURL: String?
    }

    var presentedPlayer: PlayerPresentation?
    @ObservationIgnored private var watchPartySheetPresented = false
    @ObservationIgnored private var pendingWatchPartyPresentation: WatchPartyPlaybackContext?

    @MainActor
    func watchPartySheetWillPresent() { watchPartySheetPresented = true }

    @MainActor
    func watchPartySheetDidDismiss() {
        watchPartySheetPresented = false
        if let context = pendingWatchPartyPresentation { presentWatchParty(context) }
    }

    @MainActor
    func presentWatchParty(_ context: WatchPartyPlaybackContext?) {
        pendingWatchPartyPresentation = context
        guard let context else {
            if presentedPlayer?.watchPartyContext != nil { presentedPlayer = nil }
            return
        }
        if watchPartySheetPresented, presentedPlayer?.watchPartyContext == nil { return }
        pendingWatchPartyPresentation = nil
        guard presentedPlayer?.watchPartyContext != context else { return }
        var presentation = PlayerPresentation(libraryId: context.libraryId,
            contentId: context.contentId, fileId: context.fileId,
            audioTrackIndex: nil, subtitleTrackIndex: nil,
            startFromBeginning: false, resumePosition: context.startPosition,
            prefersLastUsedVersion: false, returnToContentId: nil,
            watchPartyContext: context, posterURL: nil, backdropURL: nil)
        #if os(iOS)
        // Reuse the active presenter's cover, including a detail-owned player.
        // Replacing its content avoids racing a dismissal with a new cover.
        presentation.detailPresentationID = presentedPlayer?.detailPresentationID ?? presentedItemDetail?.id
        #endif
        presentedPlayer = presentation
    }

    #if os(iOS)
    /// Where a streaming play request should go. Installed by the root view
    /// with the SiloControl client so every local-play entry point (detail
    /// page, home rail badge, deep links, restored alerts) routes through one
    /// decision instead of each call site re-checking the remote session.
    /// Returns true when the request was taken by an engaged TV.
    var remotePlaybackInterceptor: ((SiloControlPlaybackRequest) async -> Bool)?
    /// Whether a TV is engaged right now, for sites that must not open the
    /// local player at all (a PiP restore) rather than route a request.
    var isRemotePlaybackEngaged: (() -> Bool)?

    /// True while the interceptor is deciding; a second Play in that window
    /// must not slip past it and open the local player.
    private var isRoutingRemotePlayback = false

    /// An offline play requested while a TV is engaged. A download can only
    /// play on the phone, so instead of silently starting a second player the
    /// root view asks: play here, or send the streamed version to the TV.
    struct OfflinePlayChoice: Identifiable, Equatable {
        let id = UUID()
        let presentation: PlayerPresentation
        let request: SiloControlPlaybackRequest
    }
    var pendingOfflinePlayChoice: OfflinePlayChoice?

    /// A play requested while the engaged TV is already playing a different
    /// title. Replacing what someone may be watching deserves a confirmation,
    /// so the root view asks before the request goes to the TV.
    struct ReplaceRemotePlaybackChoice: Identifiable, Equatable {
        let id = UUID()
        let request: SiloControlPlaybackRequest
        let currentTitle: String
        let targetName: String
    }
    var pendingReplaceRemotePlayback: ReplaceRemotePlaybackChoice?

    /// Installed by the root view: the title the engaged TV is playing right
    /// now, or nil when it is idle, so the router knows whether a play
    /// would replace something.
    var remotePlaybackCurrentTitle: (() -> (title: String, contentId: String?, targetName: String)?)?

    func confirmReplaceRemotePlayback() {
        guard let choice = pendingReplaceRemotePlayback else { return }
        pendingReplaceRemotePlayback = nil
        guard let remotePlaybackInterceptor else { return }
        Task { @MainActor in _ = await remotePlaybackInterceptor(choice.request) }
    }

    /// User chose the phone for a pending offline play.
    func confirmOfflinePlayHere() {
        guard let choice = pendingOfflinePlayChoice else { return }
        pendingOfflinePlayChoice = nil
        presentedPlayer = choice.presentation
    }

    /// User chose the TV for a pending offline play: the streamed version
    /// goes through the same interceptor as any other play.
    func sendPendingOfflinePlayToTV() {
        guard let choice = pendingOfflinePlayChoice else { return }
        pendingOfflinePlayChoice = nil
        guard let remotePlaybackInterceptor else { return }
        Task { @MainActor in _ = await remotePlaybackInterceptor(choice.request) }
    }
    #endif

    // MARK: - Tab Selection

    /// One-shot tab-switch request, consumed (and cleared) by `MainTabView`,
    /// which owns the actual selection state. Routed here so leaf screens —
    /// e.g. the Downloads empty state's "Browse Libraries" — can jump tabs
    /// without threading a selection binding through the tree.
    var requestedTab: AppTab?

    /// Optional copy for an alternate three-step profile journey. Cleared at
    /// every auth-state reset so a later normal login uses the default labels.
    var profileJourneyLabels: [String]?

    func switchTab(to tab: AppTab) {
        requestedTab = tab
    }

    /// Present the player using the platform-appropriate path. iOS/iPadOS use
    /// a full-window cover; macOS pushes into the main navigation content so
    /// playback replaces the detail pane instead of opening in a sheet.
    func presentPlayer(
        contentId: String,
        libraryId: Int? = nil,
        fileId: Int? = nil,
        audioTrackIndex: Int? = nil,
        subtitleTrackIndex: Int? = nil,
        startFromBeginning: Bool = false,
        resumePosition: Double? = nil,
        prefersLastUsedVersion: Bool = false,
        returnToContentId: String? = nil,
        posterURL: String? = nil,
        backdropURL: String? = nil
    ) {
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.recordBreadcrumb(
            category: .focus,
            tag: "Navigation",
            message: "player presented",
            attrs: ["target": .string("player"), "action": .string("present")]
        )
        #endif
        #if os(macOS)
        if let fileId {
            navigate(to: .playerWithFile(
                contentId: contentId,
                fileId: fileId,
                audioTrackIndex: audioTrackIndex,
                subtitleTrackIndex: subtitleTrackIndex,
                startFromBeginning: startFromBeginning,
                resumePosition: resumePosition,
                libraryId: libraryId
            ))
        } else {
            navigate(to: .player(
                contentId: contentId,
                startFromBeginning: startFromBeginning,
                resumePosition: resumePosition,
                prefersLastUsedVersion: prefersLastUsedVersion,
                libraryId: libraryId
            ))
        }
        #else
        var presentation = PlayerPresentation(
            libraryId: libraryId,
            contentId: contentId,
            fileId: fileId,
            audioTrackIndex: audioTrackIndex,
            subtitleTrackIndex: subtitleTrackIndex,
            startFromBeginning: startFromBeginning,
            resumePosition: resumePosition,
            prefersLastUsedVersion: prefersLastUsedVersion,
            returnToContentId: returnToContentId,
            posterURL: posterURL,
            backdropURL: backdropURL
        )
        #if os(iOS)
        presentation.detailPresentationID = presentedItemDetail?.id
        if let remotePlaybackInterceptor {
            // Decide the destination before touching `presentedPlayer`, so
            // an engaged TV never sees the local cover flash. The request
            // mirrors the values the local player would have used.
            let request = SiloControlPlaybackRequest(
                contentId: contentId,
                fileId: fileId,
                audioTrackIndex: audioTrackIndex,
                subtitleTrackIndex: subtitleTrackIndex,
                startFromBeginning: startFromBeginning,
                resumePosition: resumePosition
            )
            guard !isRoutingRemotePlayback else { return }
            // The TV is mid-title and this is a different one: ask first.
            // Same title (a Resume of what is already on) goes straight through.
            if let now = remotePlaybackCurrentTitle?(),
               now.contentId != contentId {
                pendingReplaceRemotePlayback = ReplaceRemotePlaybackChoice(
                    request: request,
                    currentTitle: now.title,
                    targetName: now.targetName
                )
                return
            }
            isRoutingRemotePlayback = true
            Task { @MainActor in
                defer { isRoutingRemotePlayback = false }
                if await remotePlaybackInterceptor(request) { return }
                presentedPlayer = presentation
            }
            return
        }
        #endif
        presentedPlayer = presentation
        #endif
    }

    /// Present offline playback of a completed download. iOS/iPadOS use a
    /// full-window cover; macOS pushes the offline player route.
    func presentOfflinePlayer(
        downloadId: String,
        contentId: String,
        startFromBeginning: Bool = false,
        resumePosition: Double? = nil
    ) {
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.recordBreadcrumb(
            category: .focus,
            tag: "Navigation",
            message: "offline player presented",
            attrs: ["target": .string("offlinePlayer"), "action": .string("present")]
        )
        #endif
        #if os(macOS)
        navigate(to: .offlinePlayer(
            downloadId: downloadId,
            contentId: contentId,
            startFromBeginning: startFromBeginning,
            resumePosition: resumePosition
        ))
        #else
        var presentation = PlayerPresentation(
            contentId: contentId,
            fileId: nil,
            audioTrackIndex: nil,
            subtitleTrackIndex: nil,
            startFromBeginning: startFromBeginning,
            resumePosition: resumePosition,
            prefersLastUsedVersion: false,
            returnToContentId: nil,
            offlineDownloadId: downloadId,
            posterURL: nil,
            backdropURL: nil
        )
        #if os(iOS)
        presentation.detailPresentationID = presentedItemDetail?.id
        #endif
        #if os(iOS)
        if isRemotePlaybackEngaged?() == true {
            pendingOfflinePlayChoice = OfflinePlayChoice(
                presentation: presentation,
                request: SiloControlPlaybackRequest(
                    contentId: contentId,
                    fileId: nil,
                    audioTrackIndex: nil,
                    subtitleTrackIndex: nil,
                    startFromBeginning: startFromBeginning,
                    resumePosition: resumePosition
                )
            )
            return
        }
        #endif
        presentedPlayer = presentation
        #endif
    }

    // MARK: - Actions

    #if os(iOS)
    /// Each presentation site sees only the player it owns.
    func playerPresentation(forDetailID detailID: UUID?) -> PlayerPresentation? {
        guard let presentedPlayer, presentedPlayer.detailPresentationID == detailID else { return nil }
        return presentedPlayer
    }

    /// An outgoing cover must not close a newer player or the detail below it.
    func dismissPlayerPresentation(id: UUID) {
        guard presentedPlayer?.id == id else { return }
        presentedPlayer = nil
    }

    /// A pull-down on a pushed actor/episode page means Back, not close sheet.
    func goBackInItemDetail() {
        guard presentedItemDetail != nil, !itemDetailPath.isEmpty else { return }
        itemDetailPath.removeLast()
    }

    func itemDetailPresentationDidDismiss() {
        // The sheet binding clears its item before this callback. A delayed
        // callback from an old sheet must not erase a newly opened detail.
        guard presentedItemDetail == nil else { return }
        itemDetailPath = NavigationPath()
    }
    #endif

    /// Push a route onto the navigation stack.
    func navigate(to route: Route) {
        #if os(iOS)
        if case .itemDetail(let contentId, _, let libraryId, let context) = route {
            presentItemDetail(contentId: contentId, libraryId: libraryId, resumeContext: context)
            return
        }
        #endif

        recordScreenBreadcrumb(target: route.diagnosticsTarget, action: "navigate")

        #if os(iOS)
        // Person pages reached from Cast & Crew belong to the detail card's
        // navigation stack. Keeping them inside the sheet means Back returns to
        // the title the user opened instead of revealing an unrelated route that
        // was pushed behind the still-presented card.
        if presentedItemDetail != nil,
           case .personDetail = route {
            itemDetailPath.append(route)
            return
        }
        #endif

        path.append(route)
    }

    /// Open an item from an ordered card source. Existing callers can keep
    /// using `navigate(to: .itemDetail(...))`; rows and grids that provide a
    /// browse source opt into sideways paging without changing deep links or
    /// nested recommendations reached from inside an already-open detail.
    func presentItemDetail(
        contentId: String,
        libraryId: Int? = nil,
        browseSource: ItemDetailBrowseSource? = nil,
        resumeContext: SeriesDetailContext? = nil
    ) {
        #if os(iOS)
        recordScreenBreadcrumb(target: "itemDetail", action: "present")
        if presentedItemDetail == nil {
            let source = browseSource.flatMap { source in
                source.contentIDs.contains(contentId) ? source : nil
            }
            itemDetailPath = NavigationPath()
            presentedItemDetail = ItemDetailPresentation(
                contentId: contentId,
                libraryId: libraryId,
                browseSource: source,
                resumeContext: resumeContext
            )
        } else {
            itemDetailPath.append(Route.itemDetail(contentId: contentId, libraryId: libraryId, seriesContext: resumeContext))
        }
        #else
        navigate(to: .itemDetail(contentId: contentId, libraryId: libraryId, seriesContext: resumeContext))
        #endif
    }

    func presentContinueWatchingDetail(for item: SectionItem, libraryId: Int? = nil, browseSource: ItemDetailBrowseSource? = nil) {
        if let context = SeriesDetailContext(item: item) {
            presentItemDetail(contentId: context.seriesContentId, libraryId: libraryId, resumeContext: context)
            return
        }
        // Movies, audio and incomplete legacy episode payloads retain their
        // existing destination; a missing parent must not make a card inert.
        presentItemDetail(contentId: item.contentId, libraryId: libraryId, browseSource: browseSource)
    }

    /// Select a sibling while the iOS detail card stays presented. Keeping the
    /// presentation UUID stable prevents SwiftUI from dismissing/reopening the
    /// sheet; only the card contents animate to the new title.
    func selectPresentedItemDetail(contentId: String) {
        #if os(iOS)
        guard var presentation = presentedItemDetail,
              presentation.contentId != contentId,
              presentation.browseSource?.contentIDs.contains(contentId) == true
        else { return }
        presentation.contentId = contentId
        presentedItemDetail = presentation
        #endif
    }

    /// Close the complete bottom-presented detail flow and discard any nested
    /// episode/person navigation so the next title always opens at its root.
    func dismissItemDetail() {
        #if os(iOS)
        presentedItemDetail = nil
        itemDetailPath = NavigationPath()
        #endif
    }

    /// Swap the top route instead of pushing, so sideways hops between
    /// sibling pages (e.g. episode → episode on the tvOS detail rail) don't
    /// stack up — Back exits the chain in one step.
    func replaceCurrent(with route: Route) {
        recordScreenBreadcrumb(target: route.diagnosticsTarget, action: "replace")
        if !path.isEmpty {
            path.removeLast()
        }
        path.append(route)
    }

    /// Pop the top route from the stack.
    func goBack() {
        guard !path.isEmpty else { return }
        recordScreenBreadcrumb(target: "previous", action: "back")
        path.removeLast()
    }

    /// Pop to root of the current navigation stack.
    func popToRoot() {
        recordScreenBreadcrumb(target: "root", action: "popToRoot")
        path = NavigationPath()
    }

    /// Return to the login screen (e.g., on sign-out).
    func resetToLogin() {
        recordScreenBreadcrumb(target: "login", action: "reset")
        path = NavigationPath()
        profileJourneyLabels = nil
        setAuthState(.needsLogin, reason: "resetToLogin")
    }

    /// Transition to profile selection after successful login.
    func showProfileSelection(journeyLabels: [String]? = nil) {
        recordScreenBreadcrumb(target: "profileSelection", action: "reset")
        path = NavigationPath()
        profileJourneyLabels = journeyLabels
        setAuthState(.needsProfile, reason: "showProfileSelection")
    }

    /// User-initiated profile switching has one persistence and cache
    /// boundary regardless of which menu or settings surface initiated it.
    func switchProfile() {
        Task {
            guard await completeRequestedProfileSwitch() else {
                // A refusal here leaves the user on the current screen with no
                // visible change, which reads as "the app ignored me".
                Self.recordAuthActionBreadcrumb(reason: "switchProfile", outcome: "refused")
                return
            }
            await MainActor.run {
                self.showProfileSelection()
            }
        }
    }

    /// Transition to the authenticated home screen.
    func resetToHome() {
        recordScreenBreadcrumb(target: "home", action: "reset")
        path = NavigationPath()
        profileJourneyLabels = nil
        setAuthState(.authenticated, reason: "resetToHome")
    }

    /// Return to server setup (e.g., to change servers).
    func resetToServerSetup() {
        recordScreenBreadcrumb(target: "serverSetup", action: "reset")
        path = NavigationPath()
        profileJourneyLabels = nil
        setAuthState(.needsServerSetup, reason: "resetToServerSetup")
    }

    /// Commit an auth state produced after validating a server selection.
    /// Every previous screen belongs to the old server/session boundary.
    func resetAfterServerResolution(to state: AuthState) {
        recordScreenBreadcrumb(target: state.diagnosticsState, action: "reset")
        PlayerIdentityBoundary.endEngagedVideoPictureInPicture()
        presentedPlayer = nil
        dismissItemDetail()
        path = NavigationPath()
        profileJourneyLabels = nil
        setAuthState(state, reason: "serverResolution")
    }

    func signOutAndReset() {
        requestSignOut(removingServer: false)
    }

    func signOutRemoveServerAndReset() {
        requestSignOut(removingServer: true)
    }

    /// One operation owns the button action through cleanup and navigation.
    /// Repeated taps cannot queue another logout behind a subsequent login.
    private func requestSignOut(removingServer: Bool) {
        guard !isSigningOut else { return }
        isSigningOut = true
        accountActionError = nil
        Task { @MainActor in
            defer { isSigningOut = false }
            #if os(tvOS)
            if await TokenStore.shared.hasTemporaryScope() {
                guard await RemotePlaybackIdentityManager.shared.end() else {
                    accountActionError = "Couldn't end remote playback. Try signing out again."
                    return
                }
            }
            #endif
            let serverID = ServerRegistry.shared.activeServerId
            let outcome = await AuthService.shared.signOutWithOutcome()
            guard outcome != .refused else {
                accountActionError = "The active session changed. Try signing out again."
                return
            }
            var durable = outcome != .localOnly
            if outcome == .diagnosticsCleanupFailed {
                accountActionError = "You're signed out, but Silo couldn't erase local diagnostics. Remove this server from the server list to retry cleanup."
            }
            if removingServer, let serverID {
                let removed = await ServerRegistry.shared.remove(serverId: serverID, resolveFallbackProfile: true)
                durable = durable || removed
                if removed { accountActionError = nil }
                if !removed {
                    accountActionError = "Silo couldn't remove the saved server. Please try again."
                }
            }
            if !durable, accountActionError == nil {
                accountActionError = "Silo couldn't clear the saved sign-in on this device. Please try signing out again."
            }
            let state: AuthState
            if !ServerRegistry.shared.hasActiveServer {
                state = .needsServerSetup
            } else if removingServer, ServerRegistry.shared.activeServerId != serverID {
                state = await RestoredSessionAuthResolver.resolveValidated()
            } else {
                state = .needsLogin
            }
            resetAfterServerResolution(to: state)
        }
    }

    private func completeRequestedProfileSwitch() async -> Bool {
        if await AuthService.shared.beginExplicitProfileSelection() {
            return true
        }
        #if os(tvOS)
        guard await RemotePlaybackIdentityManager.shared.end() else {
            return false
        }
        return await AuthService.shared.beginExplicitProfileSelection()
        #else
        return false
        #endif
    }

    /// A refresh failed for the active server. Keep the registry entry,
    /// drop tokens (already done by the refresh path), and route to the
    /// login screen so the user can re-enter credentials. If no server
    /// is active at all (e.g. all removed), fall back to server setup.
    func expiredSession() {
        path = NavigationPath()
        if ServerRegistry.shared.hasActiveServer {
            recordScreenBreadcrumb(target: "login", action: "sessionExpired")
            setAuthState(.needsLogin, reason: "sessionExpired")
        } else {
            recordScreenBreadcrumb(target: "serverSetup", action: "sessionExpired")
            setAuthState(.needsServerSetup, reason: "sessionExpiredNoServer")
        }
    }

    private func recordScreenBreadcrumb(target: String, action: String) {
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.recordBreadcrumb(
            category: .focus,
            tag: "Navigation",
            message: "screen changed",
            attrs: [
                "target": .string(target),
                "action": .string(action),
            ]
        )
        #endif
    }

    /// The auth-state timeline. Essential tier: without these lines a session
    /// report can show that the user ended up at the login screen but never
    /// why. Only the two state tokens and the router action that caused the
    /// move are recorded — no account, profile, server, or credential detail
    /// is available at this layer, and none is looked up.
    ///
    /// `state` carries the state the app is in *now*, and nothing else. The
    /// origin state goes in the free-text message rather than `phase`: the
    /// registry defines `phase` as a startup/lifecycle phase identifier
    /// (`launch`, `prefetch`, …), so filing a previous auth state under it
    /// would make `phase` mean two different things depending on which
    /// subsystem emitted the line, and a query grouping lifecycle lines by
    /// phase would silently mix them. There is no registered key for "previous
    /// state" and inventing one rejects the whole bundle, so the transition is
    /// spelled out in `msg`, where both tokens stay legible and neither is
    /// account, profile, or server identity.
    private func recordAuthStateBreadcrumb(from: AuthState, to: AuthState, reason: String) {
        #if os(iOS) || os(tvOS)
        DiagTrace.breadcrumb(
            .essential,
            category: .lifecycle,
            tag: "Auth",
            message: "auth state changed \(from.diagnosticsState) -> \(to.diagnosticsState)",
            attrs: [
                "state": .string(to.diagnosticsState),
                "reason": .string(reason),
            ]
        )
        #endif
    }

    /// Stage the cause of the `authState` assignment on the next line. Kept as
    /// a helper (rather than an inline assignment) so the pairing with the
    /// `didSet` observer stays greppable and every router action reads the
    /// same way.
    private func setAuthState(_ state: AuthState, reason: String) {
        pendingAuthStateReason = reason
        authState = state
    }

    /// Report the outcome of an async router action that can refuse before it
    /// ever reaches an `authState` assignment — a refused sign-out or profile
    /// switch is exactly the "it won't let me in" case with no other trace.
    /// Static because its call sites are inside detached `Task`s, where an
    /// instance method would mean capturing the router just to log.
    private static func recordAuthActionBreadcrumb(reason: String, outcome: String) {
        #if os(iOS) || os(tvOS)
        DiagTrace.breadcrumb(
            .essential,
            category: .lifecycle,
            tag: "Auth",
            message: "auth action completed",
            attrs: [
                "reason": .string(reason),
                "outcome": .string(outcome),
            ]
        )
        #endif
    }
}

private extension Route {
    var diagnosticsTarget: String {
        switch self {
        case .serverSetup:
            return "serverSetup"
        case .login:
            return "login"
        case .serverNeedsSetup:
            return "serverNeedsSetup"
        case .onboardingTour:
            return "onboardingTour"
        case .profileSelection:
            return "profileSelection"
        case .home:
            return "home"
        case .search:
            return "search"
        case .browse:
            return "browse"
        case .library:
            return "library"
        case .libraryCollection:
            return "libraryCollection"
        case .itemDetail:
            return "itemDetail"
        case .personDetail:
            return "personDetail"
        case .player:
            return "player"
        case .playerWithFile:
            return "playerWithFile"
        case .favorites:
            return "favorites"
        case .watchlist:
            return "watchlist"
        case .history:
            return "history"
        case .collections:
            return "collections"
        case .collectionDetail:
            return "collectionDetail"
        case .settings:
            return "settings"
        case .recommendations:
            return "recommendations"
        case .serverList:
            return "serverList"
        case .downloads:
            return "downloads"
        case .watchParty:
            return "watchParty"
        case .requestsHub:
            return "requestsHub"
        case .requestDetail:
            return "requestDetail"
        case .myRequests:
            return "myRequests"
        case .offlinePlayer:
            return "offlinePlayer"
        case .offlineSeriesBrowse:
            return "offlineSeriesBrowse"
        case .offlineDownloadDetail:
            return "offlineDownloadDetail"
        case .tvLibraryGrid:
            return "tvLibraryGrid"
        }
    }
}
