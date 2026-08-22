import SwiftUI

/// Renders all enabled overlay badges for an item, grouped into the
/// four corner stacks defined by the user's prefs. Designed to layer
/// inside a card's existing `ZStack` (over the poster, under any focus
/// chrome). Adds nothing to layout when no badges are visible.
///
/// Usage:
/// ```
/// ZStack {
///     posterImage
///     CardOverlays(data: .from(item), prefs: prefs, variant: .poster)
/// }
/// ```
struct CardOverlays: View {
    /// Matches the measured poster overlay layer on the web Home carousel.
    private static let posterReferenceWidth: CGFloat = 185

    let data: OverlayData
    let prefs: CardOverlayPrefs
    var variant: Variant = .poster

    enum Variant {
        case poster      // standard 2:3 poster card
        case wide        // backdrop card (continue watching, hero) — leaves
                         // headroom for the title block / progress bar.
        case hero        // large backdrop (detail-page hero, featured carousel)
    }

    var body: some View {
        let preset = OverlayPresets.preset(prefs.preset)
        GeometryReader { proxy in
            let scale = variant == .poster
                ? proxy.size.width / Self.posterReferenceWidth
                : 1
            ZStack(alignment: .topLeading) {
                cornerStack(.topLeft, preset: preset, scale: scale)
                cornerStack(.topRight, preset: preset, scale: scale)
                cornerStack(.bottomLeft, preset: preset, scale: scale)
                cornerStack(.bottomRight, preset: preset, scale: scale)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func cornerStack(
        _ position: OverlayPosition,
        preset: OverlayPreset,
        scale: CGFloat
    ) -> some View {
        let badges = OverlayRegistry
            .enabled(at: position, in: prefs)
            .compactMap { OverlayBadgeRenderState.resolve(def: $0, data: data, prefs: prefs, preset: preset) }
        if badges.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: alignment(for: position), spacing: preset.gap * scale) {
                ForEach(badges, id: \.id) { state in
                    OverlayBadgeView(state: state, preset: preset, scale: scale)
                }
            }
            .padding(insets(for: position, scale: scale))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchor(for: position))
        }
    }

    private func alignment(for position: OverlayPosition) -> HorizontalAlignment {
        switch position {
        case .topLeft, .bottomLeft:   return .leading
        case .topRight, .bottomRight: return .trailing
        }
    }

    private func anchor(for position: OverlayPosition) -> Alignment {
        switch position {
        case .topLeft:     return .topLeading
        case .topRight:    return .topTrailing
        case .bottomLeft:  return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }

    private func insets(for position: OverlayPosition, scale: CGFloat) -> EdgeInsets {
        // `wide` and `hero` variants leave more bottom room because a
        // title block / progress bar typically sits under the image.
        let bottomInset: CGFloat = {
            switch variant {
            case .poster: return 8 * scale
            case .wide:   return 24
            case .hero:   return 16
            }
        }()
        let sideInset: CGFloat = variant == .hero ? 16 : 8 * scale
        let topInset: CGFloat  = variant == .hero ? 16 : 8 * scale
        switch position {
        case .topLeft:
            return EdgeInsets(top: topInset, leading: sideInset, bottom: 0, trailing: 0)
        case .topRight:
            return EdgeInsets(top: topInset, leading: 0, bottom: 0, trailing: sideInset)
        case .bottomLeft:
            return EdgeInsets(top: 0, leading: sideInset, bottom: bottomInset, trailing: 0)
        case .bottomRight:
            return EdgeInsets(top: 0, leading: 0, bottom: bottomInset, trailing: sideInset)
        }
    }
}

// MARK: - Single-badge resolution + rendering

/// Resolved values needed to render one badge. Settings preview UI
/// uses `resolveForPreview` to force a chip even when sample data
/// doesn't yield a value; the live card path uses `resolve` and lets
/// the optional return value act as the "should I render?" signal.
struct OverlayBadgeRenderState: Equatable {
    let id: OverlayId
    let label: String
    let iconId: OverlayIconId?
    let iconOnly: Bool
    let accentColor: Color?

    /// Resolve the badge as it would appear on a real card. Returns
    /// `nil` when the overlay's data extractor returns no label —
    /// signalling that the badge should not render.
    static func resolve(
        def: OverlayDef,
        data: OverlayData,
        prefs: CardOverlayPrefs,
        preset: OverlayPreset
    ) -> OverlayBadgeRenderState? {
        guard let label = def.getValue(data) else { return nil }
        return build(def: def, label: label, data: data, prefs: prefs, preset: preset)
    }

