#if os(tvOS)
import SwiftUI
import UIKit

/// Debug overlay that marks where the tvOS focus engine will land for
/// each d-pad direction from the currently focused control.
///
/// UIKit exposes no public "next focused item in direction" query, so the
/// primary path asks the engine itself through runtime-resolved private
/// classes (`FocusEngineQuery`): it builds the same `_UIFocusMovementRequest`
/// a d-pad press produces and runs it through the focus system's movement
/// performer, which honors focus guides, occlusion, and group rules. Two
/// cases fall back to a geometric heuristic over every `UIFocusItem` in
/// the window: the private internals going missing (OS change), and the
/// engine reporting a failed movement — on tvOS SwiftUI resolves failed
/// moves itself via `.focusSection()` hops that aren't queryable from
/// UIKit. Heuristic markers carry a `?` badge so a guess isn't mistaken
/// for engine output.
///
/// Lives in its own passthrough window (`TVFocusDebugOverlayController`)
/// so it renders above full-screen covers and can never receive focus or
/// touches itself.
struct TVFocusDebugOverlay: View {
    @State private var snapshot = FocusDebugSnapshot()

    /// Layout can settle after the focus notification fires (scroll-to
    /// animations, lazy grids); a slow tick keeps the markers honest.
    private let settleTick = Timer.publish(every: 0.75, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        ZStack {
            if let focused = snapshot.focusedFrame {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        .white.opacity(0.85),
                        style: StrokeStyle(lineWidth: 3, dash: [10, 8])
                    )
                    .frame(width: focused.width, height: focused.height)
                    .position(x: focused.midX, y: focused.midY)
            }

            ForEach(snapshot.targets) { target in
                marker(for: target)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { refresh() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIFocusSystem.didUpdateNotification
            )
        ) { _ in refresh() }
        .onReceive(settleTick) { _ in refresh() }
    }

