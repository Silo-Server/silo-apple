import SwiftUI

/// SF Symbol for generic icons; brand marks render as small text marks.
/// Rating badges draw no icon: their label carries the source's text mark.
struct OverlayIcon: View {
    let iconId: OverlayIconId
    let size: CGFloat
    /// Tint applied to SF Symbol glyphs and brand text; white when nil.
    /// A preset passes one to paint marks in its own foreground (e.g.
    /// `.minimal` paints everything in the accent color).
    let tint: Color?

    var body: some View {
        if let brandText = iconId.brandText {
            BrandBadge(text: brandText, foreground: tint ?? .white, size: size)
        } else {
            Image(systemName: symbolName(for: iconId))
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint ?? .white)
        }
    }

    private func symbolName(for icon: OverlayIconId) -> String {
        switch icon {
        case .clock:     return "clock"
        case .tv:        return "tv"
        case .film:      return "film"
        case .ribbon:    return "rosette"
        case .subtitles: return "captions.bubble"
        case .languages: return "globe"
        case .building:  return "building.2"
        case .shield:    return "shield"
        case .users:     return "person.2.fill"
        case .layout:    return "rectangle.ratio.16.to.9"
        case .monitor:   return "display"
        case .volume:    return "speaker.wave.2.fill"
        case .globe:     return "globe"
        case .hdr10, .hdr, .dolbyVision, .atmos, .av1: return "questionmark"
        }
    }
}

private struct BrandBadge: View {
    let text: String
    let foreground: Color
    let size: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.78, weight: .heavy, design: .rounded))
            .tracking(0.2)
            .foregroundStyle(foreground)
            // Reserve enough horizontal room that "ATMOS" doesn't get
            // squashed when the parent gives the icon a fixed size box.
            .fixedSize(horizontal: true, vertical: false)
    }
}
