import OSLog
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
    static let continuumSessionExpired = Notification.Name("continuumSessionExpired")
    /// Posted when a playback-only remote handoff session expires. The TV
    /// restores its persistent identity instead of routing the app to login.
    static let temporaryRemoteAuthExpired = Notification.Name("temporaryRemoteAuthExpired")
    /// Posted when the account remains valid but the selected profile was
    /// removed or its saved PIN proof is no longer accepted.
    static let continuumProfileSelectionRequired = Notification.Name(
        "continuumProfileSelectionRequired"
    )
}

/// Central navigation controller for the Continuum iOS app.
///
/// Manages the authentication state machine and the navigation stack.
/// Observed by ContentView to decide which screen tree to present.
@Observable
class AppRouter {

    /// Outcomes on the post-erasure sign-out paths can only go here: the
    /// diagnostics binding is purged before control returns, so a breadcrumb
    /// would be dropped. See `signOutAndReset`.
    @ObservationIgnored private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "AppRouter"
    )

    // MARK: - Auth State Machine

    enum AuthState: Equatable {
        /// App is launching; checking for stored credentials.
        case loading
        /// No server URL has been configured yet.
        case needsServerSetup
        /// Server known but user is not signed in.
        case needsLogin
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

        init(contentId: String, browseSource: ItemDetailBrowseSource? = nil) {
            self.contentId = contentId
            self.browseSource = browseSource
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
        let id = UUID()
        let contentId: String
        let fileId: Int?
        let audioTrackIndex: Int?
        let subtitleTrackIndex: Int?
        let startFromBeginning: Bool
        let resumePosition: Double?
        /// Optional detail destination to install behind the full-screen
        /// player once playback has actually started.
        let returnToContentId: String?
        /// Set for offline playback of a completed download.
        var offlineDownloadId: String? = nil
        /// Hints supplied by the originating screen (e.g. the detail page,
        /// which has just loaded the catalog item) so the player's now-
        /// playing widget can publish artwork without re-fetching the
        /// catalog item solely for poster URLs. Either may be nil.
        let posterURL: String?
        let backdropURL: String?
    }

    var presentedPlayer: PlayerPresentation?

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
        fileId: Int? = nil,
        audioTrackIndex: Int? = nil,
        subtitleTrackIndex: Int? = nil,
        startFromBeginning: Bool = false,
        resumePosition: Double? = nil,
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
                resumePosition: resumePosition
            ))
        } else {
            navigate(to: .player(
                contentId: contentId,
                startFromBeginning: startFromBeginning,
                resumePosition: resumePosition
            ))
        }
        #else
        presentedPlayer = PlayerPresentation(
            contentId: contentId,
            fileId: fileId,
            audioTrackIndex: audioTrackIndex,
            subtitleTrackIndex: subtitleTrackIndex,
            startFromBeginning: startFromBeginning,
            resumePosition: resumePosition,
            returnToContentId: returnToContentId,
            posterURL: posterURL,
            backdropURL: backdropURL
        )
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
        presentedPlayer = PlayerPresentation(
            contentId: contentId,
            fileId: nil,
            audioTrackIndex: nil,
            subtitleTrackIndex: nil,
            startFromBeginning: startFromBeginning,
            resumePosition: resumePosition,
            returnToContentId: nil,
            offlineDownloadId: downloadId,
            posterURL: nil,
            backdropURL: nil
        )
        #endif
    }

    // MARK: - Actions

    /// Push a route onto the navigation stack.
    func navigate(to route: Route) {
        recordScreenBreadcrumb(target: route.diagnosticsTarget, action: "navigate")

        #if os(iOS)
        if case .itemDetail(let contentId) = route {
            presentItemDetail(contentId: contentId)
            return
        }

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
        browseSource: ItemDetailBrowseSource? = nil
    ) {
        #if os(iOS)
        if presentedItemDetail == nil {
            let source = browseSource.flatMap { source in
                source.contentIDs.contains(contentId) ? source : nil
            }
            itemDetailPath = NavigationPath()
            presentedItemDetail = ItemDetailPresentation(
                contentId: contentId,
                browseSource: source
            )
        } else {
            itemDetailPath.append(Route.itemDetail(contentId: contentId))
        }
        #else
        navigate(to: .itemDetail(contentId: contentId))
        #endif
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

    /// Sign out of the active server and land at the next sensible step:
    /// the login screen if a server entry still remembers its URL,
    /// otherwise the server-setup screen. Fire-and-forget wrapper so
    /// buttons and error-screen callbacks don't spell out a `Task`.
    ///
    /// Only the refusal is breadcrumbed, and that is not an oversight.
    ///
    /// A successful `completeRequestedSignOut()` has already run
    /// `AuthService.signOut()`, which purges the current diagnostics binding
    /// and then every binding for the signed-out server. That purge drops the
    /// live breadcrumb consent context *and* the last-known status snapshot it
    /// would otherwise fall back to, so no context resolves and capture is off
    /// by the time control returns here. A `succeeded` line would be offered to
    /// a disabled journal — whose directory the same purge just deleted — and
    /// dropped. The auth-state transition that `resetToLogin()` /
    /// `resetToServerSetup()` record below is in the same position and equally
    /// silent; both wait on the next account's first status refresh to reopen
    /// the gate, which is exactly the erasure working as intended.
    ///
    /// Re-emitting either one afterwards is not an option worth taking. This is
    /// a post-erasure path: the user asked to be signed out, and reviving a
    /// journal after the account's diagnostics were deleted — even with a
    /// line carrying no identifiers — would put the signed-out session's tail
    /// in front of whoever signs in next.
    ///
    /// The refusal keeps its line because a refusal purges nothing: the
    /// authorization check fails before any diagnostics work, so the gate is
    /// still open and "it won't let me sign out" stays answerable.
    func signOutAndReset() {
        Task {
            guard await completeRequestedSignOut() else {
                Self.recordAuthActionBreadcrumb(reason: "signOut", outcome: "refused")
                return
            }
            await MainActor.run {
                if ServerRegistry.shared.hasActiveServer {
                    self.resetToLogin()
                } else {
                    self.resetToServerSetup()
                }
            }
        }
    }

    /// Sign out and forget the active server entirely. If another saved
    /// server becomes active, re-enter its existing auth state; otherwise
    /// return to server setup.
    ///
    /// Breadcrumbed exactly like `signOutAndReset`, for the same reason and
    /// with one addition. Past the sign-out guard the binding purge has already
    /// run, so neither the `removeFailed` half-state nor the success can be
    /// recorded. The removal that follows then crosses an identity boundary of
    /// its own — `ServerRegistry.remove` closes the capture gate for an active
    /// server and reopens it only asynchronously — so a line here would be
    /// blocked twice over even if the purge had not already erased the context.
    func signOutRemoveServerAndReset() {
        Task {
            let serverId = ServerRegistry.shared.activeServerId
            guard await completeRequestedSignOut() else {
                Self.recordAuthActionBreadcrumb(reason: "signOutRemoveServer", outcome: "refused")
                return
            }
            if let serverId {
                let removed = await ServerRegistry.shared.remove(
                    serverId: serverId,
                    resolveFallbackProfile: true
                )
                guard removed else {
                    // Signed out but the entry survived: the user lands back at
                    // login for a server they asked to forget. The two halves
                    // disagreeing is the actual bug, and it is visible only in
                    // OSLog — see this function's doc comment.
                    Self.logger.error("signOutRemoveServer signed out but the entry survived")
                    await MainActor.run { self.resetToLogin() }
                    return
                }
            }
            await MainActor.run {
                let auth = AuthService.shared
                if !auth.hasServer {
                    self.resetToServerSetup()
                } else if !auth.isLoggedIn {
                    self.resetToLogin()
                } else if !auth.hasProfile {
                    self.showProfileSelection()
                } else {
                    self.resetToHome()
                }
            }
        }
    }

    /// A user-initiated tvOS sign-out first retires a playback-only overlay if
    /// it owns request authentication, then retries against the persistent
    /// account. Other refusals leave navigation and credentials untouched.
    private func completeRequestedSignOut() async -> Bool {
        if await AuthService.shared.signOut() {
            return true
        }
        #if os(tvOS)
        guard await RemotePlaybackIdentityManager.shared.end() else {
            return false
        }
        return await AuthService.shared.signOut()
        #else
        return false
        #endif
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
