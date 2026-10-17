import Foundation
import Synchronization
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The display artwork requests are sized for, readable off the main actor.
struct ArtworkDisplay: Equatable, Sendable {
    /// 2 on Apple TV 4K and 1 on Apple TV HD; the largest screen scale
    /// elsewhere.
    var scale: CGFloat
    /// The largest screen in points, longest edge as the width. Screens that
    /// fill a window with artwork size it from this.
    var screenSize: CGSize
    /// iPad: screens lay out wider than on iPhone.
    var isPad = false

    /// A display seen before any scene connects: 2× on a 1080p-class screen.
    static let assumed = ArtworkDisplay(scale: 2, screenSize: CGSize(width: 1920, height: 1080))

    private static let storage = Mutex(assumed)
    @MainActor private static var observers: [NSObjectProtocol] = []

    static var current: ArtworkDisplay { storage.withLock { $0 } }

    /// Read the connected screens. The main actor refreshes this when a
    /// scene connects or activates (on macOS, when screens change).
    @MainActor
    static func refresh() {
        #if canImport(UIKit)
        let screens = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }
        let sizes = screens.map(\.bounds.size)
        let scales = screens.map(\.scale)
        #if os(iOS)
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        #else
        let isPad = false
        #endif
        #else
        let sizes = NSScreen.screens.map(\.frame.size)
        let scales = NSScreen.screens.map(\.backingScaleFactor)
        let isPad = false
        #endif
        guard let scale = scales.max(), scale >= 1,
              let longEdge = sizes.map({ max($0.width, $0.height) }).max(),
              let shortEdge = sizes.map({ min($0.width, $0.height) }).max(),
              shortEdge > 0 else { return }
        let display = ArtworkDisplay(scale: scale, screenSize: CGSize(width: longEdge, height: shortEdge), isPad: isPad)
        storage.withLock { $0 = display }
    }

    /// Call once at launch, on the main actor.
    @MainActor
    static func install() {
        guard observers.isEmpty else { return }
        #if canImport(UIKit)
        let names = [UIScene.willConnectNotification, UIScene.didActivateNotification]
        #else
        let names = [NSApplication.didChangeScreenParametersNotification, NSApplication.didFinishLaunchingNotification]
        #endif
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { refresh() }
            }
        }
        refresh()
    }
}
