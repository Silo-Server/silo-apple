import SwiftUI

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
    }

    var authState: AuthState = .loading

    // MARK: - Navigation Stack

    /// Navigation path for push/pop within the current flow.
    var path = NavigationPath()

    /// Zoom-transition source id of the most recently tapped card, handed to
    /// the item-detail destination so the iOS 26 poster→detail zoom animates
    /// from the exact card tapped. A bare `contentId` collides when the same
    /// item is visible in two rows; each card uses a unique per-instance id and
    /// records it here on tap. Transient hand-off, not observable UI state.
    @ObservationIgnored var pendingZoomSourceID: String?

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
        path.append(route)
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
        authState = .needsLogin
    }

    /// Transition to profile selection after successful login.
    func showProfileSelection(journeyLabels: [String]? = nil) {
        recordScreenBreadcrumb(target: "profileSelection", action: "reset")
        path = NavigationPath()
        profileJourneyLabels = journeyLabels
        authState = .needsProfile
    }

    /// User-initiated profile switching has one persistence and cache
    /// boundary regardless of which menu or settings surface initiated it.
    func switchProfile() {
        Task {
            guard await completeRequestedProfileSwitch() else { return }
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
        authState = .authenticated
    }

    /// Return to server setup (e.g., to change servers).
    func resetToServerSetup() {
        recordScreenBreadcrumb(target: "serverSetup", action: "reset")
        path = NavigationPath()
        profileJourneyLabels = nil
        authState = .needsServerSetup
    }

    /// Sign out of the active server and land at the next sensible step:
    /// the login screen if a server entry still remembers its URL,
    /// otherwise the server-setup screen. Fire-and-forget wrapper so
    /// buttons and error-screen callbacks don't spell out a `Task`.
    func signOutAndReset() {
        Task {
            guard await completeRequestedSignOut() else { return }
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
    func signOutRemoveServerAndReset() {
        Task {
            let serverId = ServerRegistry.shared.activeServerId
            guard await completeRequestedSignOut() else { return }
            if let serverId {
                let removed = await ServerRegistry.shared.remove(
                    serverId: serverId,
                    resolveFallbackProfile: true
                )
                guard removed else {
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
            authState = .needsLogin
        } else {
            recordScreenBreadcrumb(target: "serverSetup", action: "sessionExpired")
            authState = .needsServerSetup
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
}

private extension Route {
    var diagnosticsTarget: String {
        switch self {
        case .serverSetup:
            return "serverSetup"
        case .serverNeedsSetup:
            return "serverNeedsSetup"
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
        }
    }
}
