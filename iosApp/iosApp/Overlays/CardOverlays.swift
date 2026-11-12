import NukeUI
import SwiftUI

/// Renders the enabled overlay badges for an item where the profile's prefs
/// place them: the top-left corner, the two bottom corners, and a rail
/// centred on each side edge. Designed to layer over a card's artwork, under
/// any focus chrome. Adds nothing when no badge is visible.
///
/// The layout rules are the web's (`web/src/components/overlays/CardOverlays.tsx`
/// and `docs/architecture/card-overlays.md` in silo-server), so a card looks
/// the same on every client:
///
/// - A corner draws at most three badges and a rail four; the rest are
///   dropped rather than overlapping.
/// - The top-right corner belongs to `CardWatchStatus`. No badge is drawn
///   there, and the top row stops short of it on poster cards.
/// - A filled badge on a rail is a tab, flush against the card edge.
/// - The bottom corners share the bottom edge row by row.
/// - The `band` preset draws each edge's badges as one strip over a scrim.
///
/// Usage:
/// ```
/// ZStack {
///     posterImage
///     CardOverlays(data: .from(item), prefs: prefs, variant: .poster)
/// }
/// ```
struct CardOverlays: View {
    /// The measured poster overlay layer on the web Home carousel. Every
    /// length below is in points at this card width and scales with the card.
    static let posterReferenceWidth: CGFloat = 185
    static let edgeInset: CGFloat = 8
    static let edgeGap: CGFloat = 8

    private static let maxBadgesPerCorner = 3
    private static let maxBadgesPerRail = 4
    /// The share of the card's width a rail's badges may take.
    private static let railMaxWidth: CGFloat = 0.6

    let data: OverlayData
    let prefs: CardOverlayPrefs
    var variant: Variant = .poster
    /// The server's uploaded badge images by ref (`OverlayPrefsStore.images`).
    var images: [String: OverlayImageAsset] = [:]
    /// Set by hosts that draw a watch-progress bar along the bottom of the
    /// artwork. The bar occupies the same strip as the bottom badge row, so
    /// the row rises clear of it.
    var hasProgressBar = false

    enum Variant {
        case poster      // standard 2:3 poster card
        case wide        // backdrop card (continue watching, hero) — leaves
                         // headroom for the title block / progress bar.
    }

