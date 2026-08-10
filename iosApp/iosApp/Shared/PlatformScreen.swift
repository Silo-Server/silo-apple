#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

enum PlatformScreen {
    static var mainBounds: CGRect {
        #if canImport(UIKit)
        #if os(tvOS)
        return CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #else
        return activeScreen?.bounds ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #endif
        #elseif canImport(AppKit)
        return NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        #endif
    }

    static var maximumFramesPerSecond: Double? {
        #if canImport(UIKit)
        #if os(tvOS)
        return 60
        #else
        guard let fps = activeScreen?.maximumFramesPerSecond, fps > 0 else { return nil }
        return Double(fps)
        #endif
        #elseif canImport(AppKit)
        guard let fps = NSScreen.main?.maximumFramesPerSecond, fps > 0 else { return nil }
        return Double(fps)
        #endif
    }

    /// EDR headroom the given screen could make available, spelled once for
    /// both hosts — AppKit and UIKit name the same quantity differently.
    /// Headroom is per screen rather than per machine: on a multi-display Mac
    /// the window may sit on a display with none to spend. `nil` screen (view
    /// not in a window yet) reads as the SDR floor.
    #if os(iOS)
    static func potentialEDRHeadroom(of screen: UIScreen?) -> Double {
        Double(screen?.potentialEDRHeadroom ?? 1.0)
    }
    #elseif canImport(AppKit)
    static func potentialEDRHeadroom(of screen: NSScreen?) -> Double {
        Double(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0)
    }
    #endif

    #if canImport(UIKit) && !os(tvOS)
    private static var activeScreen: UIScreen? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }

        return scenes.first(where: { $0.activationState == .foregroundActive })?.screen
            ?? scenes.first(where: { $0.activationState == .foregroundInactive })?.screen
            ?? scenes.first?.screen
    }
    #endif
}
