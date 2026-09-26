#if os(iOS)
import UIKit

/// Bookkeeping for one player presentation's brightness override.
///
/// `UIScreen.brightness` is device-wide and outlives the app, so the player
/// saves the user's level before its first write and hands it back when the
/// player closes or the app leaves the foreground. A session is active while
/// `originalLevel` is set.
struct PlayerBrightnessSession: Equatable {
    /// How far the screen may drift from the restored original while the app
    /// was away and still count as "the user left it alone".
    static let matchTolerance: Double = 0.02

    /// The user's level before the player's first write.
    private(set) var originalLevel: Double?
    /// The last level the player applied.
    private(set) var playerLevel: Double?
    /// True after `suspend()` wrote the original back and before the app
    /// returned or the player wrote again.
    private(set) var isSuspended = false

    /// Records a gesture write. Captures `currentLevel` as the original only
    /// when no session is active, so repeated drags keep the first baseline.
    mutating func recordApply(_ level: Double, currentLevel: Double) {
        if originalLevel == nil {
            originalLevel = currentLevel
        }
        playerLevel = level
        isSuspended = false
    }

    /// The app left `.active`. Returns the original level to write, or nil
    /// when no session is active or it is already suspended. Keeps
    /// `playerLevel` so `resume(currentLevel:)` can re-apply it.
    mutating func suspend() -> Double? {
        guard let originalLevel, !isSuspended else { return nil }
        isSuspended = true
        return originalLevel
    }

    /// The app is `.active` again. Returns the player level to re-apply when
    /// the screen is still at the restored original. When the user changed
    /// brightness while away, ends the session and returns nil so their level
    /// stays. Does nothing when not suspended.
    mutating func resume(currentLevel: Double) -> Double? {
        guard isSuspended, let originalLevel else { return nil }
        guard abs(currentLevel - originalLevel) <= Self.matchTolerance else {
            self = PlayerBrightnessSession()
            return nil
        }
        isSuspended = false
        return playerLevel
    }

    /// The player presentation ended. Returns the original level to write
    /// when a session is active and not suspended; a suspended session has
    /// already written it. Always resets to the empty state.
    mutating func end() -> Double? {
        let restoreLevel = isSuspended ? nil : originalLevel
        self = PlayerBrightnessSession()
        return restoreLevel
    }
}

/// The part of `UIScreen` the player changes. Tests substitute a stand-in,
/// because simulator brightness is global device state with no visible effect.
@MainActor
protocol PlayerBrightnessScreen: AnyObject {
    var brightness: CGFloat { get set }
}

extension UIScreen: PlayerBrightnessScreen {}

/// Applies `PlayerBrightnessSession` decisions to the screen the player
/// wrote to. `PlayerView` owns the lifecycle (`suspend`/`resume` on
/// `scenePhase`, `restore` on disappear) because the gesture layer remounts
/// mid-session on reloads and would restore at the wrong time.
@MainActor
final class PlayerScreenBrightness {
    static let shared = PlayerScreenBrightness { PlayerScreenBrightness.foregroundActiveScreen }

    private var session = PlayerBrightnessSession()
    /// The screen the session's first write targeted. Remembered because the
    /// `.foregroundActive` lookup finds nothing once the scene resigns
    /// active, which is exactly when `suspend()` must write. Weak because
    /// UIKit owns the screen; cleared whenever the session empties so the
    /// next session resolves it afresh.
    private weak var screen: (any PlayerBrightnessScreen)?
    /// Finds the screen for a session that has none yet.
    private let foregroundScreen: @MainActor () -> (any PlayerBrightnessScreen)?

    init(foregroundScreen: @escaping @MainActor () -> (any PlayerBrightnessScreen)?) {
        self.foregroundScreen = foregroundScreen
    }

    /// Drag baseline: the session's screen, else the foreground screen,
    /// else mid-level.
    func currentLevel() -> Double {
        guard let screen = screen ?? foregroundScreen() else { return 0.5 }
        return Double(screen.brightness)
    }

    /// Writes a gesture level, saving the user's level first if this is the
    /// session's first write.
    func apply(_ level: Double) {
        guard let screen = screen ?? foregroundScreen() else { return }
        self.screen = screen
        let clamped = Self.clamp(level)
        session.recordApply(clamped, currentLevel: Double(screen.brightness))
        screen.brightness = CGFloat(clamped)
    }

    /// `scenePhase` left `.active`. Apple QA1751: once the app leaves the
    /// foreground, `UIScreen.brightness` writes have no effect, so the
    /// original has to go back at resign-active, not at background.
    func suspend() {
        write(session.suspend())
    }

    /// `scenePhase` returned to `.active`. Re-applies the player level
    /// unless the user changed brightness while away, which ends the session.
    func resume() {
        guard let screen else { return }
        let level = session.resume(currentLevel: Double(screen.brightness))
        write(level)
        if session.originalLevel == nil {
            self.screen = nil
        }
    }

    /// The player closed. Puts the user's level back if the gesture changed
    /// it and a suspend has not already done so.
    func restore() {
        write(session.end())
        screen = nil
    }

    private func write(_ level: Double?) {
        guard let level, let screen else { return }
        screen.brightness = CGFloat(Self.clamp(level))
    }

    private static func clamp(_ level: Double) -> Double {
        min(max(level, 0), 1)
    }

    /// Screen hosting the app's foreground scene. `UIScreen.main` is
    /// deprecated on iOS 26; the player always lives in the single
    /// foreground window scene, so resolving through the scene list is
    /// equivalent.
    private static var foregroundActiveScreen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .screen
    }
}
#endif
