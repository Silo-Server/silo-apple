import SwiftUI

extension View {
    /// Silo's Liquid Glass background in `shape`. All Apple targets (iOS / macOS /
    /// tvOS) are at the 26 minimum, so this is unconditional. It's the single
    /// place glass styling is configured — call sites never write `glassEffect`
    /// directly so tint/shape conventions stay consistent.
    func siloGlass(in shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return self.glassEffect(glass, in: shape)
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
        if DevicePower.isLowPowerAppleTV {
            self.background(shape.fill(Color(white: 0.10).opacity(0.88)))
        } else {
            self.siloGlass(in: shape, tint: tint)
        }
    }
}
