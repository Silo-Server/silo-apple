#if os(tvOS)
import SwiftUI
import UIKit

/// Reads and nudges the live focus engine for the app's key window.
///
/// SwiftUI exposes no way to ask "does anything on screen currently hold
/// focus?", and `@FocusState` is not an answer: the engine can drop focus
/// without writing `nil` back into a binding, which is exactly the wedge this
/// watchdog exists to catch. `UIFocusSystem` is the only source of truth.
enum TVFocusSystemProbe {
    @MainActor
    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    /// The focused item's *type* name, or `nil` when nothing is focused. Only
    /// the type is returned: a focused item's description can carry item
    /// titles, and breadcrumbs must stay free of library content.
    @MainActor
    static func focusedItemTypeName() -> String? {
        guard let window = keyWindow,
              let item = UIFocusSystem.focusSystem(for: window)?.focusedItem
        else { return nil }
        return String(describing: type(of: item))
    }

    /// Ask the engine to re-resolve focus from the window root. Used only on
    /// pushed routes, where the tvOS shell owns no focus target it could
    /// legitimately pin.
    @MainActor
    static func requestFocusUpdate() {
        guard let window = keyWindow else { return }
        window.setNeedsFocusUpdate()
        window.updateFocusIfNeeded()
    }
}

/// Watches for the focus engine losing focus entirely — no focused item, so no
/// control reacts to the remote and the app reads as hard-frozen — and fires a
/// single repair nudge per detection.
///
/// Field reports of this wedge showed the main thread alive and the top bar's
/// `@FocusState` stale at a non-nil item, so the bar's own compensating re-pin
/// never ran. Detection therefore cannot be derived from app state; it has to
/// come from the engine (`TVFocusSystemProbe`).
///
/// Per docs/tvos-focus.md the repair must not fight the engine: one nudge per
/// detected outage, rate-limited, and never a retry loop.
struct TVFocusWatchdogModifier: ViewModifier {
    /// False whenever something other than the shell legitimately owns (or
    /// suspends) focus — a presented cover, a system dialog, the background.
    /// A "no focused item" reading is not actionable in those states.
    let isActive: Bool
    let onRepair: () -> Void

    private static let checkInterval = Duration.seconds(2)
    /// Two consecutive misses (~4 s) before acting. One miss is routinely seen
    /// mid-transition, while a cover dismisses or content swaps in.
    private static let missesBeforeRepair = 2
    /// Monotonic: a wall-clock step (NTP, manual date change) must not be able
    /// to read as "the last repair was in the future" and gate repair off.
    private static let minimumTimeBetweenRepairs = Duration.seconds(5)
    private static let maximumRepairsPerOutage = 3

    @State private var consecutiveMisses = 0
    @State private var repairsThisOutage = 0
    @State private var lastRepairAt: ContinuousClock.Instant?
    @State private var repairPending = false

    func body(content: Content) -> some View {
        content
            .task(id: isActive) {
                guard isActive else {
                    resetOutageState()
                    return
                }
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.checkInterval)
                    guard !Task.isCancelled else { return }
                    check()
                }
            }
    }

    @MainActor
    private func check() {
        if let focused = TVFocusSystemProbe.focusedItemTypeName() {
            recordRecoveryIfNeeded(focused: focused)
            resetOutageState()
            return
        }

        consecutiveMisses += 1
        guard consecutiveMisses >= Self.missesBeforeRepair else { return }
        guard repairsThisOutage < Self.maximumRepairsPerOutage else { return }
        let now = ContinuousClock.now
        if let lastRepairAt, now - lastRepairAt < Self.minimumTimeBetweenRepairs {
            return
        }

        repairsThisOutage += 1
        lastRepairAt = now
        repairPending = true
        DiagnosticsCoordinator.recordBreadcrumb(
            level: .warning,
            category: .focus,
            tag: "FocusRepair",
            message: "no focused item after \(consecutiveMisses) checks; repair attempt \(repairsThisOutage)",
            attrs: [
                "target": .string("focusSystem"),
                "action": .string("repair"),
            ]
        )
        onRepair()
    }

    @MainActor
    private func recordRecoveryIfNeeded(focused: String) {
        guard consecutiveMisses >= Self.missesBeforeRepair else { return }
        // Distinguishing repaired from self-healing outages is the point of
        // this line: it tells a field report how often the wedge is real
        // versus a transient the engine would have resolved on its own.
        DiagnosticsCoordinator.recordBreadcrumb(
            category: .focus,
            tag: "FocusRepair",
            message: repairPending
                ? "focus restored after \(consecutiveMisses) checks"
                : "focus recovered unaided after \(consecutiveMisses) checks",
            attrs: [
                "target": .string(focused),
                "action": .string(repairPending ? "restoredAfterRepair" : "recoveredUnaided"),
            ]
        )
    }

    private func resetOutageState() {
        consecutiveMisses = 0
        repairsThisOutage = 0
        repairPending = false
    }
}

extension View {
    func tvFocusWatchdog(isActive: Bool, onRepair: @escaping () -> Void) -> some View {
        modifier(TVFocusWatchdogModifier(isActive: isActive, onRepair: onRepair))
    }
}
#endif