    var body: some View {
        let preset = OverlayPresets.preset(prefs.preset).applying(prefs.style)
        let topLeft = resolve(.topLeft, preset: preset, limit: Self.maxBadgesPerCorner)
        let bottomLeft = resolve(.bottomLeft, preset: preset, limit: Self.maxBadgesPerCorner)
        let bottomRight = resolve(.bottomRight, preset: preset, limit: Self.maxBadgesPerCorner)
        let leftRail = resolve(.leftEdge, preset: preset, limit: Self.maxBadgesPerRail)
        let rightRail = resolve(.rightEdge, preset: preset, limit: Self.maxBadgesPerRail)

        GeometryReader { proxy in
            let scale = variant == .poster ? proxy.size.width / Self.posterReferenceWidth : 1
            let context = BadgeContext(preset: preset, scale: scale)
            let inset = Self.edgeInset * scale
            // Poster cards keep the top-right corner clear for the
            // watch-status indicator; wide cards never draw it.
            let topTrailing = variant == .poster
                ? inset + (CardWatchStatus.size + Self.edgeGap) * scale
                : inset
            let bottomPadding = bottomInset(inset: inset)
            let band = preset.layout == .band
            // A filled badge on a rail sits flush against the edge as a tab;
            // a transparent one (minimal, band) keeps the corner inset.
            let flushRails = !band && preset.id != .minimal
            let railInset = flushRails ? 0 : inset
            let railWidth = proxy.size.width * Self.railMaxWidth

            ZStack {
                if !topLeft.isEmpty {
                    if band {
                        BandMarks(badges: topLeft, context: context)
                            .padding(EdgeInsets(top: inset, leading: inset, bottom: inset * 3, trailing: topTrailing))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Self.bandScrim(from: .top))
                            .frame(maxHeight: .infinity, alignment: .top)
                    } else {
                        BadgeStack(badges: topLeft, alignment: .leading, context: context)
                            .padding(EdgeInsets(top: inset, leading: inset, bottom: 0, trailing: topTrailing))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                if !leftRail.isEmpty {
                    BadgeStack(badges: leftRail, alignment: .leading, context: context, rail: flushRails ? .left : nil)
                        .frame(maxWidth: railWidth, alignment: .leading)
                        .padding(.leading, railInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                if !rightRail.isEmpty {
                    BadgeStack(badges: rightRail, alignment: .trailing, context: context, rail: flushRails ? .right : nil)
                        .frame(maxWidth: railWidth, alignment: .trailing)
                        .padding(.trailing, railInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
                if !bottomLeft.isEmpty || !bottomRight.isEmpty {
                    if band {
                        // One centred strip for the whole bottom edge, left corner first.
                        BandMarks(badges: bottomLeft + bottomRight, context: context)
                            .padding(EdgeInsets(top: inset * 3, leading: inset, bottom: bottomPadding, trailing: inset))
                            .frame(maxWidth: .infinity)
                            .background(Self.bandScrim(from: .bottom))
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    } else {
                        BottomRows(left: bottomLeft, right: bottomRight, context: context, gap: Self.edgeGap * scale)
                            .padding(EdgeInsets(top: 0, leading: inset, bottom: bottomPadding, trailing: inset))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        // Positions are on the artwork, which doesn't mirror: the layer lays
        // out left to right in every language, as on web.
        .environment(\.layoutDirection, .leftToRight)
        .allowsHitTesting(false)
    }

    private func resolve(_ position: OverlayPosition, preset: OverlayPreset, limit: Int) -> [ResolvedBadge] {
        let badges = OverlayRegistry.enabled(at: position, in: prefs).compactMap {
            ResolvedBadge(def: $0, data: data, config: prefs.items[$0.id], preset: preset, images: images)
        }
        return Array(badges.prefix(limit))
    }

    private func bottomInset(inset: CGFloat) -> CGFloat {
        switch variant {
        // Wide cards leave more bottom room because a title block or
        // progress bar typically sits under the image.
        case .wide: return 24
        case .poster: return hasProgressBar ? inset * 2 : inset
        }
    }

    /// The band layout's scrim, darkest at the card edge it starts from.
    private static func bandScrim(from edge: VerticalEdge) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.85), location: 0),
                .init(color: .black.opacity(0.6), location: 0.55),
                .init(color: .black.opacity(0), location: 1),
            ],
            startPoint: edge == .top ? .top : .bottom,
            endPoint: edge == .top ? .bottom : .top
        )
    }
}

// MARK: - Badge resolution

/// What one badge draws for an item. A missing label suppresses the badge.
private struct ResolvedBadge: Identifiable {
    let id: OverlayId
    let label: String
    let iconId: OverlayIconId?
    let accent: OverlayColor?
    /// Uploaded images: one in the icon's place, or one for the whole badge.
    let image: OverlayImageAsset?
    let valueImage: OverlayImageAsset?
    /// The rating's source mark and bare score, when the badge has both.
    let sourceMark: String?
    let score: String?

    init?(
        def: OverlayDef,
        data: OverlayData,
        config: OverlayItemConfig?,
        preset: OverlayPreset,
        images: [String: OverlayImageAsset]
    ) {
        guard let label = def.getValue(data), !label.isEmpty else { return nil }
        let candidateIcon = def.getIcon?(data) ?? def.iconId
        let showIcon = def.iconCapable && candidateIcon != nil && (config?.showIcon ?? preset.preferIcon)
        let score = def.getScore?(data)
        id = def.id
        self.label = label
        iconId = showIcon ? candidateIcon : nil
        accent = (config?.accentColor ?? def.defaultAccent).flatMap(OverlayColor.init(hex:))
        image = config?.image.flatMap { images[$0] }
        valueImage = def.getValueKey?(data).flatMap { config?.valueImages[$0] }.flatMap { images[$0] }
        sourceMark = score == nil ? nil : def.sourceMark
        self.score = score
    }

    /// A wordmark icon (HDR10, ATMOS, ...) spells its text as the mark
    /// itself; when the label says the same thing, showing both reads
    /// "HDR10 HDR10".
    var labelRepeatsIcon: Bool {
        guard let mark = iconId?.wordmark else { return false }
        return mark.caseInsensitiveCompare(label.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }
}

/// The preset and card scale every badge on one card shares.
private struct BadgeContext {
    let preset: OverlayPreset
    let scale: CGFloat

    func length(_ points: CGFloat) -> CGFloat { points * scale }
    var fontSize: CGFloat { preset.fontSize * scale }
    var stackGap: CGFloat { preset.stackGap * scale }
}

private enum Rail {
    case left
    case right
}

// MARK: - Layouts

/// One position's badges, stacked.
private struct BadgeStack: View {
    let badges: [ResolvedBadge]
    let alignment: HorizontalAlignment
    let context: BadgeContext
    var rail: Rail? = nil

    var body: some View {
        VStack(alignment: alignment, spacing: context.stackGap) {
            ForEach(badges) { badge in
                OverlayBadgeView(badge: badge, context: context, rail: rail)
            }
        }
    }
}

/// The two bottom corners, drawn one row per level from the bottom up, so
/// each badge shares its width only with the badge beside it. Side-by-side
/// columns would each be as wide as their widest badge, and a long badge in
/// one corner would cut the other corner's badges short even where the pair
/// at each height fits. A pair too wide for the card wraps, the right badge
/// onto a line of its own, so only a badge wider than the card on its own is
/// cut short.
private struct BottomRows: View {
    let left: [ResolvedBadge]
    let right: [ResolvedBadge]
    let context: BadgeContext
    let gap: CGFloat

    var body: some View {
        let levels = max(left.count, right.count)
        VStack(spacing: context.stackGap) {
            ForEach(0..<levels, id: \.self) { level in
                row(left: badge(left, at: level, of: levels), right: badge(right, at: level, of: levels))
            }
        }
    }

    /// Level 0 is the top row, so the shorter corner lines up with the bottom.
    private func badge(_ badges: [ResolvedBadge], at level: Int, of levels: Int) -> ResolvedBadge? {
        let index = badges.count - levels + level
        return index >= 0 ? badges[index] : nil
    }

    @ViewBuilder
    private func row(left: ResolvedBadge?, right: ResolvedBadge?) -> some View {
        switch (left, right) {
        case let (left?, right?):
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 0) {
                    OverlayBadgeView(badge: left, context: context)
                    Spacer(minLength: gap)
                    OverlayBadgeView(badge: right, context: context)
                }
                VStack(alignment: .trailing, spacing: context.stackGap) {
                    OverlayBadgeView(badge: left, context: context)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    OverlayBadgeView(badge: right, context: context)
                }
            }
            .frame(maxWidth: .infinity)
        case let (left?, nil):
            OverlayBadgeView(badge: left, context: context)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let (nil, right?):
            OverlayBadgeView(badge: right, context: context)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case (nil, nil):
            EmptyView()
        }
    }
}

/// The band layout draws an edge's badges as one row of marks with thin
/// dividers between them. The row shows the marks that fit whole, in the
/// viewer's order, and drops the rest, as a corner drops badges past its
/// cap: a cut mark ("AT…") says nothing. Only a first mark too wide on its
/// own truncates.
private struct BandMarks: View {
    let badges: [ResolvedBadge]
    let context: BadgeContext

    var body: some View {
        if badges.count < 2 {
            row(badges)
        } else {
            // The longest row that fits; the single-mark row is the fallback
            // and the only one that may truncate.
            ViewThatFits(in: .horizontal) {
                ForEach((1...badges.count).reversed(), id: \.self) { count in
                    row(Array(badges.prefix(count)))
                }
            }
        }
    }

    private func row(_ marks: [ResolvedBadge]) -> some View {
        HStack(spacing: context.stackGap) {
            ForEach(Array(marks.enumerated()), id: \.element.id) { index, badge in
                if index > 0 {
                    Rectangle()
                        .fill(.white.opacity(0.4))
                        .frame(width: 1, height: context.fontSize * 0.9)
                }
                OverlayBadgeView(badge: badge, context: context)
            }
        }
    }
}

// MARK: - Badge

/// Renders one resolved badge on a media card.
private struct OverlayBadgeView: View {
    /// An uploaded image that replaces a whole badge is this many times the
    /// height of the text badge it stands in for, so a logo reads as a logo.
    private static let valueImageScale: CGFloat = 1.6

    let badge: ResolvedBadge
    let context: BadgeContext
    var rail: Rail? = nil

    /// Uploaded images that did not load (an administrator deleted one); the
    /// badge falls back to what it draws without them.
    @State private var failedImages: Set<URL> = []

    private var preset: OverlayPreset { context.preset }

    var body: some View {
        if let valueImage = usable(badge.valueImage) {
            let height = context.length((preset.fontSize + preset.paddingBlock * 2) * Self.valueImageScale)
            uploadedImage(valueImage, height: height)
        } else {
            textBadge
        }
    }

    private func usable(_ asset: OverlayImageAsset?) -> OverlayImageAsset? {
        guard let asset, !failedImages.contains(asset.url) else { return nil }
        return asset
    }

    private var textBadge: some View {
        let paint = preset.paint(badge.accent)
        let foreground = paint.foreground.color
        let iconImage = usable(badge.image)
        // An uploaded image beside a rating stands for its source, so the
        // label drops the mark; the plate preset draws the mark as a chip.
        let sourceChip = iconImage == nil && preset.sourceChips ? badge.sourceMark : nil
        let scoreOnly = (iconImage != nil || sourceChip != nil) && badge.score != nil
        let text = scoreOnly ? badge.score : (badge.labelRepeatsIcon ? nil : badge.label)
        let borderWidth = context.length(max(preset.borderWidth ?? 0, 0))
        let barWidth = rail == .left ? nil : accentBarWidth(paint)
        let shape = OverlayBadgeShape(cornerStyle: preset.cornerStyle, scale: context.scale, flushEdge: rail)

        return HStack(spacing: context.length(preset.iconGap)) {
            if let iconImage {
                uploadedImage(iconImage, height: context.length(preset.iconSize))
            } else if let sourceChip {
                sourceChipView(sourceChip, color: badge.accent ?? .white)
            } else if let iconId = badge.iconId {
                OverlayIcon(iconId: iconId, size: context.length(preset.iconSize), tint: foreground)
            }
            if let text {
                // A cut score ("6.") misleads, so a bare score never truncates.
                label(text, color: foreground)
                    .fixedSize(horizontal: scoreOnly, vertical: false)
                    .modifier(BadgeShadow(shadow: preset.textShadow, scale: context.scale))
            }
        }
        .padding(.horizontal, context.length(preset.paddingInline))
        .padding(.vertical, context.length(preset.paddingBlock))
        // A border sits outside the padding, as CSS draws it. A rail tab has
        // none on the side against the card edge.
        .padding(.vertical, borderWidth)
        .padding(.leading, rail == .left ? 0 : max(borderWidth, barWidth ?? 0))
        .padding(.trailing, rail == .right ? 0 : borderWidth)
        .background {
            ZStack(alignment: .leading) {
                shape.fill(paint.background.color)
                if let barWidth, let bar = paint.accentBar {
                    Rectangle().fill(bar.color).frame(width: barWidth)
                }
            }
            .clipShape(shape)
            .modifier(BadgeShadow(shadow: preset.boxShadow, scale: context.scale))
        }
        .overlay {
            if borderWidth > 0 {
                // The stroke runs past the flush edge and is clipped there,
                // so a rail tab is open on that side.
                shape.strokeBorder((paint.border ?? paint.foreground).color, lineWidth: borderWidth)
                    .padding(.leading, rail == .left ? -borderWidth : 0)
                    .padding(.trailing, rail == .right ? -borderWidth : 0)
                    .clipped()
            }
        }
    }

    /// The accent bar `.square` draws on a badge's left side.
    private func accentBarWidth(_ paint: OverlayBadgePaint) -> CGFloat? {
        guard let width = preset.accentBarWidth, paint.accentBar != nil else { return nil }
        return context.length(width)
    }

    /// One line of badge text. The frame is the web's `leading-none`: the
    /// line is as tall as the font size, so padding alone sets the badge's
    /// height.
    private func label(_ text: String, color: Color) -> some View {
        Text(verbatim: text)
            .font(.system(size: context.fontSize, weight: preset.fontWeight))
            .tracking(preset.trackingEm * context.fontSize)
            .textCase(preset.uppercase ? .uppercase : nil)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(height: context.fontSize)
    }

    /// A rating's source mark as an accent-coloured chip ahead of the score.
    private func sourceChipView(_ mark: String, color: OverlayColor) -> some View {
        let fontSize = context.fontSize
        return label(mark, color: color.readableText.color)
            .fixedSize()
            .padding(.horizontal, fontSize * 0.35)
            .padding(.vertical, fontSize * 0.15)
            .background(RoundedRectangle(cornerRadius: fontSize * 0.2).fill(color.color))
    }

    private func uploadedImage(_ asset: OverlayImageAsset, height: CGFloat) -> some View {
        LazyImage(url: asset.url) { state in
            if let image = state.image {
                image.resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .onCompletion { result in
            if case .failure = result { failedImages.insert(asset.url) }
        }
        .aspectRatio(asset.aspectRatio, contentMode: .fit)
        .frame(height: height)
    }
}

/// A badge's outline: a pill or a rounded rectangle, with the corners on a
/// rail tab's flush edge left square.
private struct OverlayBadgeShape: InsettableShape {
    let cornerStyle: OverlayPreset.CornerStyle
    let scale: CGFloat
    let flushEdge: Rail?
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let limit = min(rect.width, rect.height) / 2
        let radius: CGFloat
        switch cornerStyle {
        case .capsule: radius = limit
        case .rounded(let points): radius = max(0, min(points * scale - insetAmount, limit))
        }
        let left = flushEdge == .left ? 0 : radius
        let right = flushEdge == .right ? 0 : radius
        return Path(
            roundedRect: rect,
            cornerRadii: RectangleCornerRadii(
                topLeading: left, bottomLeading: left, bottomTrailing: right, topTrailing: right
            ),
            style: .circular
        )
    }

    func inset(by amount: CGFloat) -> OverlayBadgeShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

/// A CSS `text-shadow` or `box-shadow`, whose blur radius is about twice
/// SwiftUI's.
private struct BadgeShadow: ViewModifier {
    let shadow: OverlayShadow?
    let scale: CGFloat

    func body(content: Content) -> some View {
        if let shadow {
            content.shadow(
                color: shadow.color.color,
                radius: shadow.blur * scale / 2,
                x: shadow.x * scale,
                y: shadow.y * scale
            )
        } else {
            content
        }
    }
}
