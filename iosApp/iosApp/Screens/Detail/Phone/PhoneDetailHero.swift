#if !os(tvOS)
import SwiftUI

/// Phone detail hero, Apple-TV-style. The backdrop occupies the upper
/// portion of the viewport and is intentionally clean — no overlay
/// chrome — fading softly into the background. Below the fade sits a
/// centered editorial column (eyebrow → title → source → actions →
/// overview → facts) on the dark surface.
///
/// Why this composition: leaving the backdrop unobstructed lets the
/// artwork breathe; centering the metadata column matches the Apple TV
/// app's identity-first layout and gives every CTA a strong horizontal
/// anchor (especially the full-width Play button).
struct PhoneDetailHero<Actions: View>: View {
    let title: String
    let seriesTitle: String?
    let logoUrl: String?
    let backdropUrl: String?
    let backdropThumbhash: String?
    let eyebrow: String?
    let sourceTokens: [String]
    let ratingChip: String?
    let overview: String?
    let factsLine: [PhoneHeroFactToken]
    /// Overlay data for the backdrop. `nil` skips overlay rendering
    /// (e.g. when the detail payload didn't carry an OverlaySummary).
    var overlayData: OverlayData? = nil
    @ViewBuilder let actions: () -> Actions
    /// Optional affordance rendered directly under the overview (e.g. the
    /// on-view description-translation control). Defaults to nothing so
    /// existing call sites are unaffected.
    var belowOverview: () -> AnyView = { AnyView(EmptyView()) }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showFullOverview = false
    @EnvironmentObject private var overlayStore: OverlayPrefsStore

    private var backdropHeight: CGFloat {
        horizontalSizeClass == .regular ? 420 : 360
    }

    var body: some View {
        VStack(spacing: 0) {
            backdropBlock
            editorialColumn
                .padding(.horizontal, ContinuumTheme.safePadding)
                .padding(.top, 4)
                .padding(.bottom, 8)
        }
    }

    // MARK: - Backdrop

    private var backdropBlock: some View {
        ZStack(alignment: .bottom) {
            backdrop
            if let overlayData, overlayStore.enabled {
                CardOverlays(
                    data: overlayData,
                    prefs: overlayStore.prefs,
                    variant: .hero
                )
                .frame(height: backdropHeight)
                .frame(maxWidth: .infinity)
            }
            bottomFade
        }
        .frame(height: backdropHeight)
        .frame(maxWidth: .infinity)
        // Intentionally no hard rectangle clip here. The backdrop's background
        // extension (applied below) mirrors/blurs the artwork past its frame into
        // the top safe area and the horizontal screen edges (the callers apply
        // ignoresSafeArea on the top edge). Clipping to the fixed-height rectangle
        // would defeat that edge-to-edge bleed.
    }

    private var backdrop: some View {
        Group {
            if let url = backdropUrl, !url.isEmpty {
                AsyncImageView(url: url, thumbhash: backdropThumbhash, contentMode: .fill)
            } else {
                Color.continuumSurface
            }
        }
        .frame(height: backdropHeight)
        .frame(maxWidth: .infinity)
        // Mirror + blur the source artwork to fill behind the status bar /
        // Dynamic Island and out to the screen edges — the Apple TV / Music
        // detail-page continuation, instead of a hard banner edge. All Apple
        // targets are at the 26 minimum, so this is unconditional.
        .backgroundExtensionEffect()
    }

    /// Soft single-direction fade — only enough to let text below sit
    /// on the background without a visible seam. The artwork stays
    /// readable across most of the hero.
    private var bottomFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .clear, location: 0.55),
                .init(color: Color.continuumBackground.opacity(0.6), location: 0.85),
                .init(color: Color.continuumBackground, location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Editorial column

    private var editorialColumn: some View {
        VStack(spacing: 14) {
            if let eyebrow, !eyebrow.isEmpty {
                PhoneHeroEyebrow(text: eyebrow)
            }
            titleBlock
            sourceRow
            actions()
                .padding(.top, 6)
            overviewBlock
            belowOverview()
            factsRow
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var titleBlock: some View {
        if let episodeSeriesTitle {
            PhoneEpisodeHierarchyTitle(seriesTitle: episodeSeriesTitle, episodeTitle: title)
        } else if let logoUrl, !logoUrl.isEmpty {
            AsyncImageView(url: logoUrl, contentMode: .fit, placeholderStyle: .clear)
                .frame(height: logoHeight)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(title)
        } else {
            PhoneHeroTitle(title: title)
        }
    }

    private var episodeSeriesTitle: String? {
        guard let trimmed = seriesTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// Hero logo height — sized so wordmarks match the visual weight of
    /// Apple TV's hero treatment (large and dominant, but leaves room
    /// for the source row and CTA stack below).
    private var logoHeight: CGFloat {
        horizontalSizeClass == .regular ? 200 : 160
    }

    @ViewBuilder
    private var sourceRow: some View {
        if !sourceTokens.isEmpty || ratingChip != nil {
            HStack(spacing: 8) {
                ForEach(Array(sourceTokens.enumerated()), id: \.offset) { index, token in
                    if index > 0 {
                        Text("·")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.continuumOnSurface.opacity(0.4))
                    }
                    Text(token)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.continuumOnSurface.opacity(0.85))
                        .lineLimit(1)
                }
                if let ratingChip, !ratingChip.isEmpty {
                    Text(ratingChip)
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(0.8)
                        .foregroundColor(.continuumOnSurface)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.continuumOnSurface.opacity(0.55), lineWidth: 1)
                        )
                        .padding(.leading, 2)
                }
            }
            .multilineTextAlignment(.center)
        }
    }

    // MARK: - Overview with inline MORE pill

    @ViewBuilder
    private var overviewBlock: some View {
        if let overview, !overview.isEmpty {
            VStack(spacing: 0) {
                Text(overview)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(.continuumOnSurface.opacity(0.78))
                    .lineSpacing(3)
                    .lineLimit(showFullOverview ? nil : 3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottomTrailing) {
                        if !showFullOverview, isOverviewClipped {
                            morePill
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: ContinuumTheme.normalDuration)) {
                            showFullOverview.toggle()
                        }
                    }
            }
            .padding(.top, 8)
        }
    }

    private var morePill: some View {
        Button {
            withAnimation(.easeInOut(duration: ContinuumTheme.normalDuration)) {
                showFullOverview = true
            }
        } label: {
            Text("MORE")
                .font(.system(size: 11, weight: .heavy))
                .tracking(0.6)
                .foregroundColor(.continuumOnSurface)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(Color.continuumSurfaceElevated)
                )
        }
        .buttonStyle(.plain)
    }

    private var isOverviewClipped: Bool {
        (overview?.count ?? 0) > 140
    }

    // MARK: - Facts row

    @ViewBuilder
    private var factsRow: some View {
        if !factsLine.isEmpty {
            FlowingFactsRow(tokens: factsLine)
                .padding(.top, 4)
        }
    }
}

