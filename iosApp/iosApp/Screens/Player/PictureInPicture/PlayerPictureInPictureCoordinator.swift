//
//  PlayerPictureInPictureCoordinator.swift
//  Continuum (iOS)
//
//  Owns the single AVPictureInPictureController for the active playback
//  session, across both render routes:
//
//    • AVPlayer route — `ContentSource(playerLayer:)`; AVKit drives transport
//      directly against the AVPlayer.
//    • PlayerCore route — `ContentSource(sampleBufferDisplayLayer:playbackDelegate:)`;
//      PlayerCore remains the sample-buffer playback delegate (transport is
//      engine-intrinsic) while this class owns the controller lifecycle.
//
//  The coordinator is app-scoped (owned by `PlaybackSessionHost`) and holds
//  the controller strongly — that is what lets PiP outlive the SwiftUI render
//  surface when the full-screen player cover is dismissed.
//

#if os(iOS)
import AVKit
import OSLog

final class PlayerPictureInPictureCoordinator: NSObject {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "PlayerPiP"
    )

    // All callbacks fire on the main thread.
    var onActiveChange: ((Bool) -> Void)?
    var onPossibleChange: ((Bool) -> Void)?
    /// The user tapped PiP's restore button. Call the completion once the
    /// full player UI is back on screen.
    var onRestoreUserInterface: ((@escaping (Bool) -> Void) -> Void)?

    private(set) var isActive = false
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private weak var boundEngine: (any PictureInPictureEngine)?
    private var autoStartEnabled = true

    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
    var isPossible: Bool { controller?.isPictureInPicturePossible ?? false }

    /// True when backgrounding the app should be expected to hand playback
    /// to PiP rather than pausing. Gates the scene-phase auto-pause.
    var isAutoStartArmed: Bool { autoStartEnabled && isPossible }

    /// Bind to the active engine (or rebuild after an engine swap). Safe to
    /// call repeatedly with the same engine.
    func bind(engine: any PictureInPictureEngine, autoStartEnabled: Bool) {
        self.autoStartEnabled = autoStartEnabled
        if boundEngine !== engine {
            unbind()
            boundEngine = engine
            engine.onPictureInPictureLayerReady = { [weak self, weak engine] in
                guard let self, let engine else { return }
                self.buildControllerIfNeeded(for: engine)
            }
        }
        buildControllerIfNeeded(for: engine)
    }

    /// Tear down the controller (session end or engine swap). Ends any
    /// on-screen PiP window. State is settled silently — callers own the
    /// surrounding lifecycle and must not be re-entered via `onActiveChange`.
    func unbind() {
        if let controller, controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        }
        possibleObservation?.invalidate()
        possibleObservation = nil
        controller?.delegate = nil
        controller = nil
        boundEngine?.onPictureInPictureLayerReady = nil
        boundEngine?.pictureInPictureDidChange(active: false)
        boundEngine = nil
        isActive = false
        onPossibleChange?(false)
    }

    func startManually() {
        controller?.startPictureInPicture()
    }

    func stop() {
        controller?.stopPictureInPicture()
    }

    func setAutomaticStart(_ enabled: Bool) {
        autoStartEnabled = enabled
        applyAutoStart()
    }

    private func applyAutoStart() {
        controller?.canStartPictureInPictureAutomaticallyFromInline = autoStartEnabled
    }

    private func buildControllerIfNeeded(for engine: any PictureInPictureEngine) {
        guard isSupported else { return }
        if controller != nil {
            applyAutoStart()
            return
        }
        guard let source = engine.makePictureInPictureContentSource() else { return }
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        possibleObservation = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] observed, _ in
            let possible = observed.isPictureInPicturePossible
            DispatchQueue.main.async {
                // Drop callbacks queued before an unbind/rebind so a stale
                // `possible` can't land on the next session's state.
                guard let self, self.controller === observed else { return }
                self.onPossibleChange?(possible)
            }
        }
        self.controller = controller
        applyAutoStart()
        Self.logger.info("[CMP-PIP] controller built")
    }
}

extension PlayerPictureInPictureCoordinator: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Self.logger.info("[CMP-PIP] did start")
        isActive = true
        boundEngine?.pictureInPictureDidChange(active: true)
        onActiveChange?(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Self.logger.info("[CMP-PIP] did stop")
        isActive = false
        boundEngine?.pictureInPictureDidChange(active: false)
        onActiveChange?(false)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Self.logger.error(
            "[CMP-PIP] failed to start: \(error.localizedDescription, privacy: .public)"
        )
        isActive = false
        onActiveChange?(false)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        Self.logger.info("[CMP-PIP] restore requested")
        if let onRestoreUserInterface {
            onRestoreUserInterface(completionHandler)
        } else {
            completionHandler(true)
        }
    }
}
#endif
