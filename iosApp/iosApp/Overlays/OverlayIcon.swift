import SwiftUI

/// A badge's icon: an SF Symbol for the generic icons, text for the
/// wordmarks, and a drawn mark for Dolby Vision. Mirrors
/// `web/src/lib/overlays/icons.tsx`. Rating badges draw no icon: their label
/// carries the source's text mark.
struct OverlayIcon: View {
    let iconId: OverlayIconId
    /// The icon's height in points.
    let size: CGFloat
    /// The badge's text colour, which every icon is drawn in.
    let tint: Color

    var body: some View {
        if let wordmark = iconId.wordmark {
            // The web marks are 10-unit text in a 12-unit-high box; ATMOS
            // is 9-unit text spaced half a unit apart.
            let units: CGFloat = iconId == .atmos ? 9 : 10
            Text(verbatim: wordmark)
                .font(.system(size: size * units / 12, weight: .black))
                .tracking(iconId == .atmos ? size * 0.5 / 12 : 0)
                .foregroundStyle(tint)
                .fixedSize()
                .frame(height: size)
        } else if iconId == .dolbyVision {
            DolbyVisionMark()
                .fill(tint, style: FillStyle(eoFill: true))
                .frame(width: size, height: size)
        } else {
            Image(systemName: symbolName(for: iconId))
                .font(.system(size: size * 0.85, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        }
    }

    private func symbolName(for icon: OverlayIconId) -> String {
        switch icon {
        case .clock:     return "clock"
        case .tv:        return "tv"
        case .film:      return "film"
        case .ribbon:    return "rosette"
        case .subtitles: return "captions.bubble"
        case .languages: return "translate"
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

/// The web's Dolby Vision mark: a ring whose right half is filled. Drawn in
/// a 16-unit box as a disc with the left half of its inside cut out
/// (even-odd fill).
private struct DolbyVisionMark: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 16
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = 6 * unit
        let inner = 4.5 * unit
        var path = Path()
        path.addEllipse(in: CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
        // The cut-out: from the top of the inside, round its left, to the bottom.
        path.move(to: CGPoint(x: center.x, y: center.y - inner))
        path.addArc(
            center: center,
            radius: inner,
            startAngle: .degrees(-90),
            endAngle: .degrees(90),
            clockwise: true
        )
        path.closeSubpath()
        return path
    }
}
