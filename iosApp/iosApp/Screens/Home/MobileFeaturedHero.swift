#if os(iOS)
import SwiftUI

/// Server-driven Home spotlight for iPhone and iPad. The featured section is
/// rendered once here and removed from the rows below.
struct MobileFeaturedHero: View {
    let items: [SectionItem]
    let onPlay: (SectionItem) -> Void
    let onInfo: (SectionItem) -> Void

    @State private var currentIndex = 0

    private var heroHeight: CGFloat {
        min(max(PlatformScreen.mainBounds.height * 0.69, 610), 740)
    }

    var body: some View {
        ZStack {
            TabView(selection: $currentIndex) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    spotlight(item)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            if items.count > 1 {
                carouselControls
            }
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .background(Color.continuumBackground)
        .clipped()
        .task(id: items.map(\.contentId)) {
            guard items.count > 1 else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.55)) {
                    currentIndex = (currentIndex + 1) % items.count
                }
            }
        }
        .onChange(of: items.map(\.contentId)) { _, _ in
            currentIndex = min(currentIndex, max(items.count - 1, 0))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Featured")
    }

    private func spotlight(_ item: SectionItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            artwork(for: item)

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.28), location: 0),
                    .init(color: .clear, location: 0.22),
                    .init(color: .black.opacity(0.32), location: 0.50),
                    .init(color: Color.continuumBackground.opacity(0.86), location: 0.78),
                    .init(color: Color.continuumBackground, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.68), location: 0),
                    .init(color: .black.opacity(0.20), location: 0.55),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .opacity(0.72)

            editorialContent(for: item)
                .padding(.horizontal, 20)
                .padding(.bottom, 34)
        }
        .contentShape(Rectangle())
        .onTapGesture { onInfo(item) }
    }

    @ViewBuilder
    private func artwork(for item: SectionItem) -> some View {
        if let url = preferredArtworkURL(for: item) {
            ZStack(alignment: .top) {
                // Blurred cover artwork carries color through the tall stage.
                AsyncImageView(
                    url: url,
                    thumbhash: item.backdropThumbhash ?? item.posterThumbhash,
                    targetSize: CGSize(width: PlatformScreen.mainBounds.width, height: heroHeight),
                    contentMode: .fill
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(1.08)
                .blur(radius: 24)

                // The crisp artwork occupies only the upper portion, reducing
                // the crop on 16:9 backdrops so the subject remains visible.
                AsyncImageView(
                    url: url,
                    thumbhash: item.backdropThumbhash ?? item.posterThumbhash,
                    targetSize: CGSize(
                        width: PlatformScreen.mainBounds.width,
                        height: heroHeight * 0.74
                    ),
                    contentMode: .fill
                )
                .frame(maxWidth: .infinity)
                .frame(height: heroHeight * 0.74, alignment: .top)
                .clipped()
            }
            .backgroundExtensionEffect()
            .transition(.opacity.animation(.easeInOut(duration: 0.45)))
        } else {
            Color.continuumSurface
        }
    }

    private func editorialContent(for item: SectionItem) -> some View {
        VStack(alignment: .center, spacing: 13) {
            heroTitle(for: item)

            if !metadata(for: item).isEmpty {
                metadataRow(for: item)
            }

            if let overview = item.overview?.trimmingCharacters(in: .whitespacesAndNewlines),
               !overview.isEmpty {
                Text(overview)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .lineSpacing(3)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button {
                    onPlay(item)
                } label: {
                    Label(playLabel(for: item), systemImage: "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 22)
                        .frame(height: 48)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    onInfo(item)
                } label: {
                    Label("More Info", systemImage: "info.circle")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .frame(height: 48)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 3)
        }
        .frame(maxWidth: 620, alignment: .center)
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
            .frame(width: 270, height: 92, alignment: .center)
            .accessibilityLabel(item.title)
        } else {
            Text(item.title)
                .font(.system(size: 44, weight: .black, design: .rounded))
                .tracking(-1.2)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .multilineTextAlignment(.center)
        }
    }

    private func metadataRow(for item: SectionItem) -> some View {
        Text(metadata(for: item).joined(separator: "  ·  "))
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.88))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var carouselControls: some View {
        HStack {
            carouselArrow(systemName: "chevron.left") {
                move(by: -1)
            }
            Spacer()
            carouselArrow(systemName: "chevron.right") {
                move(by: 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 258)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func carouselArrow(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.34), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func move(by delta: Int) {
        guard !items.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.38)) {
            currentIndex = (currentIndex + delta + items.count) % items.count
        }
    }

    private func preferredArtworkURL(for item: SectionItem) -> String? {
        let backdrop = item.backdropUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let backdrop, !backdrop.isEmpty { return backdrop }
        let poster = item.posterUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        return poster?.isEmpty == false ? poster : nil
    }

    private func metadata(for item: SectionItem) -> [String] {
        var result: [String] = []
        if item.type.lowercased() == "episode" {
            if let season = item.seasonNumber, let episode = item.episodeNumber {
                result.append("S\(season) E\(episode)")
            }
        } else if let year = item.year, year > 0 {
            result.append(String(year))
        }
        if let runtime = item.runtime, runtime > 0 {
            result.append(formatRuntime(runtime))
        }
        result.append(contentsOf: (item.genres ?? []).filter { !$0.isEmpty }.prefix(2))
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