    private func marker(for target: FocusDebugSnapshot.Target) -> some View {
        let rect = target.frame
        let color = target.direction.color
        let suffix = target.isHeuristic ? " ?" : (target.isScrollRegion ? " · SCROLLS" : "")
        return RoundedRectangle(cornerRadius: 12)
            .stroke(
                color,
                style: target.isScrollRegion
                    ? StrokeStyle(lineWidth: 4, dash: [12, 8])
                    : StrokeStyle(lineWidth: 5)
            )
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(color.opacity(0.14))
            )
            .overlay(alignment: .topLeading) {
                Text(target.direction.badge + suffix)
                    .font(.system(size: 21, weight: .bold, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(color, in: Capsule())
                    .offset(x: 8, y: -16)
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    private func refresh() {
        let next = FocusDebugSnapshot.capture()
        if next != snapshot {
            snapshot = next
        }
    }
}

// MARK: - Snapshot

struct FocusDebugSnapshot: Equatable {
    /// Frame of the currently focused item, in window coordinates.
    var focusedFrame: CGRect?
    /// Predicted destination per direction (directions with no candidate
    /// are absent).
    var targets: [Target] = []

    struct Target: Equatable, Identifiable {
        let direction: Direction
        let frame: CGRect
        /// True when the frame came from the geometric fallback rather
        /// than the real focus engine.
        var isHeuristic = false
        /// True when the engine answered with a scroll placeholder: the
        /// destination control isn't materialized yet, so the marker is a
        /// strip at the edge the next row/column will scroll in from.
        var isScrollRegion = false
        var id: Direction { direction }
    }

    enum Direction: CaseIterable {
        case up, down, left, right

        var badge: String {
            switch self {
            case .up: return "▲ UP"
            case .down: return "▼ DOWN"
            case .left: return "◀ LEFT"
            case .right: return "▶ RIGHT"
            }
        }

        var focusHeading: UIFocusHeading {
            switch self {
            case .up: return .up
            case .down: return .down
            case .left: return .left
            case .right: return .right
            }
        }

        var color: Color {
            switch self {
            case .up: return .green
            case .down: return .orange
            case .left: return .cyan
            case .right: return .pink
            }
        }
    }

    // MARK: Capture

    @MainActor
    static func capture() -> FocusDebugSnapshot {
        guard let window = appKeyWindow(),
              let focusedItem = UIFocusSystem.focusSystem(for: window)?.focusedItem
        else {
            return FocusDebugSnapshot()
        }

        var frames: [(item: UIFocusItem, frame: CGRect)] = []
        var visitedContainers = Set<ObjectIdentifier>()
        var seenItems = Set<ObjectIdentifier>()
        collectFocusItems(
            in: window,
            window: window,
            frames: &frames,
            visitedContainers: &visitedContainers,
            seenItems: &seenItems,
            depth: 0
        )

        let focusedFrame = frames.first { $0.item === focusedItem }?.frame
            ?? (focusedItem as? UIView)?.convert(
                (focusedItem as? UIView)?.bounds ?? .zero, to: window
            )
        guard let focusedFrame else { return FocusDebugSnapshot() }

        // The plausibility filter applies to guesses too: SwiftUI vends
        // scroll-anchor items with region-sized frames, and a heuristic
        // that considers them repaints the same giant box the engine
        // placeholder filter just rejected.
        let candidates = frames
            .filter { $0.item !== focusedItem }
            .map(\.frame)
            .filter { isPlausibleTargetFrame($0, in: window) }

        let targets = Direction.allCases.compactMap { direction -> Target? in
            // Primary path: ask the actual focus engine. A non-nil answer
            // is exact. A nil answer means UIKit's search failed; the
            // geometric heuristic then guesses (marked `?`). Known gap:
            // SwiftUI catches failed moves and performs its own
            // `.focusSection()` hop (verified: a real Up press from a home
            // card fires `movementDidFailNotification`, then SwiftUI moves
            // focus into the top menu) — but SwiftUI vends only the active
            // section's items to UIKit, so neither the engine nor the
            // heuristic can see those destinations. No marker is drawn for
            // a cross-section hop.
            if FocusEngineQuery.isAvailable,
               let item = FocusEngineQuery.nextFocusedItem(
                   from: focusedItem,
                   heading: direction.focusHeading,
                   in: window
               ), item !== focusedItem {
                let frame = frames.first { $0.item === item }?.frame
                    ?? (item as? UIView).map { $0.convert($0.bounds, to: window) }
                    ?? frameByWalkingContainers(of: item, in: window)
                if let frame {
                    if isRealControl(item), isPlausibleTargetFrame(frame, in: window) {
                        return Target(direction: direction, frame: frame)
                    }
                    // Placeholder answer: the destination is inside
                    // unmaterialized scrollable content, so no API can
                    // name the control yet. Mark the edge of the region
                    // the next row/column scrolls in from instead.
                    if let strip = scrollStrip(
                        direction: direction,
                        region: frame,
                        focused: focusedFrame,
                        in: window
                    ) {
                        return Target(
                            direction: direction, frame: strip, isScrollRegion: true
                        )
                    }
                }
            }

            // Engine found nothing — the moment SwiftUI performs its
            // section hop into the top menu. The bar publishes where that
            // hop deterministically lands (the selected tab), so draw it
            // as a real target. Guarded to "hint is above the focused
            // item" so a focused tab never points at itself.
            if direction == .up,
               let hint = TVFocusDebugHints.shared.topMenuSelectedTabFrame,
               hint.midY < focusedFrame.minY,
               isPlausibleTargetFrame(hint, in: window) {
                return Target(direction: .up, frame: hint)
            }

            return bestCandidate(
                from: focusedFrame, among: candidates, direction: direction
            ).map { Target(direction: direction, frame: $0, isHeuristic: true) }
        }

        return FocusDebugSnapshot(focusedFrame: focusedFrame, targets: targets)
    }

    /// When the destination lies in scrollable content that isn't
    /// materialized yet, the engine answers with a placeholder ("dummy")
    /// item whose frame is the entire scroll-and-search region rather
    /// than the control focus will actually land on (UIKit scrolls and
    /// re-resolves afterwards). Drawing that literally paints a huge box
    /// over the screen — filter placeholders by class name and by
    /// implausibly large frames, and let the geometric heuristic guess
    /// the concrete control instead.
    private static func isRealControl(_ item: UIFocusItem) -> Bool {
        let className = String(describing: type(of: item)).lowercased()
        return !className.contains("dummy") && !className.contains("placeholder")
    }

    /// A compact marker for scroll-placeholder answers: focused-control
    /// sized, aligned with the focused control on the cross axis, hugging
    /// the region edge nearest the focused control — where the next
    /// row/column surfaces when the scroll happens.
    private static func scrollStrip(
        direction: Direction,
        region: CGRect,
        focused: CGRect,
        in window: UIWindow
    ) -> CGRect? {
        let visible = region.intersection(window.bounds)
        guard !visible.isEmpty else { return nil }
        let thickness: CGFloat = 72

        var strip: CGRect
        switch direction {
        case .up:
            strip = CGRect(
                x: focused.minX, y: visible.maxY - thickness,
                width: focused.width, height: thickness
            )
        case .down:
            strip = CGRect(
                x: focused.minX, y: visible.minY,
                width: focused.width, height: thickness
            )
        case .left:
            strip = CGRect(
                x: visible.maxX - thickness, y: focused.minY,
                width: thickness, height: focused.height
            )
        case .right:
            strip = CGRect(
                x: visible.minX, y: focused.minY,
                width: thickness, height: focused.height
            )
        }

        strip = strip.intersection(window.bounds)
        return strip.isEmpty ? nil : strip
    }

    private static func isPlausibleTargetFrame(
        _ frame: CGRect, in window: UIWindow
    ) -> Bool {
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else { return false }
        let visible = frame.intersection(bounds)
        guard !visible.isEmpty else { return false }
        let areaShare = (visible.width * visible.height)
            / (bounds.width * bounds.height)
        return areaShare < 0.3
            && visible.width < bounds.width * 0.85
            && visible.height < bounds.height * 0.85
    }

    /// Last-resort frame lookup for engine-returned items that are not
    /// `UIView`s and were missed by the container sweep: `item.frame` is
    /// defined in its containing container's coordinate space, and the
    /// nearest ancestor environment exposing a container is that space.
    private static func frameByWalkingContainers(
        of item: UIFocusItem, in window: UIWindow
    ) -> CGRect? {
        var environment = item.parentFocusEnvironment
        var hops = 0
        while let current = environment, hops < 30 {
            if let container = current.focusItemContainer {
                let frame = container.coordinateSpace.convert(
                    item.frame, to: window.coordinateSpace
                )
                if frame.intersects(window.bounds) { return frame }
            }
            environment = current.parentFocusEnvironment
            hops += 1
        }
        return nil
    }

    private static func appKeyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first
        return scene?.keyWindow ?? scene?.windows.first { !$0.isHidden }
    }

    /// Walks both the view hierarchy and nested `UIFocusItemContainer`s:
    /// UIKit-backed items surface via subview walking while SwiftUI hosts
    /// non-view focus items behind container queries, so one traversal
    /// alone misses items. Duplicates are dropped via `seenItems`.
    private static func collectFocusItems(
        in view: UIView,
        window: UIWindow,
        frames: inout [(item: UIFocusItem, frame: CGRect)],
        visitedContainers: inout Set<ObjectIdentifier>,
        seenItems: inout Set<ObjectIdentifier>,
        depth: Int
    ) {
        guard depth < 60, !view.isHidden, view.alpha > 0.01 else { return }

        collectFromContainer(
            view,
            window: window,
            frames: &frames,
            visitedContainers: &visitedContainers,
            seenItems: &seenItems,
            depth: depth
        )

        for subview in view.subviews {
            collectFocusItems(
                in: subview,
                window: window,
                frames: &frames,
                visitedContainers: &visitedContainers,
                seenItems: &seenItems,
                depth: depth + 1
            )
        }
    }

    private static func collectFromContainer(
        _ container: UIFocusItemContainer,
        window: UIWindow,
        frames: inout [(item: UIFocusItem, frame: CGRect)],
        visitedContainers: inout Set<ObjectIdentifier>,
        seenItems: inout Set<ObjectIdentifier>,
        depth: Int
    ) {
        guard depth < 60,
              visitedContainers.insert(ObjectIdentifier(container)).inserted
        else { return }

        let region = window.coordinateSpace.convert(
            window.bounds, to: container.coordinateSpace
        )
        for item in container.focusItems(in: region) {
            let frame = container.coordinateSpace.convert(
                item.frame, to: window.coordinateSpace
            )
            if item.canBecomeFocused,
               frame.intersects(window.bounds),
               seenItems.insert(ObjectIdentifier(item)).inserted {
                frames.append((item, frame))
            }
            if let nested = item as? UIFocusItemContainer, !(item is UIView) {
                collectFromContainer(
                    nested,
                    window: window,
                    frames: &frames,
                    visitedContainers: &visitedContainers,
                    seenItems: &seenItems,
                    depth: depth + 1
                )
            }
        }
    }

    // MARK: Directional heuristic

    /// Approximates the focus engine's choice: the candidate must lie
    /// beyond the focused frame in the movement direction; nearer edges
    /// win, axis overlap beats offset, and centered candidates break ties.
    private static func bestCandidate(
        from focused: CGRect,
        among candidates: [CGRect],
        direction: Direction
    ) -> CGRect? {
        var best: (frame: CGRect, score: CGFloat)?

        for candidate in candidates {
            let edgeDistance: CGFloat
            let axisGap: CGFloat
            let centerOffset: CGFloat

            switch direction {
            case .up:
                guard candidate.midY < focused.minY else { continue }
                edgeDistance = max(0, focused.minY - candidate.maxY)
                axisGap = max(
                    0,
                    max(candidate.minX, focused.minX)
                        - min(candidate.maxX, focused.maxX)
                )
                centerOffset = abs(candidate.midX - focused.midX)
            case .down:
                guard candidate.midY > focused.maxY else { continue }
                edgeDistance = max(0, candidate.minY - focused.maxY)
                axisGap = max(
                    0,
                    max(candidate.minX, focused.minX)
                        - min(candidate.maxX, focused.maxX)
                )
                centerOffset = abs(candidate.midX - focused.midX)
            case .left:
                guard candidate.midX < focused.minX else { continue }
                edgeDistance = max(0, focused.minX - candidate.maxX)
                axisGap = max(
                    0,
                    max(candidate.minY, focused.minY)
                        - min(candidate.maxY, focused.maxY)
                )
                centerOffset = abs(candidate.midY - focused.midY)
            case .right:
                guard candidate.midX > focused.maxX else { continue }
                edgeDistance = max(0, candidate.minX - focused.maxX)
                axisGap = max(
                    0,
                    max(candidate.minY, focused.minY)
                        - min(candidate.maxY, focused.maxY)
                )
                centerOffset = abs(candidate.midY - focused.midY)
            }

            let score = edgeDistance + axisGap * 3 + centerOffset * 0.25
            if best == nil || score < best!.score {
                best = (candidate, score)
            }
        }

        return best?.frame
    }
}

// MARK: - App-provided hints

/// Destinations the app knows but no focus API can report. SwiftUI
/// resolves cross-section hops (content → top menu) with internal state
/// UIKit never sees; the landing rule is deterministic app behavior
/// (the selected tab), so the owning view publishes it here and the
/// overlay draws it when the engine reports no candidate.
@MainActor
final class TVFocusDebugHints {
    static let shared = TVFocusDebugHints()

    /// Global frame of the top menu bar's selected tab while the bar is
    /// on screen and the debug overlay is enabled; nil otherwise.
    var topMenuSelectedTabFrame: CGRect?
}

/// Background publisher attached to the selected top-menu tab. Renders
/// nothing; keeps `TVFocusDebugHints` current while the tab is selected
/// and clears it when the tab deselects or the bar leaves the screen.
struct TVFocusDebugTabFramePublisher: View {
    let isSelected: Bool

    var body: some View {
        if isSelected, TVDebugSettings.shared.showFocusTargets {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        TVFocusDebugHints.shared.topMenuSelectedTabFrame =
                            proxy.frame(in: .global)
                    }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in
                        TVFocusDebugHints.shared.topMenuSelectedTabFrame = frame
                    }
                    .onDisappear {
                        TVFocusDebugHints.shared.topMenuSelectedTabFrame = nil
                    }
            }
        }
    }
}

