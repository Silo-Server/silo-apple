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
    let data: OverlayData
    let prefs: CardOverlayPrefs
    var variant: Variant = .poster

    enum Variant {
        case poster        // standard 2:3 poster card
        case landscapeCard // 16:9 library/home row card
        case wide          // episode/thumb row card with room for title/progress
        case hero          // large backdrop (detail-page hero, featured carousel)
    }

    var body: some View {
        let preset = OverlayPresets.preset(prefs.preset)
        ZStack(alignment: .topLeading) {
            cornerStack(.topLeft, preset: preset)
            cornerStack(.topRight, preset: preset)
            cornerStack(.bottomLeft, preset: preset)
            cornerStack(.bottomRight, preset: preset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func cornerStack(_ position: OverlayPosition, preset: OverlayPreset) -> some View {
        let badges = OverlayRegistry
            .enabled(at: position, in: prefs)
            .compactMap { OverlayBadgeRenderState.resolve(def: $0, data: data, prefs: prefs, preset: preset) }
        if badges.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: alignment(for: position), spacing: preset.gap) {
                ForEach(badges, id: \.id) { state in
                    OverlayBadgeView(state: state, preset: preset)
                }
            }
            .padding(Self.layoutInsets(for: position, variant: variant))
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

    static func layoutInsets(for position: OverlayPosition, variant: Variant) -> EdgeInsets {
        // `wide` and `hero` variants reserve bottom room for surfaces that
        // pair the image with title/progress chrome. Landscape row cards keep
        // badges pinned to the artwork corners.
        let bottomInset: CGFloat = {
            switch variant {
            case .poster, .landscapeCard: return 8
            case .wide:                   return 24
            case .hero:                   return 16
            }
        }()
        let sideInset: CGFloat = variant == .hero ? 16 : 8
        let topInset: CGFloat  = variant == .hero ? 16 : 8
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
    /// `nil` when the overlay's data extractor returns no visible label —
    /// signalling that the badge should not render or reserve stack space.
    static func resolve(
        def: OverlayDef,
        data: OverlayData,
        prefs: CardOverlayPrefs,
        preset: OverlayPreset
    ) -> OverlayBadgeRenderState? {
        guard let label = def.getValue(data),
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
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

    var body: some View {
        OverlayBadgeChrome(
            label: state.label,
            iconId: state.iconId,
            iconOnly: state.iconOnly,
            accentColor: state.accentColor,
            preset: preset
        )
    }
}

struct OverlayTextBadgeView: View {
    let label: String
    let preset: OverlayPreset

    var body: some View {
        OverlayBadgeChrome(
            label: label,
            iconId: nil,
            iconOnly: false,
            accentColor: nil,
            preset: preset
        )
    }
}

private struct OverlayBadgeChrome: View {
    let label: String
    let iconId: OverlayIconId?
    let iconOnly: Bool
    let accentColor: Color?
    let preset: OverlayPreset

    var body: some View {
        HStack(spacing: 4) {
            if let iconId {
                OverlayIcon(
                    iconId: iconId,
                    size: preset.iconSize,
                    tint: preset.foregroundColor(accentColor)
                )
            }
            if !iconOnly || iconId == nil {
                badgeText
            }
        }
        .padding(.horizontal, preset.horizontalPadding)
        .padding(.vertical, preset.verticalPadding)
        .background(background)
        .overlay(border)
        .clipShape(shape)
    }

    @ViewBuilder
    private var badgeText: some View {
        let text = Text(label)
            .font(preset.font.weight(preset.textWeight))
            .tracking(preset.tracking)
            .foregroundColor(preset.foregroundColor(accentColor))
        Group {
            if let textCase = preset.textCase {
                text.textCase(textCase)
            } else {
                text
            }
        }
        .modifier(BadgeShadow(enabled: preset.textShadow))
    }

    @ViewBuilder
    private var background: some View {
        let color = preset.backgroundColor(accentColor)
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
        if let stroke = preset.borderColor(accentColor) {
            shape.stroke(stroke, lineWidth: 1)
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
            return AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

private struct BadgeShadow: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.shadow(color: Color.black.opacity(0.85), radius: 1, y: 1)
        } else {
            content
        }
    }
}