    /// Force-resolve with the overlay's label as a fallback. Used by
    /// the settings UI so every row shows a chip even if the chosen
    /// sample fixture happens to not populate that overlay.
    static func resolveForPreview(
        def: OverlayDef,
        data: OverlayData,
        prefs: CardOverlayPrefs,
        preset: OverlayPreset
    ) -> OverlayBadgeRenderState {
        let label = def.getValue(data) ?? def.label.uppercased()
        return build(def: def, label: label, data: data, prefs: prefs, preset: preset)
    }

    private static func build(
        def: OverlayDef,
        label: String,
        data: OverlayData,
        prefs: CardOverlayPrefs,
        preset: OverlayPreset
    ) -> OverlayBadgeRenderState {
        let cfg = prefs.items[def.id]
        let dynamicIcon = def.getIcon?(data)
        let iconId = dynamicIcon ?? def.iconId
        let accent = cfg?.accentColor ?? def.defaultAccent
        let showIcon = (iconId != nil) && def.iconCapable && (cfg?.showIcon ?? preset.preferIcon)
        return .init(
            id: def.id,
            label: label,
            iconId: showIcon ? iconId : nil,
            iconOnly: def.iconOnly,
            accentColor: accent.flatMap { Color(hex: $0) }
        )
    }
}

/// Renders one resolved badge. Used by `CardOverlays` for live cards
/// and by the settings UI for per-row badge previews.
struct OverlayBadgeView: View {
    let state: OverlayBadgeRenderState
    let preset: OverlayPreset
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 4 * scale) {
            if let iconId = state.iconId {
                OverlayIcon(
                    iconId: iconId,
                    size: preset.iconSize * scale,
                    tint: preset.foregroundColor(state.accentColor)
                )
            }
            if (!state.iconOnly || state.iconId == nil) && !labelRedundantWithIcon {
                badgeText
            }
        }
        .padding(.horizontal, preset.horizontalPadding * scale)
        .padding(.vertical, preset.verticalPadding * scale)
        .background(background)
        .overlay(border)
        .clipShape(shape)
    }

    /// A wordmark icon (HDR10, ATMOS, …) spells its text as the mark
    /// itself; when the label says the same thing, showing both reads
    /// "HDR10 HDR10". Mirrors web's `labelRedundantWithIcon`.
    private var labelRedundantWithIcon: Bool {
        guard let iconId = state.iconId, let mark = iconId.wordmarkText else { return false }
        return mark.lowercased() == state.label
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }

    @ViewBuilder
    private var badgeText: some View {
        let text = Text(state.label)
            .font(.system(size: preset.fontSize * scale, weight: preset.textWeight))
            .tracking(preset.tracking * scale)
            .foregroundColor(preset.foregroundColor(state.accentColor))
        Group {
            if let textCase = preset.textCase {
                text.textCase(textCase)
            } else {
                text
            }
        }
        .modifier(BadgeShadow(enabled: preset.textShadow, scale: scale))
    }

    @ViewBuilder
    private var background: some View {
        let color = preset.backgroundColor(state.accentColor)
        if let material = preset.backdropMaterial {
            shape
                .fill(material)
                .overlay(shape.fill(color))
        } else {
            shape.fill(color)
        }
    }

    @ViewBuilder
    private var border: some View {
        if let stroke = preset.borderColor(state.accentColor) {
            shape.stroke(stroke, lineWidth: scale)
        }
    }

    /// Type-erased shape so the same value can feed `fill`, `stroke`,
    /// and `clipShape` regardless of which corner style the preset
    /// chose. AnyShape (iOS 16+) carries no measurable overhead vs.
    /// the opaque alternatives.
    private var shape: AnyShape {
        switch preset.cornerStyle {
        case .capsule:
            return AnyShape(Capsule(style: .continuous))
        case .rounded(let radius):
            return AnyShape(RoundedRectangle(cornerRadius: radius * scale, style: .continuous))
        }
    }
}

private struct BadgeShadow: ViewModifier {
    let enabled: Bool
    let scale: CGFloat
    func body(content: Content) -> some View {
        if enabled {
            content.shadow(color: Color.black.opacity(0.85), radius: scale, y: scale)
        } else {
            content
        }
    }
}
