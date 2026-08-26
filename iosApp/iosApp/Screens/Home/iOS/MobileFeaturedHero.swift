#if os(iOS)
import SwiftUI

/// Server-driven Home cards for iPhone and iPad. The featured section is
/// rendered once here and removed from the rows below.
struct MobileFeaturedHero: View {
    let items: [SectionItem]
    let usesCardLayout: Bool
    let onPlay: (SectionItem) -> Void
    let onInfo: (SectionItem) -> Void
    let loadTextlessPoster: @Sendable (String, String) async throws -> String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentIndex: Int?
    @State private var lastValidIndex = 0
    @State private var isPagerIdle = true
    @State private var autoAdvanceProgress: CGFloat = 0
    @State private var textlessPosterURLs: [String: String] = [:]
    @State private var unavailableTextlessPosters: Set<String> = []
    @State private var glowTints: [String: Color] = [:]

    private struct AutoAdvanceKey: Hashable {
        let itemIDs: [String]
        let currentIndex: Int?
        let isPagerIdle: Bool
    }

    private struct RenderedCard: Identifiable {
        let id: Int
        let logicalIndex: Int
        let item: SectionItem
    }

    /// Duplicate the trailing/leading cards at opposite ends so the carousel
    /// wraps by one ordinary page instead of animating across the whole list.
    private var renderedCards: [RenderedCard] {
        guard items.count > 1 else {
            return items.enumerated().map {
                RenderedCard(id: $0.offset, logicalIndex: $0.offset, item: $0.element)
            }
        }

        var cards = [RenderedCard(id: 0, logicalIndex: items.count - 1, item: items[items.count - 1])]
        cards.append(contentsOf: items.enumerated().map {
            RenderedCard(id: $0.offset + 1, logicalIndex: $0.offset, item: $0.element)
        })
        cards.append(RenderedCard(id: items.count + 1, logicalIndex: 0, item: items[0]))
        return cards
    }

    private var heroHeight: CGFloat {
        min(max(PlatformScreen.mainBounds.height * 0.61, 500), 620)
    }

    private let indicatorHeight: CGFloat = 23

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let heroWidth = usesCardLayout
                    ? min(max(geometry.size.width - 24, 280), 620)
                    : geometry.size.width
                let pagingInset = usesCardLayout
                    ? max((geometry.size.width - heroWidth) / 2, 0)
                    : 0

