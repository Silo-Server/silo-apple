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

    init?(interfaceOrientation: UIInterfaceOrientation) {
        if interfaceOrientation.isLandscape { self = .landscape }
        else if interfaceOrientation.isPortrait { self = .portrait }
        else { return nil }
    }

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

    private(set) var isPlayerActive = false
    private(set) var observedOrientation: PlayerScreenOrientation = .portrait

    var supportedOrientations: UIInterfaceOrientationMask {
        Self.orientationMask(isPlayerActive: isPlayerActive)
    }

    static func orientationMask(isPlayerActive: Bool) -> UIInterfaceOrientationMask {
        // Info.plist must continue advertising landscape so video can use it.
        // The delegate restricts every non-player page to portrait at runtime.
        // The rotation pill is a one-time geometry request, never a lock;
        // physical phone rotation stays enabled throughout playback.
        isPlayerActive ? .allButUpsideDown : appDefaultOrientations
    }

    static func geometryMask(
        isPlayerActive: Bool, preferredOrientation: UIInterfaceOrientationMask?
    ) -> UIInterfaceOrientationMask {
        let allowed = orientationMask(isPlayerActive: isPlayerActive)
        let requested = preferredOrientation?.intersection(allowed) ?? allowed
        // A queued landscape request cannot rotate a page after video exits.
        return requested.isEmpty ? allowed : requested
    }

    private init() {}

    func activatePlayer() {
        refreshInterfaceOrientation()
        isPlayerActive = true
        applyCurrentPolicy(preferredOrientation:
            UIDevice.current.orientation.isLandscape ? preferredLandscapeMask() : .portrait)
    }

    func deactivatePlayer() {
        isPlayerActive = false
        applyCurrentPolicy(preferredOrientation: .portrait)
    }

    var nextPlayerOrientation: PlayerScreenOrientation {
        observedOrientation.toggled
    }

    func refreshInterfaceOrientation() {
        guard let current = currentInterfaceOrientation(),
              let orientation = PlayerScreenOrientation(interfaceOrientation: current) else { return }
        observedOrientation = orientation
    }

    /// Read the real interface orientation for every tap. A geometry request
    /// rotates now, without restricting subsequent device-driven rotation,
    /// changing saved settings, or touching the video session.
    func togglePlayerOrientation() {
        guard isPlayerActive else { return }
        refreshInterfaceOrientation()
        let target = nextPlayerOrientation
        applyCurrentPolicy(preferredOrientation: target == .landscape ? preferredLandscapeMask() : .portrait)
    }

    private func applyCurrentPolicy(preferredOrientation: UIInterfaceOrientationMask) {
        if Thread.isMainThread {
            updateOrientationPolicy(preferredOrientation: preferredOrientation)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.updateOrientationPolicy(preferredOrientation: preferredOrientation)
            }
        }
    }

    private func updateOrientationPolicy(preferredOrientation: UIInterfaceOrientationMask) {
        let scenes = activeWindowScenes()
        for scene in scenes {
            for window in scene.windows {
                guard let rootViewController = window.rootViewController else { continue }
                notifyOrientationChange(for: rootViewController)
            }
        }

        let geometryMask = Self.geometryMask(isPlayerActive: isPlayerActive,
                                             preferredOrientation: preferredOrientation)
        guard let scene = scenes.first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: geometryMask)) { [weak self] _ in
            guard let self else { return }
            self.refreshInterfaceOrientation()
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
