#if os(tvOS)
import SwiftUI

/// Passive first frame for an item route whose authoritative `ItemDetail` has
/// not arrived yet. Card routes can brand the frame from their lightweight
/// route seed; ID-only deep links and cold trailer restores use the same fixed
/// geometry with quiet placeholders. Nothing here participates in focus — the
/// loaded detail view installs its own native focus graph and default owner.
struct TVItemDetailLoadingView: View {
    let seed: TVItemDetailRouteSeed?

    var body: some View {
        Group {
            if isAudiobook {
                audiobookLayout
            } else {
                cinematicLayout
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Movie / series / episode

    private var cinematicLayout: some View {
        TVDetailPageSurface(backdropURL: seed?.backdropUrl) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    cinematicArtwork
                    cinematicEditorial
                }
                .frame(height: TVDetailLayout.heroHeight)
                .frame(maxWidth: .infinity)
                .clipped()

                loadingRail
            }
        }
    }

    private var cinematicArtwork: some View {
        GeometryReader { geometry in
            let artworkWidth = geometry.size.width * 0.64
            let artworkHeight = min(
                TVDetailLayout.heroHeight * 0.94,
                artworkWidth * 9 / 16
            )

            Group {
                if let url = nonEmpty(seed?.backdropUrl) {
                    AsyncImageView(
                        url: url,
                        thumbhash: seed?.backdropThumbhash,
                        targetSize: CGSize(width: artworkWidth, height: artworkHeight),
                        contentMode: .fill
                    )
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.035))
                }
            }
            .frame(width: artworkWidth, height: artworkHeight)
            .clipped()
            .mask { cinematicArtworkMask }
            .frame(
                width: geometry.size.width,
                height: TVDetailLayout.heroHeight,
                alignment: .topTrailing
            )
        }
    }

    private var cinematicArtworkMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.46),
                .init(color: .clear, location: 1),
            ],
            startPoint: .trailing,
            endPoint: .leading
        )
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.70),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var cinematicEditorial: some View {
        VStack(alignment: .leading, spacing: 14) {
            loadingTitle
                .frame(width: 700, height: 132, alignment: .bottomLeading)

            loadingMetadata
                .frame(height: 36, alignment: .leading)

            loadingSynopsis
                .frame(width: 920, height: 104, alignment: .topLeading)
                .clipped()

            loadingPlaybackSummary
                .frame(width: 810, height: 44, alignment: .topLeading)

            loadingActions
                .padding(.top, 6)
        }
        .padding(.top, TVDetailLayout.heroTopInset)
        .padding(.horizontal, TVDetailLayout.horizontalInset)
        .frame(
            maxWidth: .infinity,
            maxHeight: TVDetailLayout.heroHeight,
            alignment: .topLeading
        )
    }

    @ViewBuilder
    private var loadingTitle: some View {
        if let title = nonEmpty(seed?.title) {
            TVDecodedLogoTitle(
                logoUrl: seed?.logoUrl,
                accessibilityLabel: title,
                maxWidth: 700,
                maxHeight: 132
            ) {
                Text(title)
                    .font(.system(size: 64, weight: .bold))
                    .tracking(-0.8)
                    .foregroundStyle(Color.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: 700, alignment: .leading)
            }
        } else {
            placeholder(width: 520, height: 64, cornerRadius: 10)
        }
    }

    @ViewBuilder
    private var loadingMetadata: some View {
        if !metadataTokens.isEmpty {
            Text(metadataTokens.joined(separator: "  ·  "))
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.76))
                .lineLimit(1)
        } else {
            placeholder(width: 390, height: 22, cornerRadius: 6)
        }
    }

    @ViewBuilder
    private var loadingSynopsis: some View {
        if let overview = nonEmpty(seed?.overview) {
            Text(overview)
                .font(.system(size: 26))
                .foregroundStyle(Color.white.opacity(0.72))
                .lineSpacing(5)
                .lineLimit(3)
                .frame(maxWidth: 920, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 13) {
                placeholder(width: 860, height: 18, cornerRadius: 5)
                placeholder(width: 790, height: 18, cornerRadius: 5)
                placeholder(width: 610, height: 18, cornerRadius: 5)
            }
            .padding(.top, 4)
        }
    }

    private var loadingPlaybackSummary: some View {
        HStack(alignment: .top, spacing: 8) {
            playbackPlaceholder(label: "VERSION", width: 245, barWidth: 100)
            playbackPlaceholder(label: "AUDIO", width: 285, barWidth: 130)
            playbackPlaceholder(label: "SUBTITLES", width: 264, barWidth: 60)
        }
    }

    private func playbackPlaceholder(
        label: String,
        width: CGFloat,
        barWidth: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 12, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(Color.white.opacity(0.42))
            placeholder(width: barWidth, height: 14, cornerRadius: 4)
        }
        .frame(width: width, alignment: .leading)
    }

    private var loadingActions: some View {
        HStack(spacing: 14) {
            placeholder(width: 340, height: 64, cornerRadius: 14)
            placeholder(width: 190, height: 64, cornerRadius: 14)
            placeholder(width: 64, height: 64, cornerRadius: 14)
        }
    }

    private var loadingRail: some View {
        VStack(alignment: .leading, spacing: TVDetailLayout.sectionHeaderSpacing) {
            placeholder(width: 220, height: 26, cornerRadius: 6)

            HStack(spacing: railSpacing) {
                ForEach(0..<railCardCount, id: \.self) { _ in
                    placeholder(
                        width: railCardSize.width,
                        height: railCardSize.height,
                        cornerRadius: ContinuumTheme.cornerRadius
                    )
                }
            }
        }
        .padding(.horizontal, TVDetailLayout.horizontalInset)
        .padding(.bottom, TVDetailLayout.pageBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    // MARK: - Audiobook

    private var audiobookLayout: some View {
        ZStack {
            audiobookBackground

            HStack(spacing: 84) {
                audiobookCover
                audiobookIdentity
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, ContinuumTheme.safePadding)
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }

    private var audiobookBackground: some View {
        ZStack {
            Color.black
            if let url = nonEmpty(seed?.posterUrl) {
                AsyncImageView(
                    url: url,
                    thumbhash: seed?.posterThumbhash,
                    targetSize: CGSize(width: 600, height: 600),
                    contentMode: .fill
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .blur(radius: 70)
                .opacity(0.28)
            }
            RadialGradient(
                colors: [
                    Color(red: 0.07, green: 0.25, blue: 0.235).opacity(0.9),
                    .clear,
                ],
                center: UnitPoint(x: 0.22, y: 0.4),
                startRadius: 0,
                endRadius: 1200
            )
            LinearGradient(
                colors: [
                    Color.black.opacity(0.35),
                    Color.black.opacity(0.72),
                    Color.black.opacity(0.96),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var audiobookCover: some View {
        Group {
            if let url = nonEmpty(seed?.posterUrl) {
                AsyncImageView(
                    url: url,
                    thumbhash: seed?.posterThumbhash,
                    targetSize: CGSize(width: 460, height: 460),
                    contentMode: .fill
                )
            } else {
                placeholder(
                    width: 460,
                    height: 460,
                    cornerRadius: ContinuumTheme.cornerRadius
                )
            }
        }
        .frame(width: 460, height: 460)
        .clipShape(
            RoundedRectangle(
                cornerRadius: ContinuumTheme.cornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: ContinuumTheme.cornerRadius,
                style: .continuous
            )
            .stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.65), radius: 40, x: 0, y: 24)
    }

    private var audiobookIdentity: some View {
        VStack(alignment: .leading, spacing: 0) {
            placeholder(width: 180, height: 18, cornerRadius: 5)

            Group {
                if let title = nonEmpty(seed?.title) {
                    Text(title)
                        .font(.system(size: 84, weight: .bold))
                        .tracking(-1)
                        .foregroundStyle(Color.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                } else {
                    placeholder(width: 680, height: 80, cornerRadius: 12)
                }
            }
            .frame(width: 820, height: 176, alignment: .topLeading)
            .padding(.top, 16)

            HStack(spacing: 12) {
                placeholder(width: 250, height: 22, cornerRadius: 6)
                if let year = seed?.year {
                    Text(String(year))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.64))
                }
            }

            HStack(spacing: 22) {
                Circle()
                    .stroke(Color.white.opacity(0.14), lineWidth: 8)
                    .frame(width: 88, height: 88)
                VStack(alignment: .leading, spacing: 8) {
                    placeholder(width: 280, height: 24, cornerRadius: 6)
                    placeholder(width: 190, height: 18, cornerRadius: 5)
                }
            }
            .padding(.top, 48)

            HStack(spacing: 14) {
                placeholder(width: 340, height: 64, cornerRadius: 14)
                placeholder(width: 200, height: 64, cornerRadius: 14)
                placeholder(width: 180, height: 64, cornerRadius: 14)
            }
            .padding(.top, 48)
        }
        .frame(maxWidth: 1040, alignment: .leading)
    }

    // MARK: - Derived presentation

    private var isAudiobook: Bool {
        seed.map { SiloMediaType.isAudiobook($0.mediaType) } ?? false
    }

    private var metadataTokens: [String] {
        guard let seed else { return [] }
        var values: [String] = []
        if let year = seed.year, year > 0 {
            values.append(String(year))
        }
        if let genre = nonEmpty(seed.genre) {
            values.append(genre)
        }
        if let runtime = seed.runtime, runtime > 0 {
            values.append(runtimeLabel(runtime))
        }
        if let rating = nonEmpty(seed.contentRating) {
            values.append(rating.uppercased())
        }
        return values
    }

    private var usesLandscapeRail: Bool {
        guard let mediaType = seed?.mediaType else { return false }
        let type = mediaType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return SiloMediaType.isSeries(type) || type == "season" || type == "episode"
    }

    private var railCardSize: CGSize {
        if usesLandscapeRail {
            return CGSize(width: 400, height: 225)
        }
        return CGSize(width: 220, height: 330)
    }

    private var railCardCount: Int { usesLandscapeRail ? 4 : 6 }
    private var railSpacing: CGFloat { usesLandscapeRail ? 34 : 44 }

    private var accessibilityLabel: String {
        if let title = nonEmpty(seed?.title) {
            return "Loading details for \(title)"
        }
        return "Loading details"
    }

    private func runtimeLabel(_ minutes: Int) -> String {
        if minutes >= 60 {
            let remainder = minutes % 60
            return remainder == 0
                ? "\(minutes / 60)h"
                : "\(minutes / 60)h \(remainder)m"
        }
        return "\(minutes) min"
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private func placeholder(
        width: CGFloat,
        height: CGFloat,
        cornerRadius: CGFloat
    ) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white.opacity(0.10))
            .frame(width: width, height: height)
    }
}
#endif