                ScrollView(.horizontal) {
                    LazyHStack(spacing: usesCardLayout ? 12 : 0) {
                        ForEach(renderedCards) { card in
                            Group {
                                if usesCardLayout {
                                    ZStack {
                                        cardGlow(for: card.item)

                                        spotlight(card.item, heroWidth: heroWidth)
                                            .frame(width: heroWidth, height: heroHeight)
                                            .clipShape(cardShape)
                                            .overlay {
                                                cardShape.stroke(
                                                    Color.white.opacity(0.09),
                                                    lineWidth: 0.75
                                                )
                                            }
                                    }
                                    .contentShape(cardShape)
                                } else {
                                    spotlight(card.item, heroWidth: heroWidth)
                                        .frame(width: heroWidth, height: heroHeight)
                                        .contentShape(Rectangle())
                                }
                            }
                                .frame(width: heroWidth, height: heroHeight)
                                .onTapGesture { onInfo(card.item) }
                                .id(card.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                // Keep the runway outside the target layout. Padding the
                // LazyHStack makes every programmatic target inherit one extra
                // inset and leaves automatic advances visibly off-centre.
                .contentMargins(.horizontal, pagingInset, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
                // An explicit centre anchor makes both timer advances and manual
                // gestures settle on one complete card instead of a partial page.
                .scrollPosition(id: $currentIndex, anchor: .center)
                .onScrollPhaseChange { _, phase in
                    isPagerIdle = phase == .idle
                    if phase == .idle {
                        normalizeSettledPage()
                    }
                }
            }
            .frame(height: heroHeight)

            if items.count > 1 {
                timedPageIndicator
                    .frame(height: indicatorHeight)
            }
        }
        .frame(height: heroHeight + (items.count > 1 ? indicatorHeight : 0))
        .frame(maxWidth: .infinity)
        .background(alignment: .bottom) {
            if usesCardLayout {
                Rectangle()
                    .fill(
                        RadialGradient(
                            colors: [
                                activeGlowTint.opacity(0.52),
                                activeGlowTint.opacity(0.18),
                                .clear,
                            ],
                            center: .top,
                            startRadius: 0,
                            endRadius: 260
                        )
                    )
                    .frame(height: 230)
                    .offset(y: 120)
                    .blur(radius: 26)
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.45), value: activeContentID)
            }
        }
        .background(Color.continuumBackground)
        .task {
            seedCurrentIndex()
        }
        .task(id: currentItemID) {
            await loadTextlessArtworkAroundCurrentCard()
        }
        .task(id: activeArtworkURL) {
            guard usesCardLayout else { return }
            await loadActiveGlowTint()
        }
        .task(
            id: AutoAdvanceKey(
                itemIDs: items.map(\.contentId),
                currentIndex: currentIndex,
                isPagerIdle: isPagerIdle
            )
        ) {
            var resetTransaction = Transaction()
            resetTransaction.disablesAnimations = true
            withTransaction(resetTransaction) {
                autoAdvanceProgress = 0
            }

            guard items.count > 1 else { return }
            guard isPagerIdle else { return }

            await Task.yield()
            withAnimation(reduceMotion ? nil : .linear(duration: 10)) {
                autoAdvanceProgress = 1
            }

            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            guard !Task.isCancelled, isPagerIdle else { return }

            let nextIndex = min((currentIndex ?? lastValidIndex) + 1, items.count + 1)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.55)) {
                currentIndex = nextIndex
            }
        }
        .onChange(of: items.map(\.contentId)) { _, _ in
            seedCurrentIndex()
        }
        .onChange(of: currentIndex) { _, newIndex in
            guard let newIndex, renderedCards.indices.contains(newIndex) else { return }
            lastValidIndex = newIndex
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Featured")
    }

    private var timedPageIndicator: some View {
        let activeIndex = logicalIndex(forPage: currentIndex ?? lastValidIndex)
        let progress = min(max(autoAdvanceProgress, 0), 1)

        return HStack(spacing: 8) {
            ForEach(items.indices, id: \.self) { index in
                if index == activeIndex {
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.28))
                        Capsule()
                            .fill(Color.white.opacity(0.94))
                            .frame(width: max(7, 32 * progress))
                    }
                    .frame(width: 32, height: 7)
                    .clipped()
                    .accessibilityLabel("Featured item \(index + 1) of \(items.count)")
                } else {
                    Circle()
                        .fill(Color.white.opacity(0.38))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .animation(nil, value: activeIndex)
        .accessibilityElement(children: .contain)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    private var activeContentID: String {
        guard !items.isEmpty else { return "" }
        return items[logicalIndex(forPage: currentIndex ?? lastValidIndex)].contentId
    }

    private var activeGlowTint: Color {
        glowTints[activeContentID] ?? .clear
    }

    private var activeArtworkURL: String? {
        guard !items.isEmpty else { return nil }
        return preferredArtworkURL(
            for: items[logicalIndex(forPage: currentIndex ?? lastValidIndex)]
        )
    }

    private func loadActiveGlowTint() async {
        guard let artwork = activeArtworkURL,
              let url = URL(string: artwork) else { return }
        if let cached = HeroBackdropPalette.cachedTint(for: url) {
            glowTints[activeContentID] = cached
        } else if let tint = await HeroBackdropPalette.tintColor(for: url) {
            withAnimation(.easeInOut(duration: 0.35)) {
                glowTints[activeContentID] = tint
            }
        }
    }

    @ViewBuilder
    private func cardGlow(for item: SectionItem) -> some View {
        if let artwork = preferredArtworkURL(for: item),
           let url = URL(string: artwork) {
            ZStack {
                cardShape
                    .fill(Color.black.opacity(0.88))
                    .blur(radius: 30)
                    .scaleEffect(1.04)

                cardShape
                    .fill((glowTints[item.contentId] ?? .clear).opacity(0.56))
                    .blur(radius: 24)
                    .scaleEffect(1.025)
            }
                .allowsHitTesting(false)
                .task(id: artwork) {
                    if let cached = HeroBackdropPalette.cachedTint(for: url) {
                        glowTints[item.contentId] = cached
                    } else if let tint = await HeroBackdropPalette.tintColor(for: url) {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            glowTints[item.contentId] = tint
                        }
                    }
                }
        }
    }

    private func seedCurrentIndex() {
        guard !items.isEmpty else {
            currentIndex = nil
            lastValidIndex = 0
            return
        }
        let defaultIndex = items.count > 1 ? 1 : 0
        let candidate = currentIndex ?? defaultIndex
        let seededIndex = renderedCards.indices.contains(candidate) ? candidate : defaultIndex
        lastValidIndex = seededIndex
        currentIndex = seededIndex
    }

    private func normalizeSettledPage() {
        guard !items.isEmpty else { return }
        var page = currentIndex ?? lastValidIndex
        if items.count > 1 {
            if page == 0 {
                page = items.count
            } else if page == items.count + 1 {
                page = 1
            }
        } else {
            page = 0
        }

        lastValidIndex = page
        guard currentIndex != page else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            currentIndex = page
        }
    }

    private func logicalIndex(forPage page: Int) -> Int {
        guard items.count > 1 else { return 0 }
        if page <= 0 { return items.count - 1 }
        if page >= items.count + 1 { return 0 }
        return page - 1
    }

    private var currentItemID: String? {
        guard !items.isEmpty else { return nil }
        return items[logicalIndex(forPage: currentIndex ?? lastValidIndex)].contentId
    }

    /// Fetch the visible card and its next neighbour. Keeping this cache local
    /// to Home avoids refetches while the carousel loops but naturally drops it
    /// on profile/server changes when the Home view is rebuilt.
    private func loadTextlessArtworkAroundCurrentCard() async {
        guard !items.isEmpty else { return }
        let index = logicalIndex(forPage: currentIndex ?? lastValidIndex)
        let indexes = items.count > 1 ? [index, (index + 1) % items.count] : [index]

        for candidateIndex in indexes {
            let candidate = items[candidateIndex]
            let contentID = candidate.contentId
            guard textlessPosterURLs[contentID] == nil,
                  !unavailableTextlessPosters.contains(contentID) else { continue }

            do {
                if let url = try await loadTextlessPoster(contentID, candidate.type) {
                    textlessPosterURLs[contentID] = url
                } else {
                    unavailableTextlessPosters.insert(contentID)
                }
            } catch {
                if Task.isCancelled { return }
                // A transient request failure remains retryable when the
                // carousel next visits this item.
                continue
            }
        }
    }

    private func spotlight(_ item: SectionItem, heroWidth: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            artwork(for: item, heroWidth: heroWidth)

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.12), location: 0),
                    .init(color: .clear, location: 0.30),
                    .init(color: .black.opacity(0.18), location: 0.52),
                    .init(color: .black.opacity(0.74), location: 0.76),
                    .init(color: .black.opacity(0.96), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            editorialContent(for: item)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
        }
        .background(Color.continuumSurface)
    }

    @ViewBuilder
    private func artwork(for item: SectionItem, heroWidth: CGFloat) -> some View {
        if let url = preferredArtworkURL(for: item) {
            AsyncImageView(
                url: url,
                thumbhash: item.posterThumbhash ?? item.backdropThumbhash,
                targetSize: CGSize(width: heroWidth, height: heroHeight),
                contentMode: .fill
            )
            .frame(width: heroWidth, height: heroHeight)
            .clipped()
            .transition(.opacity.animation(.easeInOut(duration: 0.35)))
        } else {
            Color.continuumSurface
        }
    }

    private func editorialContent(for item: SectionItem) -> some View {
        VStack(alignment: .center, spacing: 9) {
            heroTitle(for: item)

            Text(editorialQuote(for: item))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.94))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(.center)

            if !metadata(for: item).isEmpty {
                metadataRow(for: item)
            }

            HStack(spacing: 10) {
                Button {
                    onPlay(item)
                } label: {
                    Label(playLabel(for: item), systemImage: "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(
                            .white,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    onInfo(item)
                } label: {
                    Label("More Info", systemImage: "info.circle")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .siloGlass(
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous),
                            tint: Color.black.opacity(0.18),
                            interactive: true
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func heroTitle(for item: SectionItem) -> some View {
        if let logo = item.logoUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
           !logo.isEmpty {
            AsyncImageView(
                url: logo,
                contentMode: .fit,
                placeholderStyle: .clear
            )
            .frame(width: 220, height: 76, alignment: .center)
            .accessibilityLabel(item.title)
        } else {
            Text(item.title)
                .font(.system(size: 36, weight: .black, design: .rounded))
                .tracking(-1)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .multilineTextAlignment(.center)
        }
    }

    private func metadataRow(for item: SectionItem) -> some View {
        Text(metadata(for: item).joined(separator: "  ·  "))
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.72))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func preferredArtworkURL(for item: SectionItem) -> String? {
        if let textless = textlessPosterURLs[item.contentId], !textless.isEmpty {
            return textless
        }
        let poster = item.posterUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let poster, !poster.isEmpty { return poster }
        let backdrop = item.backdropUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        return backdrop?.isEmpty == false ? backdrop : nil
    }

    private func editorialQuote(for item: SectionItem) -> String {
        if let tagline = item.tagline?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tagline.isEmpty,
           let quote = shortQuote(tagline) {
            return quote
        }
        if let overview = item.overview?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overview.isEmpty {
            let punctuation = CharacterSet(charactersIn: ".!?")
            if let end = overview.rangeOfCharacter(from: punctuation)?.lowerBound,
               let quote = shortQuote(String(overview[...end])) {
                return quote
            }
            if let quote = shortQuote(overview) {
                return quote
            }
        }

        // Some libraries do not have a provider tagline or overview. Keep the
        // hero's editorial rhythm intact without inventing title-specific copy.
        return "Ready when you are."
    }

    /// A hero tagline must read as a compact pull quote. Prefer a complete
    /// clause; otherwise keep at most six whole words and never show a clipped
    /// ellipsis in this surface.
    private func shortQuote(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= 46 { return trimmed }

        if let clauseEnd = trimmed.firstIndex(where: { $0 == "," || $0 == ";" }) {
            let clause = String(trimmed[..<clauseEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let wordCount = clause.split(whereSeparator: { $0.isWhitespace }).count
            if clause.count >= 8, clause.count <= 46, wordCount >= 3 {
                return clause
            }
        }

        var words: [Substring] = []
        for word in trimmed.split(separator: " ").prefix(6) {
            let candidate = (words + [word]).joined(separator: " ")
            if candidate.count > 46 { break }
            words.append(word)
        }
        let compact = words.joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return compact.isEmpty ? nil : compact
    }

    private func metadata(for item: SectionItem) -> [String] {
        var result: [String] = []
        if let rating = item.ratingImdb ?? item.ratingTmdb, rating > 0 {
            result.append(String(format: "★ %.1f", rating))
        }
        result.append(contentsOf: (item.genres ?? []).filter { !$0.isEmpty }.prefix(2))
        if let runtime = item.runtime, runtime > 0 {
            result.append(formatRuntime(runtime))
        }
        if let rating = item.contentRating?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rating.isEmpty {
            result.append(rating.uppercased())
        }
        return result
    }

    private func formatRuntime(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes)m" }
        let remainder = minutes % 60
        return remainder == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(remainder)m"
    }

    private func playLabel(for item: SectionItem) -> String {
        guard let position = item.positionSeconds, position > 60 else { return "Play" }
        return "Resume"
    }
}
#endif
