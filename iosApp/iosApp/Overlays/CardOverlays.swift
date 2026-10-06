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
        // Wide cards leave more bottom room because a
        // title block / progress bar typically sits under the image.
        let bottomInset: CGFloat = {
            switch variant {
            case .poster: return 8 * scale
            case .wide:   return 24
            }
        }()
        let sideInset: CGFloat = 8 * scale
        let topInset: CGFloat  = 8 * scale
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

/// Resolved values needed to render one badge. Missing labels suppress the badge.
private struct OverlayBadgeRenderState {
    let id: OverlayId
    let label: String
    let iconId: OverlayIconId?
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
        let cfg = prefs.items[def.id]
        let dynamicIcon = def.getIcon?(data)
        let iconId = dynamicIcon ?? def.iconId
        let accent = cfg?.accentColor ?? def.defaultAccent
        let showIcon = (iconId != nil) && def.iconCapable && (cfg?.showIcon ?? preset.preferIcon)
        return .init(
            id: def.id,
            label: label,
            iconId: showIcon ? iconId : nil,
            accentColor: accent.map(Color.init(hex:))
        )
    }
}

/// Renders one resolved badge on a media card.
private struct OverlayBadgeView: View {
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
            if let label = displayLabel {
                badgeText(label)
            }
        }
        .padding(.horizontal, preset.horizontalPadding * scale)
        .padding(.vertical, preset.verticalPadding * scale)
        .background(background)
        .overlay(border)
        .clipShape(shape)
    }

    /// The label without the token a brand mark already draws, so a badge
    /// never reads "HDR10 HDR10" or "DV DV HDR10". Nil when nothing is left.
    private var displayLabel: String? {
        guard let mark = state.iconId?.brandText else { return state.label }
        let remaining = state.label
            .split(separator: " ")
            .filter { $0.caseInsensitiveCompare(mark) != .orderedSame }
            .joined(separator: " ")
        return remaining.isEmpty ? nil : remaining
    }

    private func badgeText(_ label: String) -> some View {
        Text(label)
            .font(.system(size: preset.fontSize * scale, weight: preset.textWeight))
            .tracking(preset.tracking * scale)
            .foregroundStyle(preset.foregroundColor(state.accentColor))
            .textCase(preset.textCase)
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

    /// One shape value feeds fill, stroke and clipShape for either corner style.
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