// MARK: - Title

private struct PhoneHeroTitle: View {
    let title: String

    var body: some View {
        let parts = PhoneHeroMetadata.splitTitle(title)
        VStack(spacing: 4) {
            Text(parts.primary)
                .font(.system(size: 30, weight: .heavy))
                .foregroundColor(.continuumOnSurface)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = parts.subtitle {
                Text(subtitle.uppercased())
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(1.2)
                    .foregroundColor(.continuumOnSurface.opacity(0.8))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PhoneEpisodeHierarchyTitle: View {
    let seriesTitle: String
    let episodeTitle: String

    var body: some View {
        let parts = PhoneHeroMetadata.splitTitle(episodeTitle)
        VStack(spacing: 6) {
            Text(seriesTitle)
                .font(.system(size: 34, weight: .heavy))
                .foregroundColor(.continuumOnSurface)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(parts.primary)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.continuumOnSurface.opacity(0.9))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = parts.subtitle {
                Text(subtitle.uppercased())
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(1.0)
                    .foregroundColor(.continuumOnSurface.opacity(0.76))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Eyebrow

private struct PhoneHeroEyebrow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.6)
            .foregroundColor(.continuumOnSurface)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color.continuumSurfaceElevated)
            )
    }
}

// MARK: - Facts row (wraps when needed)

/// Centered facts row that line-wraps when the tokens exceed the
/// container width. SwiftUI's plain HStack truncates instead of
/// wrapping, so we lean on `Layout` to flow the chips like Apple's
/// quality-badge row beneath the overview.
private struct FlowingFactsRow: View {
    let tokens: [PhoneHeroFactToken]

    var body: some View {
        PhoneFactsFlowLayout(spacing: 8, lineSpacing: 6, alignment: .center) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                if index > 0,
                   case .text = token,
                   case .text = tokens[index - 1] {
                    Text("·")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.continuumOnSurface.opacity(0.4))
                }
                factsItem(token)
            }
        }
    }

    @ViewBuilder
    private func factsItem(_ token: PhoneHeroFactToken) -> some View {
        switch token {
        case .text(let value):
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.continuumOnSurface.opacity(0.78))
        case .rating(let value):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.continuumSuccess.opacity(0.9))
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.continuumOnSurface.opacity(0.78))
            }
        case .chip(let value):
            Text(value)
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.8)
                .foregroundColor(.continuumOnSurface)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.continuumOnSurface.opacity(0.45), lineWidth: 1)
                )
        }
    }
}

/// Minimal flow layout that wraps subviews onto new lines when the
/// proposed width can't fit them. Uses each subview's intrinsic
/// width — no shrinking — so every chip stays at its natural size.
private struct PhoneFactsFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    var alignment: HorizontalAlignment

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let lines = layoutLines(maxWidth: maxWidth, subviews: subviews)
        let height = lines.reduce(0) { acc, line in acc + line.height + lineSpacing } - lineSpacing
        let width = lines.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth), height: max(0, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        let lines = layoutLines(maxWidth: maxWidth, subviews: subviews)
        var y = bounds.minY
        for line in lines {
            let extra = max(0, maxWidth - line.width)
            var x = bounds.minX + (alignment == .center ? extra / 2 : 0)
            for entry in line.entries {
                entry.subview.place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: entry.size.width, height: entry.size.height)
                )
                x += entry.size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Entry { let subview: LayoutSubview; let size: CGSize }
    private struct Line { var entries: [Entry] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func layoutLines(maxWidth: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = [Line()]
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let candidateWidth = lines[lines.count - 1].width
                + (lines[lines.count - 1].entries.isEmpty ? 0 : spacing)
                + size.width
            if candidateWidth > maxWidth, !lines[lines.count - 1].entries.isEmpty {
                lines.append(Line())
            }
            let isFirst = lines[lines.count - 1].entries.isEmpty
            lines[lines.count - 1].entries.append(Entry(subview: subview, size: size))
            lines[lines.count - 1].width += (isFirst ? 0 : spacing) + size.width
            lines[lines.count - 1].height = max(lines[lines.count - 1].height, size.height)
        }
        return lines
    }
}
#endif
