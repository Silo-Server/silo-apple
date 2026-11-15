import SwiftUI

struct PlaybackStatsPanel: View {
    /// How the same row set is dressed. The rows themselves always come from
    /// `PlaybackStats`, so the platforms can't drift on *what* is reported —
    /// only on how much chrome is drawn around it.
    enum Layout {
        /// tvOS Stats pane and the Mac options panel: uppercase section
        /// headers, trailing-aligned label column, monospaced values. Reads
        /// as a panel, and shows every section.
        case sectioned
        /// iOS overlay: one flat `Label:  value` list, no section headers,
        /// drawn straight onto the picture. Reads as annotation, and leaves
        /// Aether's internals out.
        case plain
    }

    let stats: PlaybackStats
    var layout: Layout = .sectioned
    var usesTVTypography = false
    var usesTwoColumnLayout = false

    static let playbackSectionID = "stats-playback"
    static let streamSectionID = "stats-stream"
    static let engineSectionID = "stats-engine"

    var body: some View {
        Group {
            switch layout {
            case .plain:
                plainList
            case .sectioned where usesTwoColumnLayout:
                HStack(alignment: .top, spacing: 34) {
                    column(leftSections)
                    divider
                    column(rightSections)
                }
            case .sectioned:
                column(allSections)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Plain layout

    /// Flat `Label:` / value grid over `overlayRows`. Draws no background of
    /// its own — the overlay owns that, so this stays reusable as bare
    /// annotation. Single column by design: the overlay set is short enough
    /// to fit a phone in landscape, which is what lets the overlay stay
    /// inert (no scrolling) without clipping anything.
    private var plainList: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(stats.overlayRows) { row in
                GridRow {
                    // A row with no label continues the one above it.
                    Text(verbatim: row.label.isEmpty ? "" : "\(row.label):")
                        .foregroundStyle(.white.opacity(0.58))
                        .gridColumnAlignment(.leading)
                    Text(row.value)
                        .foregroundStyle(.white.opacity(0.95))
                        // The plate hugs its rows; a long value wraps here
                        // instead of widening it across the picture, and
                        // stops at two lines so the plate keeps its height.
                        .lineLimit(2)
                        .frame(maxWidth: 340, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 11))
    }

    /// What is playing: the wide values, so it gets a column to itself.
    private var leftSections: [StatsSection] {
        [
            .init(id: Self.playbackSectionID, title: .playerHudPlayback, rows: stats.playbackRows)
        ]
    }

    private var rightSections: [StatsSection] {
        [
            .init(id: Self.streamSectionID, title: .playerHudStream, rows: stats.streamRows),
            .init(id: Self.engineSectionID, title: .playerStatsSectionEngine, rows: stats.engineRows)
        ]
    }

    private var allSections: [StatsSection] {
        leftSections + rightSections
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }

    private func column(_ sections: [StatsSection]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 10) {
            ForEach(sections) { section in
                rows(for: section)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func rows(for section: StatsSection) -> some View {
        if !section.rows.isEmpty {
            GridRow {
                Text(section.title)
                    .textCase(.uppercase)
                    .font(headerFont)
                    .foregroundStyle(.white.opacity(0.52))
                    .gridColumnAlignment(.trailing)
                    .id(section.id)
                Color.clear
                    .frame(height: 1)
            }
            ForEach(section.rows) { row in
                GridRow {
                    Text(row.label)
                        .font(labelFont)
                        .foregroundStyle(.white.opacity(0.74))
                    Text(row.value)
                        .font(valueFont)
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        // A line of several words may take a second line. A
                        // single token, such as a host name, shrinks instead
                        // of breaking in the middle.
                        .lineLimit(row.value.contains(" ") ? 2 : 1)
                        .minimumScaleFactor(0.76)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var headerFont: Font {
        usesTVTypography
            ? .system(size: 13, weight: .semibold)
            : .caption.weight(.semibold)
    }

    private var labelFont: Font {
        usesTVTypography
            ? .system(size: 20, weight: .medium)
            : .callout.weight(.medium)
    }

    private var valueFont: Font {
        usesTVTypography
            ? .system(size: 20, weight: .regular)
            : .callout.monospacedDigit()
    }

    private struct StatsSection: Identifiable {
        let id: String
        let title: LocalizedStringResource
        let rows: [PlaybackStats.Row]
    }
}