// MARK: - Engine query

/// Asks the real tvOS focus engine what a d-pad move would focus, by
/// reconstructing the private request UIKit's event recognizer builds:
///
///   request  = _UIFocusMovementRequest(initWithFocusSystem:)
///   itemInfo = _UIFocusItemInfo(infoWithItem: focusedItem)
///   movement = _UIFocusMovementInfo(initWithHeading:velocity:isInitial:
///                shouldLoadScrollableContainer:groupFilter:inputType:)
///   context  = focusSystem._movementPerformer
///                .contextForFocusMovement(request)   // full pipeline
///   next     = (context as UIFocusUpdateContext).nextFocusedItem
///
/// The performer runs the engine's complete candidate search — including
/// the exhaustive-search and focus-section escalations a bare
/// `_UIFocusMap` query skips — without applying the movement. If the
/// performer is unavailable, a direct map query
/// (`_nextFocusedItemForFocusMovementRequest:`) is the lesser fallback.
///
/// Everything resolves through the ObjC runtime — nothing links against
/// private symbols — and every step is guarded, so an OS that renames any
/// of it just flips `isAvailable` and the overlay degrades to the
/// geometric heuristic. Debug tooling only; never ships behavior.
@MainActor
private enum FocusEngineQuery {
    private static let requestClass = NSClassFromString("_UIFocusMovementRequest") as? NSObject.Type
    private static let movementClass = NSClassFromString("_UIFocusMovementInfo") as? NSObject.Type
    private static let itemInfoClass = NSClassFromString("_UIFocusItemInfo") as? NSObject.Type
    private static let mapClass = NSClassFromString("_UIFocusMap") as? NSObject.Type

