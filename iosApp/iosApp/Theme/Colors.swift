import SwiftUI

extension Color {
    // MARK: - Core Palette (Plezy OLED Dark)

    /// Pure black background (#000000)
    static let continuumBackground = Color(hex: "#000000")

    /// Barely-visible surface (#0A0A0A)
    static let continuumSurface = Color(hex: "#0A0A0A")

    /// Surface variant for containers (#0E0F12)
    static let continuumSurfaceVariant = Color(hex: "#0E0F12")

    /// Surface for elevated containers like episode cards (#15171C)
    static let continuumSurfaceElevated = Color(hex: "#15171C")

    /// Primary interactive color — same as text (monochrome UI)
    static let continuumPrimary = Color(hex: "#EDEDED")

    /// Kept for backwards compat — same as primary
    static let continuumPrimaryLight = Color(hex: "#EDEDED")

    /// Primary text color (#EDEDED)
    static let continuumOnSurface = Color(hex: "#EDEDED")

    /// Muted/secondary text — primary at 60% opacity (#99EDEDED)
    static let continuumSecondaryText = Color(hex: "#99EDEDED")

    /// Error red (#B00020)
    static let continuumError = Color(hex: "#B00020")

    /// Success green
    static let continuumSuccess = Color.green

    /// Warning amber (ratings stars)
    static let continuumWarning = Color(hex: "#FFC107")

    // MARK: - Skyline chrome (guide §4)

    /// Selected-but-unfocused tab/pill capsule fill — `chrome.selected`, white @ 14%
    static let continuumChromeSelectedFill = Color.white.opacity(0.14)

    /// Inner border of the selected capsule — white @ 10%
    static let continuumChromeSelectedBorder = Color.white.opacity(0.10)

    /// Resting pill/chip fill — `chrome.unfocused-bg`, white @ 7%
    static let continuumChromeRestingFill = Color.white.opacity(0.07)

    /// Hairline border on resting pills/chips — white @ 9%
    static let continuumChromeRestingBorder = Color.white.opacity(0.09)

    /// Anchored dropdown panel fill — `glass.strong`, #16171B @ 86% over blur
    static let continuumGlassStrong = Color(hex: "#16171B").opacity(0.86)

    /// Shelf/base dropdown fill — `glass.regular`, black @ 55% over blur.
    static let continuumGlassRegular = Color.black.opacity(0.55)

    /// Page scrim behind anchored dropdowns — `scrim.dropdown`, black @ 55%
    static let continuumDropdownScrim = Color.black.opacity(0.55)

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
    static let continuumOutline = Color.white.opacity(0.12)

    /// Overlay for sheets and modals
    static let continuumOverlay = Color.black.opacity(0.6)

    /// Divider/separator line color — white at 12%
    static let continuumDivider = Color.white.opacity(0.12)

    /// Disabled control tint
    static let continuumDisabled = Color(hex: "#4B5563")
}
