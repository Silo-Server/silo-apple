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
                rows(for: section, isFirstInColumn: section.id == sections.first?.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func rows(for section: StatsSection, isFirstInColumn: Bool) -> some View {
        if !section.rows.isEmpty {
            if usesTVTypography {
                // TV: each section opens with a full-width heading under a
                // hairline, and its labels line up on one left edge.
                GridRow {
                    VStack(alignment: .leading, spacing: 12) {
                        if !isFirstInColumn {
                            Rectangle()
                                .fill(Color.white.opacity(0.12))
                                .frame(height: 1)
                                .padding(.top, 10)
                        }
                        Text(section.title)
                            .textCase(.uppercase)
                            .font(headerFont)
                            .tracking(1.6)
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    .gridCellColumns(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(TVWholeRowCell())
                    .id(section.id)
                }
            } else {
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
            }
            ForEach(section.rows, id: \.0) { row in
                GridRow {
                    Text(row.0)
                        .font(labelFont)
                        .foregroundStyle(.white.opacity(usesTVTypography ? 0.68 : 0.74))
                        .frame(minWidth: usesTVTypography ? 260 : nil, alignment: .leading)
                        .modifier(TVWholeRowCell(isEnabled: usesTVTypography, fillsRow: true))
                    // On TV a long value (codec chains) wraps rather than
                    // shrinking or ending in an ellipsis.
                    Text(row.1)
                        .font(valueFont)
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .lineLimit(usesTVTypography ? 3 : 1)
                        .minimumScaleFactor(usesTVTypography ? 1 : 0.76)
                        .fixedSize(horizontal: false, vertical: usesTVTypography)
                        .modifier(TVWholeRowCell(isEnabled: usesTVTypography))
                }
            }
        }
    }

    private var headerFont: Font {
        usesTVTypography
            ? .system(size: 18, weight: .semibold)
            : .caption.weight(.semibold)
    }

    private var labelFont: Font {
        // TV: quieter labels so the readings carry the weight.
        usesTVTypography
            ? .system(size: 21, weight: .regular)
            : .callout.weight(.medium)
    }

    private var valueFont: Font {
        usesTVTypography
            ? .system(size: 24, weight: .semibold)
            : .callout.monospacedDigit()
    }

    /// TV: a row shows only while all of it is inside the scroll view, as
    /// the HUD's lists do, so a page never ends on a cut line under its
    /// "More" cue.
    private struct TVWholeRowCell: ViewModifier {
        var isEnabled = true
        /// As tall as the row (a label beside a wrapped value), so the two
        /// hide together, without asking the grid for more height.
        var fillsRow = false

        func body(content: Content) -> some View {
            if isEnabled {
                content
                    .frame(maxHeight: fillsRow ? .infinity : nil, alignment: .topLeading)
                    .gridCellUnsizedAxes(fillsRow ? .vertical : [])
                    .visualEffect { effect, proxy in
                        let viewport = proxy.bounds(of: .scrollView(axis: .vertical))
                        let whole = viewport.map { $0.minY <= 0.5 && $0.maxY >= proxy.size.height - 0.5 } ?? true
                        return effect.opacity(whole ? 1 : 0)
                    }
            } else {
                content
            }
        }
    }

    private struct StatsSection: Identifiable {
        let id: String
        let title: LocalizedStringResource
        let rows: [(String, String)]
    }
}
