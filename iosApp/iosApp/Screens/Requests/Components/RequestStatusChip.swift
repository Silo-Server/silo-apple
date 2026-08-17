import SwiftUI

extension RequestStatusTint {
    /// The one place the pure tint enum becomes a `Color`. Chips stay
    /// monochrome; the dot is the only chromatic element (Skyline grammar —
    /// the rating amber is the precedent for a single accent token).
    var color: Color {
        switch self {
        case .amber: .requestAmber
        case .sky: .requestSky
        case .emerald: .requestEmerald
        case .rose: .requestRose
        case .neutral: .siloSecondaryText
        }
    }
}

/// Monochrome capsule chip with a small colored status dot — the standalone
/// status presentation used on detail pages and My Requests rows.
struct RequestStatusChip: View {
    let state: RequestDisplayState
    /// Optional detail text after the label (e.g. a decline reason).
    var detail: String? = nil

    var body: some View {
        HStack(spacing: dotSpacing) {
            Circle()
                .fill(state.tint.color)
                .frame(width: dotSize, height: dotSize)
            Text(text)
                .font(font)
                .fontWeight(.semibold)
                .foregroundColor(.siloOnSurface)
                .lineLimit(1)
        }
        .padding(.horizontal, hPadding)
        .padding(.vertical, vPadding)
        .background(
            Capsule().fill(Color.siloChromeRestingFill)
        )
        .overlay(
            Capsule().stroke(Color.siloChromeRestingBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    private var text: String {
        if let detail, !detail.isEmpty {
            return "\(state.label) · \(detail)"
        }
        return state.label
    }

    private var font: Font {
        #if os(tvOS)
        .system(size: 24)
        #else
        .siloCaption
        #endif
    }

    private var dotSize: CGFloat {
        #if os(tvOS)
        11
        #else
        7
        #endif
    }

    private var dotSpacing: CGFloat {
        #if os(tvOS)
        10
        #else
        6
        #endif
    }

    private var hPadding: CGFloat {
        #if os(tvOS)
        22
        #else
        10
        #endif
    }

    private var vPadding: CGFloat {
        #if os(tvOS)
        10
        #else
        5
        #endif
    }
}

/// Corner ribbon variant of the same state for poster cards — dark glass
/// capsule pinned top-trailing over the artwork.
struct RequestPosterRibbon: View {
    let state: RequestDisplayState

    var body: some View {
        HStack(spacing: dotSpacing) {
            Circle()
                .fill(state.tint.color)
                .frame(width: dotSize, height: dotSize)
            Text(state.label)
                .font(.system(size: fontSize, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, hPadding)
        .padding(.vertical, vPadding)
        .background(
            Capsule().fill(Color.black.opacity(0.62))
        )
        .overlay(
            Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .accessibilityHidden(true)
    }

    private var fontSize: CGFloat {
        #if os(tvOS)
        20
        #else
        10
        #endif
    }

    private var dotSize: CGFloat {
        #if os(tvOS)
        10
        #else
        6
        #endif
    }

    private var dotSpacing: CGFloat {
        #if os(tvOS)
        8
        #else
        5
        #endif
    }

    private var hPadding: CGFloat {
        #if os(tvOS)
        16
        #else
        8
        #endif
    }

    private var vPadding: CGFloat {
        #if os(tvOS)
        8
        #else
        4
        #endif
    }
}
