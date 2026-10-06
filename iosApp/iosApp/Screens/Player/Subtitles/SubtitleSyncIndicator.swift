import SwiftUI

/// A small card in the player's top-trailing corner that follows a subtitle
/// sync the viewer started: its progress while it runs, then how it ended.
/// It also says briefly when someone else's timing change reaches the
/// subtitle on screen. It never takes focus; on iOS and macOS a finished card
/// can be dismissed, and every finished card leaves on its own.
struct SubtitleSyncIndicator: View {
    let notice: SubtitleSyncNotice
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.spacing) {
            icon
                .frame(width: Metrics.icon, height: Metrics.icon)
            VStack(alignment: .leading, spacing: Metrics.lineSpacing) {
                Text(notice.title)
                    .font(Metrics.titleFont)
                    .foregroundStyle(Color.siloOnSurface)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = notice.detail {
                    Text(detail)
                        .font(Metrics.detailFont)
                        .foregroundStyle(Color.siloSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if notice.tone == .progress, let percent = notice.percent {
                    SubtitleSyncProgressBar(percent: percent)
                        .padding(.top, Metrics.lineSpacing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            #if !os(tvOS)
            if notice.tone != .progress, let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.siloSecondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            #endif
        }
        .padding(Metrics.padding)
        .frame(width: Metrics.width)
        .siloPlayerGlass(
            in: RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous),
            tint: accent.opacity(0.16)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .strokeBorder(accent.opacity(notice.tone == .progress ? 0.18 : 0.45), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("subtitle-sync-indicator")
    }

    @ViewBuilder
    private var icon: some View {
        switch notice.tone {
        case .progress:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                #if !os(tvOS)
                .controlSize(.small)
                #endif
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(accent)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(accent)
        case .info:
            Image(systemName: "info.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(accent)
        }
    }

    private var accent: Color {
        switch notice.tone {
        case .progress: return .white
        case .success: return .siloSwitchOn
        case .warning: return .siloWarning
        case .info: return Color(red: 0.49, green: 0.83, blue: 0.99)
        }
    }

    private var accessibilityText: String {
        var parts = [notice.title]
        if let detail = notice.detail { parts.append(detail) }
        if notice.tone == .progress, let percent = notice.percent { parts.append("\(percent) percent") }
        return parts.joined(separator: ". ")
    }

    private enum Metrics {
        #if os(tvOS)
        static let width: CGFloat = 560
        static let padding: CGFloat = 24
        static let spacing: CGFloat = 18
        static let lineSpacing: CGFloat = 6
        static let icon: CGFloat = 32
        static let cornerRadius: CGFloat = 22
        static let titleFont: Font = .system(size: 26, weight: .semibold)
        static let detailFont: Font = .system(size: 22)
        #else
        static let width: CGFloat = 300
        static let padding: CGFloat = 14
        static let spacing: CGFloat = 12
        static let lineSpacing: CGFloat = 3
        static let icon: CGFloat = 18
        static let cornerRadius: CGFloat = 16
        static let titleFont: Font = .subheadline.weight(.semibold)
        static let detailFont: Font = .footnote
        #endif
    }
}

/// A thin progress bar with its percentage, for a running sync.
struct SubtitleSyncProgressBar: View {
    let percent: Int

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            ProgressView(value: Double(min(100, max(0, percent))), total: 100)
                .progressViewStyle(.linear)
                .tint(.white.opacity(0.85))
            Text("\(percent)%")
                .font(Metrics.font.monospacedDigit())
                .foregroundStyle(Color.siloSecondaryText)
                .frame(minWidth: Metrics.labelWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Subtitle sync progress")
        .accessibilityValue("\(percent) percent")
    }

    private enum Metrics {
        #if os(tvOS)
        static let spacing: CGFloat = 14
        static let font: Font = .system(size: 20)
        static let labelWidth: CGFloat = 60
        #else
        static let spacing: CGFloat = 8
        static let font: Font = .caption2
        static let labelWidth: CGFloat = 34
        #endif
    }
}
