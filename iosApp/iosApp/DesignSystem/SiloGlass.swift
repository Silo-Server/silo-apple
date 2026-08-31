import SwiftUI

extension View {
    /// Silo's Liquid Glass background in `shape` on Apple 26+, with the native
    /// material fallback used by iOS 18. This is the single place glass styling
    /// is configured so call sites keep the same tint and shape conventions.
    @ViewBuilder
    func siloGlass(in shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.glassEffect(
                siloGlassConfiguration(tint: tint, interactive: interactive),
                in: shape
            )
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
        #else
        self.glassEffect(
            siloGlassConfiguration(tint: tint, interactive: interactive),
            in: shape
        )
        #endif
    }

    /// Glass for surfaces drawn over LIVE VIDEO (player HUD, controls,
    /// notices). Backdrop-sampling effects — glassEffect and the legacy
    /// materials alike — make the render server re-sample and re-blur the
    /// covered video region on every video frame, which A12-class Apple
    /// TVs pay for as a visible spike whenever the player menu is up.
    /// Low-power devices draw a non-sampling translucent fill instead;
    /// everything else gets standard Silo glass.
    @ViewBuilder
    func siloPlayerGlass(in shape: some Shape, tint: Color? = nil) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.siloGlass(in: shape, tint: tint)
        } else {
            // Avoid per-frame backdrop sampling over video on A12-era phones.
            self.background(shape.fill(Color(white: 0.10).opacity(0.88)))
        }
        #else
        if DevicePower.isLowPowerAppleTV {
            self.background(shape.fill(Color(white: 0.10).opacity(0.88)))
        } else {
            self.siloGlass(in: shape, tint: tint)
        }
        #endif
    }
}

@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
private func siloGlassConfiguration(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}
