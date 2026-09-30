import SwiftUI

extension RequestStatusTint {
    /// The one place the pure tint enum becomes a `Color`. Status text stays
    /// monochrome; the dot and the current stage are the only chromatic
    /// elements (Skyline grammar — the rating amber is the precedent for a
    /// single accent token).
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

/// Four-segment stage track: steps behind the request are solid, the step
/// it's on carries the status tint, and the rest stay dim. The only
/// chromatic element is the current segment, matching the status dot.
struct RequestStageTrack: View {
    let progress: RequestProgress
    var height: CGFloat = RequestStageTrack.defaultHeight

    var body: some View {
        HStack(spacing: height) {
            ForEach(RequestStep.allCases, id: \.self) { step in
                Capsule()
                    .fill(fill(for: step))
                    .frame(height: height)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(progress.longLabel)
    }

    private func fill(for step: RequestStep) -> Color {
        if step == progress.currentStep { return progress.tint.color }
        if step.rawValue < progress.completedSteps { return Color.siloOnSurface.opacity(0.82) }
        return Color.white.opacity(0.14)
    }

    static var defaultHeight: CGFloat {
        #if os(tvOS)
        6
        #else
        4
        #endif
    }
}

/// Status dot + label, the caption line under request cards and rows.
struct RequestStatusLabel: View {
    let progress: RequestProgress
    var text: String? = nil
    var font: Font = .siloCaption
    var color: Color = .siloSecondaryText
    var lineLimit = 1

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: dotSpacing) {
            Circle()
                .fill(progress.tint.color)
                .frame(width: dotSize, height: dotSize)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            Text(text ?? progress.shortLabel)
                .font(font)
                .foregroundColor(color)
                .lineLimit(lineLimit)
        }
        .accessibilityElement(children: .combine)
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
        10
        #else
        5
        #endif
    }
}

/// Corner badge for discovery posters whose title is already requested or
/// in the library. Same grammar as `DownloadedBadge`: a white glyph on a
/// filled status circle, pinned bottom-trailing.
struct RequestPosterBadge: View {
    let state: RequestDisplayState
    var size: CGFloat = RequestPosterBadge.defaultSize

    var body: some View {
        if let symbol {
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(state.tint.color))
                .shadow(color: .black.opacity(0.35), radius: 4)
                .accessibilityHidden(true)
        }
    }

    private var symbol: String? {
        switch state {
        case .pending: "clock"
        case .onTheWay: "arrow.down"
        case .inLibrary: "checkmark"
        case .needsAttention: "exclamationmark"
        case .unavailable: nil
        }
    }

    static var defaultSize: CGFloat {
        #if os(tvOS)
        36
        #else
        20
        #endif
    }
}
