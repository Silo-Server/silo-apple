import SwiftUI

extension Color {
    // MARK: - Core Palette (Plezy OLED Dark)

    /// Pure black background (#000000)
    static let siloBackground = Color(hex: "#000000")

    /// Barely-visible surface (#0A0A0A)
    static let siloSurface = Color(hex: "#0A0A0A")

    /// Surface variant for containers (#0E0F12)
    static let siloSurfaceVariant = Color(hex: "#0E0F12")

    /// Surface for elevated containers like episode cards (#15171C)
    static let siloSurfaceElevated = Color(hex: "#15171C")

    /// Primary interactive color — same as text (monochrome UI)
    static let siloPrimary = Color(hex: "#EDEDED")

    /// Primary text color (#EDEDED)
    static let siloOnSurface = Color(hex: "#EDEDED")

    /// Accent for enabled control states (toggle tracks, prominent buttons).
    /// The monochrome palette made an on toggle a white knob on a white
    /// track; this matches the web client's blue-theme primary.
    static let siloAccent = Color(hex: "#78AEFC")

    /// Orange sampled from the canonical Silo wordmark artwork. Reserved for
    /// branded moments so ordinary signed-in controls retain `siloAccent`.
    static let siloBrandOrange = Color(hex: "#FD7403")

    /// Muted/secondary text — primary at 60% opacity (#99EDEDED)
    static let siloSecondaryText = Color(hex: "#99EDEDED")

    /// Error red (#B00020)
    static let siloError = Color(hex: "#B00020")

    /// Success green
    static let siloSuccess = Color.green

    /// Warning amber (ratings stars)
    static let siloWarning = Color(hex: "#FFC107")

    // MARK: - Skyline chrome (guide §4)

    /// Selected-but-unfocused tab/pill capsule fill — `chrome.selected`, white @ 14%
    static let siloChromeSelectedFill = Color.white.opacity(0.14)

    /// Inner border of the selected capsule — white @ 10%
    static let siloChromeSelectedBorder = Color.white.opacity(0.10)

    /// Resting pill/chip fill — `chrome.unfocused-bg`, white @ 7%
    static let siloChromeRestingFill = Color.white.opacity(0.07)

    /// Hairline border on resting pills/chips — white @ 9%
    static let siloChromeRestingBorder = Color.white.opacity(0.09)

    // MARK: - Request status dots

    /// The requests UI keeps chips monochrome; these tint only the small
    /// status dot (and match the web app's ribbon palette so both clients
    /// speak one status language). Pending — amber.
    static let requestAmber = Color(hex: "#F59E0B")

    /// Approved / queued / downloading — sky.
    static let requestSky = Color(hex: "#38BDF8")

    /// Completed / in library — emerald.
    static let requestEmerald = Color(hex: "#34D399")

    /// Declined / failed — rose.
    static let requestRose = Color(hex: "#FB7185")

    // MARK: - Semantic Aliases

    /// Outline/border color — white at 12%
    static let siloOutline = Color.white.opacity(0.12)

    /// Divider/separator line color — white at 12%
    static let siloDivider = Color.white.opacity(0.12)

    /// Disabled control tint
    static let siloDisabled = Color(hex: "#4B5563")
}
