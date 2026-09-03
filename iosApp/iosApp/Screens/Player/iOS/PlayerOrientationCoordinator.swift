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
    var mask: UIInterfaceOrientationMask { self == .portrait ? .portrait : .landscape }
}

/// Session-only policy. Locking captures an exact orientation (including the
/// landscape side); explicit rotation moves that lock without unlocking it.
struct PlayerRotationState {
    private(set) var isPlayerActive = false
    private(set) var lockedOrientation: UIInterfaceOrientationMask?
    var isLocked: Bool { lockedOrientation != nil }

    mutating func activate() {
        isPlayerActive = true
        lockedOrientation = nil
    }

    mutating func deactivate() {
        isPlayerActive = false
        lockedOrientation = nil
    }

    mutating func toggleLock(at orientation: UIInterfaceOrientationMask) {
        guard isPlayerActive else { return }
        lockedOrientation = isLocked ? nil : orientation
    }

    mutating func manuallyRotate(to orientation: UIInterfaceOrientationMask) {
        guard isPlayerActive, isLocked else { return }
        lockedOrientation = orientation
    }
}

/// Centralized orientation policy for the iOS app and player shell. Playback code
/// should stay unaware of this; the coordinator only manages UIKit masks and
/// scene geometry updates while the full-screen player is visible.
@Observable
final class PlayerOrientationCoordinator {
    static let shared = PlayerOrientationCoordinator()
    static let appDefaultOrientations: UIInterfaceOrientationMask = .portrait

    private var rotationState = PlayerRotationState()
    private(set) var observedOrientation: PlayerScreenOrientation = .portrait
    var isPlayerActive: Bool { rotationState.isPlayerActive }
    var isRotationLocked: Bool { rotationState.isLocked }

    var supportedOrientations: UIInterfaceOrientationMask {
        Self.orientationMask(isPlayerActive: isPlayerActive,
                             lockedOrientation: rotationState.lockedOrientation)
    }

    static func orientationMask(
        isPlayerActive: Bool, lockedOrientation: UIInterfaceOrientationMask? = nil
    ) -> UIInterfaceOrientationMask {
        // Info.plist must continue advertising landscape so video can use it.
        // The delegate restricts every non-player page to portrait at runtime.
        guard isPlayerActive else { return appDefaultOrientations }
        // Only the separate lock button restricts device-driven rotation.
        return lockedOrientation ?? .allButUpsideDown
    }

    static func geometryMask(
        isPlayerActive: Bool, preferredOrientation: UIInterfaceOrientationMask?,
        lockedOrientation: UIInterfaceOrientationMask? = nil
    ) -> UIInterfaceOrientationMask {
        let allowed = orientationMask(isPlayerActive: isPlayerActive, lockedOrientation: lockedOrientation)
        let requested = preferredOrientation?.intersection(allowed) ?? allowed
        // A queued landscape request cannot rotate a page after video exits.
        return requested.isEmpty ? allowed : requested
    }

    private init() {}

    func activatePlayer() {
        refreshInterfaceOrientation()
        rotationState.activate()
        applyCurrentPolicy(preferredOrientation: deviceOrientationMask())
    }

    func deactivatePlayer() {
        rotationState.deactivate()
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

    /// Read the real interface orientation for every tap. Explicit rotation
    /// works with the lock on or off, without touching the video session.
    func togglePlayerOrientation() {
        guard isPlayerActive else { return }
        refreshInterfaceOrientation()
        let target = nextPlayerOrientation
        let mask: UIInterfaceOrientationMask = target == .landscape ? preferredLandscapeMask() : .portrait
        rotationState.manuallyRotate(to: mask)
        applyCurrentPolicy(preferredOrientation: mask)
    }

    func toggleRotationLock() {
        guard isPlayerActive else { return }
        refreshInterfaceOrientation()
        let currentMask = currentInterfaceOrientation().flatMap(Self.exactMask) ?? observedOrientation.mask
        rotationState.toggleLock(at: currentMask)
        applyCurrentPolicy(preferredOrientation: rotationState.lockedOrientation ?? deviceOrientationMask())
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
                                             preferredOrientation: preferredOrientation,
                                             lockedOrientation: rotationState.lockedOrientation)
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

    private static func exactMask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask? {
        switch orientation {
        case .portrait: return .portrait
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return nil
        }
    }

    private func deviceOrientationMask() -> UIInterfaceOrientationMask {
        switch UIDevice.current.orientation {
        case .portrait: return .portrait
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        default: return currentInterfaceOrientation().flatMap(Self.exactMask) ?? .portrait
        }
    }

    private func currentInterfaceOrientation() -> UIInterfaceOrientation? {
        activeWindowScenes()
            .map(\.effectiveGeometry.interfaceOrientation)
            .first(where: { $0 != .unknown })
    }
}
#endif
