import SwiftUI

struct PlaybackStatsPanel: View {
    /// How the same row set is dressed. The rows themselves always come from
    /// `PlaybackStats`, so the platforms can't drift on *what* is reported —
    /// only on how much chrome is drawn around it.
    enum Layout {
        /// tvOS Info HUD pane: uppercase section headers, trailing-aligned
        /// label column, monospaced values. Reads as a panel.
        case sectioned
        /// iOS overlay: one flat `Label:  value` list, no section headers,
        /// drawn straight onto the picture. Reads as annotation.
        case plain
    }

    let stats: PlaybackStats
    var layout: Layout = .sectioned
    var usesTVTypography = false
    var usesTwoColumnLayout = false

    static let sourceSectionID = "stats-source"
    static let mediaSectionID = "stats-media"
    static let bufferSectionID = "stats-buffer"
    static let networkSectionID = "stats-network"
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

    /// Flat `Label:` / value grid over `compactRows`. Draws no background of
    /// its own — the overlay owns that, so this stays reusable as bare
    /// annotation. Single column by design: the compact set is short enough
    /// to fit a phone in landscape, which is what lets the overlay stay
    /// inert (no scrolling) without clipping anything.
    private var plainList: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(Array(plainGroups.enumerated()), id: \.offset) { index, group in
                // A caption per group, so the compact set reads as three
                // short lists rather than one wall of fields.
                GridRow {
                    Text(group.title)
                        .textCase(.uppercase)
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.top, index == 0 ? 0 : 8)
                        .gridCellColumns(2)
                }
                ForEach(group.rows, id: \.0) { row in
                    GridRow {
                        Text(row.0)
                            .foregroundStyle(.white.opacity(0.66))
                            .gridColumnAlignment(.leading)
                        Text(row.1)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .font(.system(size: 12))
    }

    /// `compactRows`, grouped as the sectioned layout groups them.
    private var plainGroups: [(title: LocalizedStringResource, rows: [(String, String)])] {
        let compact = Set(stats.compactRows.map(\.0))
        func pick(_ rows: [(String, String)]) -> [(String, String)] {
            rows.filter { compact.contains($0.0) }
        }
        return [
            (title: .playerStatsSectionSource, rows: pick(stats.sourceRows)),
            (title: .playerStatsSectionMedia, rows: pick(stats.mediaRows)),
            (title: .playerHudPlayback, rows: pick(stats.bufferRows + stats.networkRows))
        ].filter { !$0.rows.isEmpty }
    }

    private var leftSections: [StatsSection] {
        [
            .init(id: Self.sourceSectionID, title: .playerStatsSectionSource, rows: stats.sourceRows),
            .init(id: Self.mediaSectionID, title: .playerStatsSectionMedia, rows: stats.mediaRows)
        ]
    }

    private var rightSections: [StatsSection] {
        [
            .init(id: Self.bufferSectionID, title: .playerStatsSectionBuffer, rows: stats.bufferRows),
            .init(id: Self.networkSectionID, title: .playerStatsSectionNetwork, rows: stats.networkRows),
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
            ForEach(section.rows, id: \.0) { row in
                GridRow {
                    Text(row.0)
                        .font(labelFont)
                        .foregroundStyle(.white.opacity(0.74))
                    Text(row.1)
                        .font(valueFont)
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
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
        let rows: [(String, String)]
    }
}
