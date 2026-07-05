//
//  PlaybackSessionHost.swift
//  Continuum (iOS)
//
//  App-scoped owner of the live video playback session.
//
//  `PlayerViewModel` used to be owned by `PlayerView` and died with the
//  full-screen cover. Picture in Picture breaks that coupling: when the user
//  dismisses the player while PiP is floating, the session (engine, audio
//  session, server progress loop) must keep running with no SwiftUI player
//  on screen. This host owns the view model instead; `PlayerView` is a
//  renderer bound to it.
//
//  Owned by `AppRouter`. Main-thread only.
//

#if os(iOS)
import Foundation
import OSLog

@Observable
final class PlaybackSessionHost {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "PlaybackSessionHost"
    )

    /// The live view model. Non-nil whenever a session exists — including
    /// while playback continues detached in PiP with the cover dismissed.
    private(set) var viewModel: PlayerViewModel?

    /// The payload the cover was presented with, retained so the PiP restore
    /// button can re-present the same item bound to the same view model.
    private(set) var presentation: AppRouter.PlayerPresentation?

    /// True while the cover is dismissed but PiP keeps the session alive.
    private(set) var isDetachedForPictureInPicture = false

    @ObservationIgnored let pictureInPicture = PlayerPictureInPictureCoordinator()

    /// Installed by `AppRouter` — re-presents the player cover for the given
    /// payload when PiP asks to restore the full UI. Returns whether the
    /// cover was actually (re)presented.
    @ObservationIgnored var onRequestPresentation: ((AppRouter.PlayerPresentation) -> Bool)?

    @ObservationIgnored private var pendingRestoreCompletion: ((Bool) -> Void)?

    init() {
        pictureInPicture.onActiveChange = { [weak self] active in
            self?.handlePictureInPictureActiveChange(active)
        }
        pictureInPicture.onPossibleChange = { [weak self] possible in
            self?.viewModel?.isPictureInPicturePossible = possible
        }
        pictureInPicture.onRestoreUserInterface = { [weak self] completion in
            self?.restoreUserInterface(completion: completion)
        }
    }

    /// Start a fresh session for a new presentation, ending any prior one
    /// (including a session detached in PiP).
    func beginSession(for presentation: AppRouter.PlayerPresentation) {
        endSession()
        let viewModel = PlayerViewModel()
        viewModel.pictureInPicture = pictureInPicture
        self.viewModel = viewModel
        self.presentation = presentation
    }

    /// The cover finished (re)appearing. Completes an in-flight PiP restore.
    func coverDidPresent() {
        isDetachedForPictureInPicture = false
        if let completion = pendingRestoreCompletion {
            pendingRestoreCompletion = nil
            completion(true)
        }
    }

    /// Explicit close (the X button / remote dismiss). Ends the session
    /// unless PiP is active — then the cover detaches and playback floats.
    func userRequestedDismiss() {
        guard !pictureInPicture.isActive else { return }
        endSession()
    }

    /// The cover left the screen. Idempotent with `userRequestedDismiss`.
    func coverDidDismiss() {
        guard viewModel != nil else { return }
        if pictureInPicture.isActive {
            isDetachedForPictureInPicture = true
            Self.logger.info("[CMP-PIP] cover dismissed with PiP active; session detached")
            return
        }
        endSession()
    }

    func endSession() {
        if let completion = pendingRestoreCompletion {
            pendingRestoreCompletion = nil
            completion(true)
        }
        pictureInPicture.unbind()
        if let viewModel {
            // Host methods only run on the main thread (views, AVKit
            // delegates, router), but the class is not statically isolated.
            MainActor.assumeIsolated { viewModel.cleanup() }
        }
        viewModel = nil
        presentation = nil
        isDetachedForPictureInPicture = false
    }

    private func handlePictureInPictureActiveChange(_ active: Bool) {
        viewModel?.isPictureInPictureActive = active
        guard !active else { return }
        // PiP window closed. If a restore is in flight the cover is being
        // re-presented — keep the session. If the cover is down and no
        // restore is coming, nobody owns playback anymore: end it.
        if isDetachedForPictureInPicture && pendingRestoreCompletion == nil {
            endSession()
        }
    }

    private func restoreUserInterface(completion: @escaping (Bool) -> Void) {
        guard isDetachedForPictureInPicture, let presentation else {
            // Cover is still on screen (PiP was started in-app); nothing to
            // re-present.
            completion(true)
            return
        }
        pendingRestoreCompletion = completion
        let presented = onRequestPresentation?(presentation) ?? false
        if !presented {
            // Never leave AVKit's restore completion hanging — the PiP
            // window would freeze half-dismissed.
            pendingRestoreCompletion = nil
            completion(true)
        }
    }
}
#endif
