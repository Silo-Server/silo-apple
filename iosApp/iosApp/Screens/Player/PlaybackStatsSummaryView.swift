import SwiftUI

/// The first view of the stats panels: the playback state, how the file is
/// delivered, and the few readings a viewer acts on. The full rows
/// (`PlaybackStatsPanel`) stay one step away.
struct PlaybackStatsSummaryView: View {
    enum Scale { case phone, tv }

    let summary: PlaybackStats.Summary
    var scale: Scale = .phone

    private var isTV: Bool { scale == .tv }

    var body: some View {
        VStack(alignment: .leading, spacing: isTV ? 34 : 14) {
            header
            Grid(
                alignment: .topLeading,
                horizontalSpacing: isTV ? 20 : 28,
                verticalSpacing: isTV ? 20 : 12
            ) {
                ForEach(Array(readingRows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(row, id: \.title) { reading in
                            tile(reading)
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: isTV ? 8 : 3) {
            Label {
                Text(summary.status)
            } icon: {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusTint)
            }
            .font(.system(size: isTV ? 38 : 17, weight: .semibold))
            .foregroundStyle(.white)
            if let context = summary.context {
                Text(context)
                    .font(.system(size: isTV ? 24 : 12))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Four across on TV, two by two on a phone.
    private var readingRows: [[PlaybackStats.Summary.Reading]] {
        let perRow = isTV ? 4 : 2
        return stride(from: 0, to: summary.readings.count, by: perRow).map {
            Array(summary.readings[$0..<min($0 + perRow, summary.readings.count)])
        }
    }

    @ViewBuilder
    private func tile(_ reading: PlaybackStats.Summary.Reading) -> some View {
        let content = VStack(alignment: .leading, spacing: isTV ? 8 : 2) {
            Text(reading.title)
                .textCase(.uppercase)
                .font(.system(size: isTV ? 18 : 10, weight: .semibold))
                .tracking(isTV ? 1.6 : 0.8)
                .foregroundStyle(.white.opacity(0.68))
            HStack(spacing: isTV ? 10 : 4) {
                if reading.needsAttention {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
                Text(reading.value)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.system(size: isTV ? 32 : 16, weight: .semibold))
            if let detail = reading.detail {
                Text(detail)
                    .font(.system(size: isTV ? 22 : 11))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)

        if isTV {
            content
                .padding(20)
                .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                )
        } else {
            content
        }
    }

    private var statusSymbol: String {
        switch summary.health {
        case .good: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .neutral:
            // The status is in the app's language, as the projection wrote it.
            switch summary.status {
            case AppLanguage.string(.playerStatsPhasePaused): return "pause.circle.fill"
            case AppLanguage.string(.playerStatsPhasePlaying): return "play.circle.fill"
            default: return "circle.dashed"
            }
        }
    }

    private var statusTint: Color {
        switch summary.health {
        case .good: return .green
        case .attention: return .yellow
        case .neutral: return .white.opacity(0.85)
        }
    }
}
