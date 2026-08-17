import SwiftUI

/// How a now-playing bar renders its background.
/// - `.card`: the bar draws its own translucent rounded card (used when it sits
///   loose above a plain tab bar / sidebar — the iOS 18 fallback and iPad/macOS).
/// - `.accessory`: chromeless — the host (iOS 26 `tabViewBottomAccessory`) provides
///   the Liquid Glass background, so the bar must not draw its own card.
enum NowPlayingBarStyle {
    case card
    case accessory
}

/// Applies (or omits) the rounded translucent card behind a now-playing bar.
struct NowPlayingBarChrome: ViewModifier {
    let style: NowPlayingBarStyle

    func body(content: Content) -> some View {
        switch style {
        case .card:
            content
                .siloGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.siloOutline, lineWidth: 1)
                )
        case .accessory:
            content
        }
    }
}