    private static let requestInitSel = NSSelectorFromString("initWithFocusSystem:")
    private static let itemInfoSel = NSSelectorFromString("infoWithItem:")
    private static let setItemInfoSel = NSSelectorFromString("setFocusedItemInfo:")
    private static let setMovementSel = NSSelectorFromString("setMovementInfo:")
    private static let movementInitSel = NSSelectorFromString(
        "initWithHeading:velocity:isInitial:shouldLoadScrollableContainer:groupFilter:inputType:"
    )
    private static let mapInitSel = NSSelectorFromString("initWithFocusSystem:rootEnvironment:")
    private static let nextItemSel = NSSelectorFromString("_nextFocusedItemForFocusMovementRequest:")

    private static let allocSel = NSSelectorFromString("alloc")
    private static let performerSel = NSSelectorFromString("_movementPerformer")
    private static let contextSel = NSSelectorFromString("contextForFocusMovement:")
    private static let nextFocusedItemSel = NSSelectorFromString("nextFocusedItem")

    static let isAvailable: Bool = {
        guard let requestClass, let movementClass, let itemInfoClass
        else { return false }
        let requestOK = requestClass.instancesRespond(to: requestInitSel)
            && requestClass.instancesRespond(to: setItemInfoSel)
            && requestClass.instancesRespond(to: setMovementSel)
            && movementClass.instancesRespond(to: movementInitSel)
            && (itemInfoClass as AnyObject).responds(to: itemInfoSel)
        let performerOK = UIFocusSystem.instancesRespond(to: performerSel)
        let mapOK = mapClass.map {
            $0.instancesRespond(to: mapInitSel) && $0.instancesRespond(to: nextItemSel)
        } ?? false
        return requestOK && (performerOK || mapOK)
    }()

