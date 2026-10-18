import SwiftUI

extension EnvironmentValues {
    /// Set only by library browse surfaces; detail destinations carry a copy in their route.
    @Entry var browseLibraryId: Int? = nil
    /// False where picking a title must not start solo playback (the Watch
    /// Party picker). Cards keep Select but drop their Play/Pause action.
    @Entry var allowsDirectPlayback = true
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
    /// Posted by `HTTPClient` when the server answers 403
    /// `profile_verification_required` to a request that carried the active
    /// profile's current proof. The object is a
    /// ``ProfileVerificationRequiredEvent``. `ContentView` hands it to
    /// `AuthService`, which runs the invalid-profile recovery and then posts
    /// ``siloProfileSelectionRequired``.
    static let siloProfileVerificationRequired = Notification.Name(
        "siloProfileVerificationRequired"
    )
}

/// Auth state machine and navigation state for every Apple platform.
/// Main-actor isolated because SwiftUI observes all of its state.
@MainActor
@Observable
final class AppRouter {

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
        /// Choose a User as the root: at launch with two or more users and
        /// none linked, when Ask For says so, or after a removal (spec §6.2).
        case needsUser(focusUserID: String?)
        /// Choose a Server as the root, for a user with two or more servers
        /// and no last server still in it (spec §6.2).
        case needsServer(userID: String, focusServerID: String?)
        /// "Sign in to…" as the root: no users yet, but servers are saved
        /// (spec §5.4).
        case needsSignInTarget(SignInContext)

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
            case .needsUser: return "needsUser"
            case .needsServer: return "needsServer"
            case .needsSignInTarget: return "needsSignInTarget"
            }
        }

        /// The first-run screens draw over the shared brand-light backdrop.
        var showsMarqueeBackdrop: Bool {
            switch self {
            case .needsServerSetup, .needsLogin, .serverRecovery, .needsProfile,
                 .needsUser, .needsServer, .needsSignInTarget: true
            case .loading, .authenticated: false
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
            // Re-read even when the state is unchanged: a server switch can
            // commit `.authenticated` over `.authenticated` under a new owner.
            authenticatedOwner = authState == .authenticated ? sessionOwner() : nil
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

    // MARK: - Return After Re-Authentication

    /// Who the app is signed in as while it shows the main screens. Read once
    /// on entering `.authenticated`, because by the time a session expires
    /// its account and profile have already been cleared.
    @ObservationIgnored private var authenticatedOwner: SessionOwner?
    /// Where the person was when their session expired. Consumed by the next
    /// `resetToHome()`.
    @ObservationIgnored private var sessionReturnPoint: SessionReturnPoint?
    /// The signed-in server, account and profile. Tests replace it.
    @ObservationIgnored var sessionOwner: () -> SessionOwner? = { SessionOwner.current() }

    // MARK: - Navigation Stack

    @ObservationIgnored private var isSigningOut = false
    var accountActionError: String?

    /// Navigation path for push/pop within the current flow.
    var path = NavigationPath()

    #if os(macOS)
    /// Routes pushed through the router, mirrored because `NavigationPath` is
    /// opaque. Entries past `path.count` are stale (the system Back button
    /// pops the path directly), so read `visiblePushedRoutes` instead.
    @ObservationIgnored private var pushedRoutes: [Route] = []

    /// The routes currently on the stack, oldest first. The Mac sidebar reads
    /// this to highlight the row that matches the page in view.
    var visiblePushedRoutes: [Route] {
        Array(pushedRoutes.prefix(path.count))
    }

    private func recordPush(_ route: Route, replacingTop: Bool = false) {
        let kept = max(0, path.count - (replacingTop ? 1 : 0))
        pushedRoutes = Array(pushedRoutes.prefix(kept)) + [route]
    }
    #endif

    // MARK: - Item Detail Presentation

    /// iPhone and iPad present catalog details as a native bottom sheet instead
    /// of pushing them into the tab or split-view navigation stack. A fresh UUID
    /// makes reopening the same title after dismissal a new presentation while
    /// keeping the content id itself available to the sheet root.
    struct ItemDetailPresentation: Identifiable, Equatable {
        let id = UUID()
        let contentId: String
        let libraryId: Int?
        let resumeContext: SeriesDetailContext?
        /// Set when the card opens on a request detail (a TMDB title) rather
        /// than a catalog item; `contentId` is then only a page identity.
        let request: RequestRoot?
        /// Presented as a sheet as large as the window instead of a page
        /// sheet. Fixed when the detail opens (see `presentsItemDetailFullWindow`), so folding
        /// or rotating never swaps the presentation, and the player above it,
        /// out from under the user.
        var fillsWindow = false

        struct RequestRoot: Equatable {
            let mediaType: RequestMediaType
            let tmdbId: Int
        }

        init(contentId: String, libraryId: Int? = nil, resumeContext: SeriesDetailContext? = nil) {
            self.contentId = contentId
            self.libraryId = libraryId
            self.resumeContext = resumeContext
            self.request = nil
        }

        init(request: RequestRoot) {
            self.contentId = "request:\(request.mediaType.rawValue):\(request.tmdbId)"
            self.libraryId = nil
            self.resumeContext = nil
            self.request = request
        }
    }

    #if os(iOS)
    var presentedItemDetail: ItemDetailPresentation?
    var itemDetailPath = NavigationPath()
    /// Kept current by the tab view: true while its window would split a
    /// detail page (see `PhoneDetailHeroLayout.usesSplitLayout`), as on an
    /// iPad or the iPhone Duo's open display held in landscape. A page sheet
    /// there is a centered card (about 930 x 710 on an 11-inch iPad) over a
    /// near-black dimmed page, so details opened then fill the window.
    var presentsItemDetailFullWindow = false

    /// Opens or restores the detail card in the presentation the window calls
    /// for now. Request details stay sheets: their page has no split layout.
    private func openItemDetail(_ presentation: ItemDetailPresentation?) {
        presentedItemDetail = presentation.map { presentation in
            var presentation = presentation
            presentation.fillsWindow = presentsItemDetailFullWindow && presentation.request == nil
            return presentation
        }
    }
    #endif

    // MARK: - Player Presentation

    /// Payload for the full-screen player cover (iOS, iPadOS, tvOS).
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
        /// The shuffle this playback starts; its `current` is `contentId`.
        var shuffle: APIv2Shuffle? = nil
        /// Hints supplied by the originating screen (e.g. the detail page,
        /// which has just loaded the catalog item) so the player's now-
        /// playing widget can publish artwork without re-fetching the
        /// catalog item solely for poster URLs. Either may be nil.
        let posterURL: String?
        let backdropURL: String?
    }

    var presentedPlayer: PlayerPresentation?

    /// The iOS detail sheet that owns a newly presented player; nil elsewhere.
    private var currentDetailPresentationID: UUID? {
        #if os(iOS)
        presentedItemDetail?.id
        #else
        nil
        #endif
    }

    @ObservationIgnored private var watchPartySheetPresented = false
    @ObservationIgnored private var pendingWatchPartyPresentation: WatchPartyPlaybackContext?

    func watchPartySheetWillPresent() { watchPartySheetPresented = true }

    func watchPartySheetDidDismiss() {
        watchPartySheetPresented = false
        if let context = pendingWatchPartyPresentation { presentWatchParty(context) }
    }

    func presentWatchParty(_ context: WatchPartyPlaybackContext?) {
        pendingWatchPartyPresentation = context
        guard let context else {
            if presentedPlayer?.watchPartyContext != nil {
                // A party sheet open over the player goes with it, and its
                // dismissal is not reliably reported.
                watchPartySheetPresented = false
                presentedPlayer = nil
            }
            return
        }
        if watchPartySheetPresented, presentedPlayer?.watchPartyContext == nil { return }
        pendingWatchPartyPresentation = nil
        guard presentedPlayer?.watchPartyContext != context else { return }
        // Reuse the active presenter's cover, including a detail-owned player.
        // Replacing its content avoids racing a dismissal with a new cover.
        presentedPlayer = PlayerPresentation(libraryId: context.libraryId,
            contentId: context.contentId, fileId: context.fileId,
            audioTrackIndex: nil, subtitleTrackIndex: nil,
            startFromBeginning: false, resumePosition: context.startPosition,
            prefersLastUsedVersion: false, returnToContentId: nil,
            detailPresentationID: presentedPlayer?.detailPresentationID ?? currentDetailPresentationID,
            watchPartyContext: context, posterURL: nil, backdropURL: nil)
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
    private(set) var isRoutingRemotePlayback = false

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
        Task { _ = await remotePlaybackInterceptor(choice.request) }
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
        Task { _ = await remotePlaybackInterceptor(choice.request) }
    }
    #endif

    // MARK: - Tab Selection

    /// One-shot tab-switch request, consumed (and cleared) by `MainTabView`,
    /// which owns the actual selection state. Routed here so leaf screens —
    /// e.g. the Downloads empty state's "Browse Libraries" — can jump tabs
    /// without threading a selection binding through the tree.
    var requestedTab: AppTab?

    /// Set by a completed sign-in, including setup from a nearby phone: a
    /// household with exactly one profile and no PIN goes straight to Home
    /// instead of a one-person picker.
    var skipsSingleProfilePicker = false

    func switchTab(to tab: AppTab) {
        requestedTab = tab
    }

    // MARK: - Search Requests

    /// Search opened with `query` filled in. A fresh `id` makes a repeated
    /// query a new request.
    struct SearchRequest: Equatable {
        let id = UUID()
        let query: String
    }

    #if os(iOS) || os(tvOS)
    /// One-shot Search request from Siri, consumed (and cleared) by the main
    /// tab view (`TVMainTabView` on tvOS), which owns tab selection and the
    /// navigation stack.
    var requestedSearch: SearchRequest?

    func requestSearch(query: String) {
        requestedSearch = SearchRequest(query: query)
    }
    #endif

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
        let presentation = PlayerPresentation(
            libraryId: libraryId,
            contentId: contentId,
            fileId: fileId,
            audioTrackIndex: audioTrackIndex,
            subtitleTrackIndex: subtitleTrackIndex,
            startFromBeginning: startFromBeginning,
            resumePosition: resumePosition,
            prefersLastUsedVersion: prefersLastUsedVersion,
            returnToContentId: returnToContentId,
            detailPresentationID: currentDetailPresentationID,
            posterURL: posterURL,
            backdropURL: backdropURL
        )
        #if os(iOS)
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
            Task {
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

    /// Play a new shuffle's first pick from its beginning. The up-next screen
    /// then offers the shuffle's picks until the viewer stops. A shuffle
    /// always plays here: an engaged TV would play the first pick alone.
    func presentShuffle(_ shuffle: APIv2Shuffle) {
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.recordBreadcrumb(
            category: .focus,
            tag: "Navigation",
            message: "player presented",
            attrs: ["target": .string("player"), "action": .string("shuffle")]
        )
        var presentation = PlayerPresentation(
            contentId: shuffle.current.contentId,
            fileId: nil,
            audioTrackIndex: nil,
            subtitleTrackIndex: nil,
            startFromBeginning: true,
            resumePosition: nil,
            prefersLastUsedVersion: false,
            returnToContentId: nil,
            detailPresentationID: currentDetailPresentationID,
            posterURL: shuffle.current.posterUrl,
            backdropURL: shuffle.current.backdropUrl
        )
        presentation.shuffle = shuffle
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
        let presentation = PlayerPresentation(
            contentId: contentId,
            fileId: nil,
            audioTrackIndex: nil,
            subtitleTrackIndex: nil,
            startFromBeginning: startFromBeginning,
            resumePosition: resumePosition,
            prefersLastUsedVersion: false,
            returnToContentId: nil,
            offlineDownloadId: downloadId,
            detailPresentationID: currentDetailPresentationID,
            posterURL: nil,
            backdropURL: nil
        )
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
        // Request detail opens in the same bottom card as a library title,
        // with its pull-down dismissal and nested navigation.
        if case .requestDetail(let mediaType, let tmdbId) = route {
            recordScreenBreadcrumb(target: route.diagnosticsTarget, action: "present")
            if presentedItemDetail == nil {
                itemDetailPath = NavigationPath()
                openItemDetail(ItemDetailPresentation(
                    request: .init(mediaType: mediaType, tmdbId: tmdbId)
                ))
            } else {
                itemDetailPath.append(route)
            }
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

        #if os(macOS)
        recordPush(route)
        #endif
        path.append(route)
    }

    /// Opens item detail.
    func presentItemDetail(
        contentId: String,
        libraryId: Int? = nil,
        resumeContext: SeriesDetailContext? = nil
    ) {
        #if os(iOS)
        recordScreenBreadcrumb(target: "itemDetail", action: "present")
        if presentedItemDetail == nil {
            itemDetailPath = NavigationPath()
            openItemDetail(ItemDetailPresentation(
                contentId: contentId,
                libraryId: libraryId,
                resumeContext: resumeContext
            ))
        } else {
            itemDetailPath.append(Route.itemDetail(contentId: contentId, libraryId: libraryId, seriesContext: resumeContext))
        }
        #else
        navigate(to: .itemDetail(contentId: contentId, libraryId: libraryId, seriesContext: resumeContext))
        #endif
    }

    func presentContinueWatchingDetail(for item: SectionItem, libraryId: Int? = nil) {
        if let context = SeriesDetailContext(item: item) {
            presentItemDetail(contentId: context.seriesContentId, libraryId: libraryId, resumeContext: context)
            return
        }
        // Movies, audio and incomplete legacy episode payloads retain their
        // existing destination; a missing parent must not make a card inert.
        presentItemDetail(contentId: item.contentId, libraryId: libraryId)
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
        #if os(macOS)
        recordPush(route, replacingTop: true)
        #endif
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

    /// Why the sign-in screen is showing, when it isn't the user's own
    /// choice. The sign-in screen explains an expired session instead of
    /// just appearing. Cleared once the user signs in or leaves sign-in.
    enum LoginNotice: Equatable {
        case sessionExpired

        /// The line the sign-in screen shows for this notice.
        func message(serverName: String) -> String {
            switch self {
            case .sessionExpired: "You were signed out of \(serverName). Sign in again."
            }
        }
    }

    private(set) var loginNotice: LoginNotice?

    // MARK: - Silo users (spec §5, plan §2.10)

    /// Why the sign-in screens are running: the server step, the placement
    /// of the sign-in, and the sign-in screen's buttons follow it.
    var signInContext: SignInContext = .firstRun
    /// Where Cancel on a sign-in returns: the user, server, and screens
    /// showing when the sign-in started. Nil for a first sign-in.
    var signInReturnPoint: SignInReturnPoint?
    /// A question a finished sign-in raised (spec §5.4.1), answered through
    /// `SiloUserCoordinator.answer`.
    var signInPrompt: SignInPrompt?
    /// A sign-out or removal waiting for its confirmation (spec §5.6).
    var removalRequest: RemovalRequest?
    /// A user being renamed (spec §5.2).
    var renameRequest: UserRenameRequest?
    /// Bumped each time a user or sign-in is opened, even when the auth
    /// state stays the same (Automatic reopening a profile under another
    /// account), so session-scoped stores re-scope.
    private(set) var signInRevision = 0
    /// The coordinator this router's flows run through. Tests replace it.
    @ObservationIgnored var usersOverride: SiloUserCoordinator?
    var users: SiloUserCoordinator { usersOverride ?? .shared }

    func noteSignInChanged() {
        signInRevision &+= 1
    }

    /// Bumped when a sign-in screen must start over in place: a question
    /// its sign-in raised was answered Cancel and the same screen shows
    /// again, with its code or form still in the finished state.
    private(set) var signInScreenGeneration = 0

    func restartSignInScreen() {
        signInScreenGeneration &+= 1
    }

    /// Choose a User as the root.
    func showUserChooser(focus userID: String?) {
        loginNotice = nil
        recordScreenBreadcrumb(target: "chooseUser", action: "reset")
        path = NavigationPath()
        setAuthState(.needsUser(focusUserID: userID), reason: "showUserChooser")
    }

    /// Choose a Server as the root.
    func showServerChooser(userID: String, focus serverID: String?) {
        loginNotice = nil
        recordScreenBreadcrumb(target: "chooseServer", action: "reset")
        path = NavigationPath()
        setAuthState(.needsServer(userID: userID, focusServerID: serverID), reason: "showServerChooser")
    }

    /// "Sign in to…" as the root.
    func showSignInTarget(_ context: SignInContext) {
        loginNotice = nil
        signInContext = context
        recordScreenBreadcrumb(target: "signInTarget", action: "reset")
        path = NavigationPath()
        setAuthState(.needsSignInTarget(context), reason: "showSignInTarget")
    }

    /// The sign-in screen for the active server, for `context`.
    func showSignIn(context: SignInContext, notice: LoginNotice? = nil) {
        signInContext = context
        loginNotice = notice
        recordScreenBreadcrumb(target: "login", action: "reset")
        path = NavigationPath()
        setAuthState(.needsLogin, reason: "showSignIn")
    }

    /// An address to fill in on the next server-setup screen (adding the
    /// server a TV sign-in link names). Read once.
    private var serverSetupPrefill: String?

    func prefillServerSetup(with url: String) { serverSetupPrefill = url }

    func consumeServerSetupPrefill() -> String? {
        defer { serverSetupPrefill = nil }
        return serverSetupPrefill
    }

    /// Return to the login screen (e.g., on sign-out).
    func resetToLogin() {
        loginNotice = nil
        sessionReturnPoint = nil
        recordScreenBreadcrumb(target: "login", action: "reset")
        path = NavigationPath()
        setAuthState(.needsLogin, reason: "resetToLogin")
    }

    /// Transition to profile selection after successful login.
    func showProfileSelection() {
        loginNotice = nil
        signInReturnPoint = nil
        recordScreenBreadcrumb(target: "profileSelection", action: "reset")
        path = NavigationPath()
        setAuthState(.needsProfile, reason: "showProfileSelection")
    }

    /// User-initiated profile switching has one persistence and cache
    /// boundary regardless of which menu or settings surface initiated it.
    func switchProfile() {
        Task { @MainActor in
            guard await completeRequestedProfileSwitch() else {
                // A refusal here leaves the user on the current screen with no
                // visible change, which reads as "the app ignored me".
                Self.recordAuthActionBreadcrumb(reason: "switchProfile", outcome: "refused")
                return
            }
            showProfileSelection()
        }
    }

    /// Transition to the authenticated home screen. After a session expiry,
    /// the same profile of the same account returns to the screens it was on.
    func resetToHome() {
        signInReturnPoint = nil
        recordScreenBreadcrumb(target: "home", action: "reset")
        let returnPoint = sessionReturnPoint
        sessionReturnPoint = nil
        path = NavigationPath()
        setAuthState(.authenticated, reason: "resetToHome")
        guard let returnPoint, returnPoint.restores(for: authenticatedOwner) else { return }
        recordScreenBreadcrumb(target: "previous", action: "restoreAfterSessionExpired")
        path = returnPoint.path
        #if os(iOS)
        itemDetailPath = returnPoint.itemDetailPath
        openItemDetail(returnPoint.itemDetail)
        #endif
    }

    /// Return to server setup (e.g., to change servers). `context` replaces
    /// the running sign-in's context when given.
    func resetToServerSetup(context: SignInContext? = nil) {
        if let context { signInContext = context }
        loginNotice = nil
        sessionReturnPoint = nil
        recordScreenBreadcrumb(target: "serverSetup", action: "reset")
        path = NavigationPath()
        skipsSingleProfilePicker = false
        setAuthState(.needsServerSetup, reason: "resetToServerSetup")
    }

    /// Commit an auth state produced after validating a server selection.
    /// Every previous screen belongs to the old server/session boundary.
    func resetAfterServerResolution(to state: AuthState) {
        loginNotice = nil
        sessionReturnPoint = nil
        signInReturnPoint = nil
        recordScreenBreadcrumb(target: state.diagnosticsState, action: "reset")
        PlayerIdentityBoundary.endEngagedVideoPictureInPicture()
        presentedPlayer = nil
        dismissItemDetail()
        path = NavigationPath()
        setAuthState(state, reason: "serverResolution")
    }

    /// Commits the route the launch resolved under the splash, with the
    /// sign-in it runs.
    func commitLaunch(_ resolution: RestoredSessionAuthResolver.LocalResolution) {
        if let context = resolution.signInContext { signInContext = context }
        loginNotice = resolution.loginNotice
        authState = resolution.state
    }

    /// Commits a resolved launch route, with the sign-in it runs.
    func resetAfterServerResolution(to resolution: RestoredSessionAuthResolver.LocalResolution) {
        if let context = resolution.signInContext { signInContext = context }
        resetAfterServerResolution(to: resolution.state)
        loginNotice = resolution.loginNotice
    }

    func signOutAndReset() {
        requestSignOut(removingServer: false)
    }

    /// "Sign In Again" after the session expired. Not a sign-out: the saved
    /// sign-in stays (other users on the device are untouched) and its
    /// sign-in screen opens, so the same person signs straight back in.
    /// Before sign-in migration, the server's own session is signed out as
    /// it always was.
    func signOutAfterSessionExpired() {
        guard !isSigningOut else { return }
        isSigningOut = true
        accountActionError = nil
        Task {
            defer { isSigningOut = false }
            guard await users.signInAgainForCurrentSession(router: self) else {
                await users.signOutCurrent(alsoRemoveServer: false, asksForAccountChoice: false, router: self)
                return
            }
        }
    }

    func signOutRemoveServerAndReset() {
        requestSignOut(removingServer: true)
    }

    #if os(iOS)
    /// A TV approval to show again once a user is chosen, added, or signed
    /// back in. ContentView takes it when it is due (`takeDueDeviceApproval`).
    private(set) var pendingDeviceApproval: DeviceApprovalLink?
    /// How deep the Choose a User that "Not you? Switch User" pushed sits
    /// on the stack. The approval waits while it shows, an Add User
    /// cancelled back to it included, and is due once the person leaves it.
    @ObservationIgnored private var deviceApprovalChooserDepth: Int?

    func takePendingDeviceApproval() -> DeviceApprovalLink? {
        defer {
            pendingDeviceApproval = nil
            deviceApprovalChooserDepth = nil
        }
        return pendingDeviceApproval
    }

    /// The waiting TV approval, once its card can show again: a signed-in
    /// screen shows (approval is account-level, so Who's Watching counts)
    /// and the Switch User chooser it waited on is gone, whether a user was
    /// picked (the current one too) or the person went back. Going back
    /// works like Cancel on the old sign-out confirmation: the card returns
    /// for the user still signed in, and nothing is left to show later.
    func takeDueDeviceApproval() -> DeviceApprovalLink? {
        guard pendingDeviceApproval != nil, authState == .authenticated || authState == .needsProfile else {
            return nil
        }
        if let depth = deviceApprovalChooserDepth, path.count >= depth { return nil }
        return takePendingDeviceApproval()
    }

    /// A TV approval link named a saved server the current user can't use
    /// right now: open its sign-in screen. The TV's code returns to the
    /// approval card after that sign-in.
    func signIn(forTVApproval link: DeviceApprovalLink, on server: ServerEntry) {
        guard !isSigningOut else { return }
        pendingDeviceApproval = link
        deviceApprovalChooserDepth = nil
        Task { @MainActor in
            guard await users.beginSignIn(forServer: server.id, router: self) else {
                pendingDeviceApproval = nil
                accountActionError = "Couldn't switch to that server. Try again."
                return
            }
        }
    }

    /// "Not you?" on a TV approval: Switch User, without signing anyone out
    /// (coordinator decision 2). The chooser offers Add User too; the TV's
    /// code returns to the approval card once a user is chosen or added, or
    /// the person goes back (`takeDueDeviceApproval`).
    func switchUser(forTVApproval link: DeviceApprovalLink) {
        guard !isSigningOut else { return }
        Task { @MainActor in
            await beginSwitchUser(forTVApproval: link)
        }
    }

    /// `switchUser(forTVApproval:)`'s work, to the chooser showing.
    func beginSwitchUser(forTVApproval link: DeviceApprovalLink) async {
        pendingDeviceApproval = link
        // Not due while the chooser opens.
        deviceApprovalChooserDepth = 0
        let depth = path.count
        await users.beginSwitchUser(router: self)
        // Pushed on top of the screens: due once the person leaves it. A
        // chooser shown as the root waits for a signed-in screen instead.
        deviceApprovalChooserDepth = path.count > depth ? path.count : nil
    }

    /// Kept for the approval card's existing call site: switching account is
    /// now Switch User, which signs nobody out.
    func switchAccount(forTVApproval link: DeviceApprovalLink, on server: ServerEntry, choosingAccount: Bool) {
        switchUser(forTVApproval: link)
    }
    #endif

    /// One operation owns the button action through cleanup and navigation.
    /// Repeated taps cannot queue another logout behind a subsequent login.
    /// `asksForAccountChoice` is false only when the session ended rather
    /// than the person signing out.
    private func requestSignOut(removingServer: Bool, asksForAccountChoice: Bool = true) {
        guard !isSigningOut else { return }
        isSigningOut = true
        accountActionError = nil
        Task {
            defer { isSigningOut = false }
            await users.signOutCurrent(alsoRemoveServer: removingServer,
                                       asksForAccountChoice: asksForAccountChoice, router: self)
        }
    }

    /// Runs a confirmed sign-out or removal through the same single flight
    /// as Sign out.
    func performRemoval(_ request: RemovalRequest, removingServer: Bool = false) {
        guard !isSigningOut else { return }
        isSigningOut = true
        accountActionError = nil
        Task {
            defer { isSigningOut = false }
            await users.perform(request, removingServer: removingServer, router: self)
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
    /// `context` is the sign-in that follows: Sign in again for a saved
    /// sign-in (spec §6.2.3).
    func expiredSession(context: SignInContext? = nil, hasActiveServer: Bool? = nil) {
        sessionReturnPoint = currentReturnPoint()
        signInReturnPoint = nil
        path = NavigationPath()
        if let context { signInContext = context }
        if hasActiveServer ?? ServerRegistry.shared.hasActiveServer {
            recordScreenBreadcrumb(target: "login", action: "sessionExpired")
            loginNotice = .sessionExpired
            setAuthState(.needsLogin, reason: "sessionExpired")
        } else {
            recordScreenBreadcrumb(target: "serverSetup", action: "sessionExpired")
            setAuthState(.needsServerSetup, reason: "sessionExpiredNoServer")
        }
    }

    /// The open screens, if there is anything beyond Home to return to.
    /// Captured before the auth-state change closes the detail card.
    private func currentReturnPoint() -> SessionReturnPoint? {
        guard authState == .authenticated, let authenticatedOwner else { return nil }
        #if os(iOS)
        guard !path.isEmpty || presentedItemDetail != nil else { return nil }
        return SessionReturnPoint(owner: authenticatedOwner, path: path,
                                  itemDetail: presentedItemDetail, itemDetailPath: itemDetailPath)
        #else
        guard !path.isEmpty else { return nil }
        return SessionReturnPoint(owner: authenticatedOwner, path: path)
        #endif
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

    /// The auth-state timeline (essential tier): the new state and the router
    /// action that caused it, with no account, profile, or server identity.
    /// The previous state goes in the message: `phase` is registered for
    /// startup phases, and an unregistered key would reject the bundle.
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

    /// Records why the next `authState` assignment happens.
    private func setAuthState(_ state: AuthState, reason: String) {
        pendingAuthStateReason = reason
        authState = state
    }

    /// Records an async router action that refused before reaching an
    /// `authState` change (a refused sign-out or profile switch).
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

/// The server, verified account and profile the app is signed in as.
/// Profile ids are unique only within an account, so all three must match.
struct SessionOwner: Equatable {
    let serverID: String
    let accountID: String
    let profileID: String

    /// Nil for a legacy session that never recorded its account, so it never
    /// restores another session's screens.
    static func current() -> SessionOwner? {
        guard let serverID = ServerRegistry.shared.activeServerId,
              let accountID = AuthService.shared.accountID,
              let profileID = AuthService.shared.profileId,
              !serverID.isEmpty, !profileID.isEmpty else { return nil }
        return SessionOwner(serverID: serverID, accountID: accountID, profileID: profileID)
    }
}

/// The screens open when a session expired, kept in memory until the next
/// sign-in reaches Home.
struct SessionReturnPoint {
    let owner: SessionOwner
    let path: NavigationPath
    #if os(iOS)
    let itemDetail: AppRouter.ItemDetailPresentation?
    let itemDetailPath: NavigationPath
    #endif

    /// Only the same profile of the same account on the same server goes
    /// back. Anyone else starts at Home, so one profile's pages never open
    /// for another.
    func restores(for owner: SessionOwner?) -> Bool {
        owner == self.owner
    }
}

private extension Route {
    var diagnosticsTarget: String {
        switch self {
        case .serverSetup:
            return "serverSetup"
        case .serverNeedsSetup:
            return "serverNeedsSetup"
        case .search:
            return "search"
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
        case .serverList:
            return "serverList"
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
        case .autoDownloads:
            return "autoDownloads"
        case .chooseUser:
            return "chooseUser"
        case .chooseServer:
            return "chooseServer"
        case .signInTarget:
            return "signInTarget"
        case .manageUsers:
            return "manageUsers"
        }
    }
}
