#if os(iOS)
import Observation
import UIKit

/// SwiftUI app delegate bridge used only so UIKit asks our shared coordinator
/// which orientations are currently allowed.
final class SiloAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        PlayerOrientationCoordinator.shared.supportedOrientations
    }
}

enum PlayerScreenOrientation: Equatable {
    case portrait
    case landscape

    var toggled: Self { self == .portrait ? .landscape : .portrait }
    var title: String { self == .portrait ? "Portrait" : "Landscape" }
    var symbolName: String { self == .portrait ? "rectangle.portrait" : "rectangle" }
    var mask: UIInterfaceOrientationMask { self == .portrait ? .portrait : .landscape }
}

/// Centralized orientation policy for the iOS app and player shell. Playback code
/// should stay unaware of this; the coordinator only manages UIKit masks and
/// scene geometry updates while the full-screen player is visible.
@Observable
final class PlayerOrientationCoordinator {
    static let shared = PlayerOrientationCoordinator()
    static let appDefaultOrientations: UIInterfaceOrientationMask = .portrait

    private(set) var playerMode = PlayerSettings.shared.playerOrientationMode
    private(set) var isPlayerActive = false
    private(set) var requestedOrientation: PlayerScreenOrientation?
    private(set) var observedOrientation: PlayerScreenOrientation = .portrait

    var supportedOrientations: UIInterfaceOrientationMask {
        Self.orientationMask(isPlayerActive: isPlayerActive, playerMode: playerMode,
                             requestedOrientation: requestedOrientation)
    }

    static func orientationMask(
        isPlayerActive: Bool, playerMode: PlayerOrientationMode,
        requestedOrientation: PlayerScreenOrientation? = nil
    ) -> UIInterfaceOrientationMask {
        guard isPlayerActive else { return appDefaultOrientations }
        if let requestedOrientation { return requestedOrientation.mask }
        // Info.plist must continue advertising landscape so video can use it.
        // The delegate restricts every non-player page to portrait at runtime.
        return playerMode.isLandscapeLocked ? .landscape : .allButUpsideDown
    }

    private init() {}

    var isLandscapeLocked: Bool {
        playerMode.isLandscapeLocked
    }

    func activatePlayer() {
        playerMode = PlayerSettings.shared.playerOrientationMode
        requestedOrientation = nil
        refreshInterfaceOrientation()
        isPlayerActive = true
        applyCurrentPolicy(rotateIntoLandscape: playerMode.isLandscapeLocked)
    }

    func deactivatePlayer() {
        isPlayerActive = false
        requestedOrientation = nil
        applyCurrentPolicy(rotateIntoLandscape: false, attemptDeviceRotation: true)
    }

    var nextPlayerOrientation: PlayerScreenOrientation {
        (requestedOrientation ?? observedOrientation).toggled
    }

    func refreshInterfaceOrientation() {
        guard let current = currentInterfaceOrientation(), current != .unknown else { return }
        observedOrientation = current.isLandscape ? .landscape : .portrait
    }

    /// An explicit rotation for this playback session, without changing the
    /// profile's saved auto-rotation setting or reloading the video.
    func togglePlayerOrientation() {
        guard isPlayerActive else { return }
        refreshInterfaceOrientation()
        let target = nextPlayerOrientation
        requestedOrientation = target
        applyCurrentPolicy(rotateIntoLandscape: target == .landscape, attemptDeviceRotation: true)
    }

    func togglePlayerMode() {
        setPlayerMode(playerMode.isLandscapeLocked ? .rotateFreely : .landscapeLocked)
    }

    func setPlayerMode(_ mode: PlayerOrientationMode) {
        guard playerMode != mode || requestedOrientation != nil else { return }
        requestedOrientation = nil
        playerMode = mode
        PlayerSettings.shared.setPlayerOrientationMode(mode)
        guard isPlayerActive else { return }
        applyCurrentPolicy(
            rotateIntoLandscape: mode.isLandscapeLocked,
            attemptDeviceRotation: !mode.isLandscapeLocked
        )
    }

    private func applyCurrentPolicy(
        rotateIntoLandscape: Bool,
        attemptDeviceRotation: Bool = false
    ) {
        if Thread.isMainThread {
            updateOrientationPolicy(
                rotateIntoLandscape: rotateIntoLandscape,
                attemptDeviceRotation: attemptDeviceRotation
            )
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.updateOrientationPolicy(
                    rotateIntoLandscape: rotateIntoLandscape,
                    attemptDeviceRotation: attemptDeviceRotation
                )
            }
        }
    }

    private func updateOrientationPolicy(
        rotateIntoLandscape: Bool,
        attemptDeviceRotation: Bool
    ) {
        let scenes = activeWindowScenes()
        for scene in scenes {
            for window in scene.windows {
                guard let rootViewController = window.rootViewController else { continue }
                notifyOrientationChange(for: rootViewController)
            }
        }

        // `requestGeometryUpdate(.iOS(interfaceOrientations:))` is the iOS 16+
        // replacement for the deprecated `attemptRotationToDeviceOrientation`
        // — it rotates the device on its own once `notifyOrientationChange`
        // has refreshed each VC's `supportedInterfaceOrientations`. The
        // `attemptDeviceRotation` flag is therefore only meaningful as a
        // signal that a follow-up policy refresh is desired post-rotate.
        let geometryMask = rotateIntoLandscape ? preferredLandscapeMask() : supportedOrientations
        guard let scene = scenes.first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: geometryMask)) { [weak self] _ in
            guard attemptDeviceRotation, let self else { return }
            for window in scene.windows {
                guard let rootViewController = window.rootViewController else { continue }
                self.notifyOrientationChange(for: rootViewController)
            }
        }
    }

    private func notifyOrientationChange(for viewController: UIViewController) {
        viewController.setNeedsUpdateOfSupportedInterfaceOrientations()
        if let navigationController = viewController as? UINavigationController {
            navigationController.visibleViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        if let tabBarController = viewController as? UITabBarController {
            tabBarController.selectedViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        if let presentedViewController = viewController.presentedViewController {
            notifyOrientationChange(for: presentedViewController)
        }
        for child in viewController.children {
            notifyOrientationChange(for: child)
        }
    }

    private func activeWindowScenes() -> [UIWindowScene] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter {
                $0.activationState == .foregroundActive
                    || $0.activationState == .foregroundInactive
            }
    }

    private func preferredLandscapeMask() -> UIInterfaceOrientationMask {
        if let interfaceOrientation = currentInterfaceOrientation() {
            switch interfaceOrientation {
            case .landscapeLeft:
                return .landscapeLeft
            case .landscapeRight:
                return .landscapeRight
            default:
                break
            }
        }

        switch UIDevice.current.orientation {
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        default:
            return .landscapeRight
        }
    }

    private func currentInterfaceOrientation() -> UIInterfaceOrientation? {
        activeWindowScenes()
            .map(\.effectiveGeometry.interfaceOrientation)
            .first(where: { $0 != .unknown })
    }
}
#endif