    /// `alloc` runs through `perform` because Swift hides `NSObject.alloc`.
    /// The +1 from alloc is deliberately left outstanding
    /// (`takeUnretainedValue`) for the subsequent init to consume; the
    /// init's +1 result is what `takeRetainedValue` balances.
    private static func allocInstance(of cls: NSObject.Type) -> NSObject? {
        (cls as AnyObject).perform(allocSel)?.takeUnretainedValue() as? NSObject
    }

    static func nextFocusedItem(
        from focusedItem: UIFocusItem,
        heading: UIFocusHeading,
        in window: UIWindow
    ) -> UIFocusItem? {
        guard isAvailable,
              let movementClass, let itemInfoClass, let requestClass,
              let focusSystem = UIFocusSystem.focusSystem(for: window)
        else { return nil }

        guard let requestAlloc = allocInstance(of: requestClass),
              let request = requestAlloc
                  .perform(requestInitSel, with: focusSystem)?
                  .takeRetainedValue() as? NSObject
        else { return nil }

        // Class factory method returns autoreleased (+0).
        guard let itemInfo = (itemInfoClass as AnyObject)
            .perform(itemInfoSel, with: focusedItem)?
            .takeUnretainedValue()
        else { return nil }
        _ = request.perform(setItemInfoSel, with: itemInfo)

        // IMP cast: six mixed-type arguments are beyond perform(_:with:).
        // Signature: (heading: NSUInteger, velocity: CGFloat, isInitial:
        // BOOL, shouldLoadScrollableContainer: BOOL, groupFilter: id,
        // inputType: NSInteger). shouldLoadScrollableContainer matches a
        // real d-pad press so scrollable candidates are considered.
        typealias MovementInit = @convention(c) (
            AnyObject, Selector, UInt, CGFloat, ObjCBool, ObjCBool, AnyObject?, Int
        ) -> Unmanaged<AnyObject>?
        guard let movementAlloc = allocInstance(of: movementClass),
              let movementImp = movementAlloc.method(for: movementInitSel)
        else { return nil }
        let movementInit = unsafeBitCast(movementImp, to: MovementInit.self)
        guard let movement = movementInit(
            movementAlloc, movementInitSel,
            UInt(heading.rawValue), 0, false, true, nil, 0
        )?.takeRetainedValue() else { return nil }
        _ = request.perform(setMovementSel, with: movement)

        // Primary: the focus system's own movement performer builds the
        // full update context (with every escalation the real d-pad press
        // goes through) without applying the movement.
        if UIFocusSystem.instancesRespond(to: performerSel),
           let performer = focusSystem.perform(performerSel)?
               .takeUnretainedValue() as? NSObject,
           performer.responds(to: contextSel) {
            let context = performer.perform(contextSel, with: request)?
                .takeUnretainedValue()
            if let context = context as? UIFocusUpdateContext {
                return context.nextFocusedItem
            }
            if let context = context as? NSObject,
               context.responds(to: nextFocusedItemSel) {
                return context.perform(nextFocusedItemSel)?
                    .takeUnretainedValue() as? UIFocusItem
            }
            return nil
        }

        // Fallback: bare focus-map query (first-pass search only; misses
        // the exhaustive/section escalations).
        guard let mapClass else { return nil }
        typealias MapInit = @convention(c) (
            AnyObject, Selector, AnyObject?, AnyObject?
        ) -> Unmanaged<AnyObject>?
        guard let mapAlloc = allocInstance(of: mapClass),
              let mapImp = mapAlloc.method(for: mapInitSel)
        else { return nil }
        let mapInit = unsafeBitCast(mapImp, to: MapInit.self)
        guard let map = mapInit(
            mapAlloc, mapInitSel, focusSystem, window
        )?.takeRetainedValue() as? NSObject else { return nil }

        return map.perform(nextItemSel, with: request)?
            .takeUnretainedValue() as? UIFocusItem
    }
}

