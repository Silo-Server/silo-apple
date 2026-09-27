#if os(tvOS)
import UIKit

/// Records how focus leaves the composite episode carousel, so a field report
/// of a side swipe escaping it shows what the focus engine actually did.
///
/// One essential line per exit, written to the diagnostics ring that "Send
/// Diagnostics Now" freezes. It carries the engine's heading, the type and
/// screen frame of the item that took focus, the carousel's last move and how
/// long before the exit it ran, and how often the edge fences refused focus
/// while the carousel held it. Only type names, geometry, and positions are recorded;
/// breadcrumbs must stay free of library content.
@MainActor
final class TVEpisodeRailFocusTrace {
    private weak var railItem: UIFocusItem?
    private var isArmed = false
    private var lastMove: (direction: Int, at: ContinuousClock.Instant)?
    private var fenceRefusals = 0
    private var observer: NSObjectProtocol?
    /// The carousel's frame in global (screen) coordinates.
    var railFrame: CGRect = .null

    /// Mirrors the carousel's `railHasFocus`. SwiftUI can report a change
    /// before or after the engine's own update notification — a programmatic
    /// `railHasFocus = true` reports it before the engine has moved focus at
    /// all — so the rail's focus item is whichever candidate lies inside the
    /// carousel's frame. A loss leaves the trace armed: the exit is logged
    /// from the engine's notification, which disarms it.
    func railFocusChanged(_ hasFocus: Bool) {
        guard hasFocus else { return }
        isArmed = true
        railItem = nil
        lastMove = nil
        fenceRefusals = 0
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: UIFocusSystem.didUpdateNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
                    as? UIFocusUpdateContext else { return }
                MainActor.assumeIsolated { self?.focusDidUpdate(context) }
            }
        }
        adoptIfRailItem(TVFocusSystemProbe.focusedItem())
    }

    /// Called when the carousel leaves the screen.
    func stop() {
        isArmed = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func recordMove(_ direction: Int) {
        lastMove = (direction, .now)
    }

    func recordFenceRefusal() {
        fenceRefusals += 1
    }

    private func focusDidUpdate(_ context: UIFocusUpdateContext) {
        guard isArmed else { return }
        guard let railItem else {
            adoptIfRailItem(context.nextFocusedItem)
            return
        }
        guard context.previouslyFocusedItem === railItem,
              context.nextFocusedItem !== railItem else { return }
        isArmed = false

        let heading = Self.name(for: context.focusHeading)
        let next = context.nextFocusedItem
        let nextType = next.map { String(describing: type(of: $0)) } ?? "none"
        let expected = context.focusHeading == .up || context.focusHeading == .down
        let message = [
            "focus left episode carousel",
            "heading=\(heading)",
            "next=\(nextType)",
            Self.geometry(of: next),
            lastMoveSummary,
            "fenceRefusals=\(fenceRefusals)",
        ].joined(separator: " ")

        DiagTrace.log(
            .essential,
            level: expected ? .info : .warning,
            category: .focus,
            tag: "EpisodeRail",
            message: message,
            attrs: [
                "target": .string(nextType),
                "action": .string("exit.\(heading)"),
            ]
        )
    }

    private func adoptIfRailItem(_ item: UIFocusItem?) {
        guard let item, !railFrame.isNull,
              let frame = Self.screenFrame(of: item),
              railFrame.minY...railFrame.maxY ~= frame.midY else { return }
        railItem = item
    }

    private var lastMoveSummary: String {
        guard let lastMove else { return "lastMove=none" }
        let elapsed = ContinuousClock.now - lastMove.at
        let ms = elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        return "lastMove=\(lastMove.direction < 0 ? "left" : "right") \(ms)ms"
    }

    private static func screenFrame(of item: UIFocusItem) -> CGRect? {
        guard let container = item.focusItemContainer,
              let screen = TVFocusSystemProbe.keyWindowScreen else { return nil }
        return container.coordinateSpace.convert(item.frame, to: screen.coordinateSpace)
    }

    private static func geometry(of item: UIFocusItem?) -> String {
        guard let item, let frame = screenFrame(of: item),
              let screen = TVFocusSystemProbe.keyWindowScreen else { return "frame=unknown" }
        let visibility = screen.bounds.contains(frame)
            ? "onScreen"
            : screen.bounds.intersects(frame) ? "partlyOffScreen" : "offScreen"
        return "frame=\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height)) \(visibility)"
    }

    private static func name(for heading: UIFocusHeading) -> String {
        switch heading {
        case []: "none"
        case .up: "up"
        case .down: "down"
        case .left: "left"
        case .right: "right"
        case .next: "next"
        case .previous: "previous"
        default: "raw\(heading.rawValue)"
        }
    }
}
#endif
