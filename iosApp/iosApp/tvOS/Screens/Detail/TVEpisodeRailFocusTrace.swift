#if os(tvOS)
import UIKit

/// Records how focus enters and leaves the Series episode row, so a field
/// report of focus escaping it shows what the focus engine actually did.
///
/// One essential line per exit and per entry, written to the diagnostics ring
/// that "Send Diagnostics Now" freezes. An exit carries the engine's heading,
/// the type and screen frame of the item that took focus, and the row's last
/// move and how long before the exit it ran. Only type names, geometry, and
/// positions are recorded; breadcrumbs must stay free of library content.
@MainActor
final class TVEpisodeRailFocusTrace {
    private var lastMove: (direction: Int, at: ContinuousClock.Instant)?
    private var observer: NSObjectProtocol?
    /// The row's frame in global (screen) coordinates.
    var railFrame: CGRect = .null

    /// Starts observing focus updates the first time a card takes focus.
    func railFocusChanged(_ hasFocus: Bool) {
        guard hasFocus, observer == nil else { return }
        lastMove = nil
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

    /// Called when the row leaves the screen.
    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func recordMove(_ direction: Int) {
        lastMove = (direction, .now)
    }

    private func focusDidUpdate(_ context: UIFocusUpdateContext) {
        let wasInside = isInsideRail(context.previouslyFocusedItem)
        let isInside = isInsideRail(context.nextFocusedItem)
        guard wasInside != isInside else { return }
        let heading = Self.name(for: context.focusHeading)

        if isInside {
            let previous = context.previouslyFocusedItem
            DiagTrace.log(
                .essential,
                category: .focus,
                tag: "EpisodeRail",
                message: "focus entered episode row heading=\(heading) previous=\(Self.typeName(of: previous)) \(Self.geometry(of: previous))",
                attrs: [
                    "target": .string("episodeRail"),
                    "action": .string("enter.\(heading)"),
                ]
            )
            lastMove = nil
            return
        }

        let next = context.nextFocusedItem
        let nextType = Self.typeName(of: next)
        let expected = context.focusHeading == .up || context.focusHeading == .down
        DiagTrace.log(
            .essential,
            level: expected ? .info : .warning,
            category: .focus,
            tag: "EpisodeRail",
            message: "focus left episode row heading=\(heading) next=\(nextType) \(Self.geometry(of: next)) \(lastMoveSummary)",
            attrs: [
                "target": .string(nextType),
                "action": .string("exit.\(heading)"),
            ]
        )
    }

    private func isInsideRail(_ item: UIFocusItem?) -> Bool {
        guard let item, !railFrame.isNull,
              let frame = Self.screenFrame(of: item) else { return false }
        return railFrame.minY...railFrame.maxY ~= frame.midY
    }

    private var lastMoveSummary: String {
        guard let lastMove else { return "lastMove=none" }
        let elapsed = ContinuousClock.now - lastMove.at
        let ms = elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        return "lastMove=\(lastMove.direction < 0 ? "left" : "right") \(ms)ms"
    }

    private static func typeName(of item: UIFocusItem?) -> String {
        item.map { String(describing: type(of: $0)) } ?? "none"
    }

    /// SwiftUI's focus items (`UIKitFocusableViewResponderItem`) have no
    /// `focusItemContainer`; their `frame` is in the coordinate space of the
    /// nearest hosting view among their parent focus environments. Window
    /// coordinates are the screen's on tvOS.
    private static func screenFrame(of item: UIFocusItem) -> CGRect? {
        if let container = item.focusItemContainer {
            guard let screen = TVFocusSystemProbe.keyWindowScreen else { return nil }
            return container.coordinateSpace.convert(item.frame, to: screen.coordinateSpace)
        }
        var environment = item.parentFocusEnvironment
        while let current = environment, !(current is UIView) {
            environment = current.parentFocusEnvironment
        }
        guard let view = environment as? UIView, view.window != nil else { return nil }
        return view.convert(item.frame, to: nil)
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
