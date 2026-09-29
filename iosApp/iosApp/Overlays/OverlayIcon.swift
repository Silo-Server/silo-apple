import SwiftUI

/// Renders an overlay icon. SF Symbol-backed glyphs cover the generic
/// set ("monitor", "star", "tv", …). Brand marks (HDR10, DV, Atmos,
/// AV1) are drawn as small text tags inside a tinted background so they
/// read at 10-pt — full SVG marks would be lost at that size and ship a
/// binary surface we don't otherwise need. Rating badges draw no icon:
/// their label carries the source's text mark.
struct OverlayIcon: View {
    let iconId: OverlayIconId
    let size: CGFloat
    /// Tint applied to SF Symbol glyphs and brand text; white when nil.
    /// A preset passes one to paint marks in its own foreground (e.g.
    /// `.minimal` paints everything in the accent color).
    let tint: Color?

    var body: some View {
        switch iconId {
        case .hdr10:        BrandBadge(text: "HDR10", fallbackBackground: .clear, fallbackForeground: tint ?? .white, size: size)
        case .hdr:          BrandBadge(text: "HDR",   fallbackBackground: .clear, fallbackForeground: tint ?? .white, size: size)
        case .dolbyVision:  BrandBadge(text: "DV",    fallbackBackground: .clear, fallbackForeground: tint ?? .white, size: size)
        case .atmos:        BrandBadge(text: "ATMOS", fallbackBackground: .clear, fallbackForeground: tint ?? .white, size: size)
        case .av1:          BrandBadge(text: "AV1",   fallbackBackground: .clear, fallbackForeground: tint ?? .white, size: size)
        default:
            Image(systemName: symbolName(for: iconId))
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(tint ?? .white)
        }
    }

    private func symbolName(for icon: OverlayIconId) -> String {
        switch icon {
        case .star:      return "star.fill"
        case .clock:     return "clock"
        case .tv:        return "tv"
        case .film:      return "film"
        case .award:     return "rosette"
        case .ribbon:    return "rosette"
        case .subtitles: return "captions.bubble"
        case .languages: return "globe"
        case .building:  return "building.2"
        case .shield:    return "shield"
        case .layout:    return "rectangle.ratio.16.to.9"
        case .monitor:   return "display"
        case .volume:    return "speaker.wave.2.fill"
        case .calendar:  return "calendar"
        case .globe:     return "globe"
        default:         return "questionmark"
        }
    }
}

private struct BrandBadge: View {
    let text: String
    let fallbackBackground: Color
    let fallbackForeground: Color
    let size: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.78, weight: .heavy, design: .rounded))
            .tracking(0.2)
            .foregroundColor(fallbackForeground)
            // Reserve enough horizontal room that "ATMOS" doesn't get
            // squashed when the parent gives the icon a fixed size box.
            .fixedSize(horizontal: true, vertical: false)
    }
}
