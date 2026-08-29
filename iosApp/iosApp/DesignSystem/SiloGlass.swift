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

    /// The clearer Liquid Glass variant used by floating controls and menus
    /// that should preserve more of the artwork beneath them.
    func siloClearGlass(in shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        var glass = Glass.clear
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return self.glassEffect(glass, in: shape)
    }

    /// Regular Liquid Glass for bounded surfaces drawn over live video.
    /// Player call sites keep these surfaces compact and group adjacent
    /// controls in `GlassEffectContainer`s so the HUD retains the native
    /// material on every supported Apple TV without sampling one giant
    /// full-screen backdrop.
    func siloPlayerGlass(in shape: some Shape, tint: Color? = nil) -> some View {
        self.siloGlass(in: shape, tint: tint)
    }
}