// MARK: - Overlay window

/// Hosts `TVFocusDebugOverlay` in its own always-on-top passthrough
/// window so the markers draw over full-screen covers (player, pickers)
/// and never participate in hit testing or focus.
@MainActor
final class TVFocusDebugOverlayController {
    static let shared = TVFocusDebugOverlayController()

    private var window: UIWindow?

    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard window == nil else { return }
            let scenes = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
            guard let scene = scenes.first(where: {
                $0.activationState == .foregroundActive
            }) ?? scenes.first else { return }

            let host = UIHostingController(rootView: TVFocusDebugOverlay())
            host.view.backgroundColor = .clear

            let overlay = UIWindow(windowScene: scene)
            overlay.windowLevel = .alert + 100
            overlay.isUserInteractionEnabled = false
            overlay.backgroundColor = .clear
            overlay.rootViewController = host
            overlay.isHidden = false
            window = overlay
        } else {
            window?.isHidden = true
            window = nil
        }
    }
}

/// Root-level activation hook: mirrors the persisted debug setting into
/// the overlay window's lifecycle.
struct TVFocusDebugActivationModifier: ViewModifier {
    @State private var debugSettings = TVDebugSettings.shared

    func body(content: Content) -> some View {
        content
            .onChange(of: debugSettings.showFocusTargets, initial: true) { _, enabled in
                TVFocusDebugOverlayController.shared.setEnabled(enabled)
            }
    }
}
#endif
