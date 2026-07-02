import SwiftUI

/// Chapter picker. On tvOS renders as a focus-navigable grid of 16:9 cards
/// with a thumbnail slot that's ready for on-demand server thumbnails when
/// the client starts subscribing to the `chapter_thumbnail_ready` realtime
/// protocol; until then, each card shows a gradient placeholder plus the
/// chapter number and title. On iOS this stays a plain list.
struct ChapterSheet: View {
    let viewModel: PlayerViewModel
    var onSelect: (() -> Void)? = nil

    private var currentChapterIndex: Int? {
        viewModel.chapters.lastIndex(where: { $0.time <= viewModel.currentTime })
    }

    var body: some View {
        chapterContent
            // The list/empty-state force white text. The iOS-26 glass restyle
            // dropped the explicit dark backing, leaving legibility dependent on
            // the sheet inheriting dark mode. Pin the sheet to dark so the
            // system material renders dark (white text stays readable) without
            // re-adding an opaque background that would defeat the glass look.
            .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var chapterContent: some View {
        let chapters = viewModel.chapters
        if chapters.isEmpty {
            ContentUnavailableView("No chapters", systemImage: "bookmark.slash")
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                #if os(tvOS)
                .background(Color.black.opacity(0.85).ignoresSafeArea())
                #endif
        } else {
            #if os(tvOS)
            tvOSGrid(chapters)
            #else
            iosList(chapters)
            #endif
        }
    }

    #if os(tvOS)
    private func tvOSGrid(_ chapters: [PlayerChapterInfo]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 360, maximum: 420), spacing: 24)],
                spacing: 24
            ) {
                ForEach(chapters) { chapter in
                    ChapterCard(
                        chapter: chapter,
                        isCurrent: currentChapterIndex == chapter.index
                    ) {
                        viewModel.seekTo(seconds: chapter.time)
                        onSelect?()
                    }
                }
            }
            .padding(48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92).ignoresSafeArea())
    }
    #endif

    private func iosList(_ chapters: [PlayerChapterInfo]) -> some View {
        NavigationStack {
            List {
                ForEach(chapters) { chapter in
                    Button {
                        viewModel.seekTo(seconds: chapter.time)
                        onSelect?()
                    } label: {
                        HStack {
                            Text("\(chapter.index + 1).")
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(width: 30, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chapter.title ?? "Chapter \(chapter.index + 1)")
                                    .foregroundStyle(.white)
                                Text(PlayerTimeFormatter.formatHMS(chapter.time))
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.6))
                                    .monospacedDigit()
                            }
                            Spacer()
                            if currentChapterIndex == chapter.index {
                                Image(systemName: "play.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Chapters")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onSelect?() }
                }
            }
        }
    }
}

#if os(tvOS)
/// Single chapter card. The thumbnail slot shows a gradient placeholder
/// today; when chapter thumbnail URLs become available on `WatchDetail`
/// (and the realtime `chapter_thumbnail_ready` subscription lands) it can
/// drop in a `CachedAsyncImage` without touching the surrounding layout.
private struct ChapterCard: View {
    let chapter: PlayerChapterInfo
    let isCurrent: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                thumbnail
                info
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isFocused
                          ? Color.white.opacity(0.14)
                          : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        isCurrent ? Color.white.opacity(0.8) : Color.white.opacity(0.10),
                        lineWidth: isCurrent ? 2 : 1
                    )
            )
            .scaleEffect(isFocused ? 1.04 : 1.0)
            .shadow(color: .black.opacity(isFocused ? 0.4 : 0),
                    radius: isFocused ? 16 : 0, y: isFocused ? 8 : 0)
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
    }

    private var thumbnail: some View {
        ZStack {
            // Placeholder background — tight gradient in the same mono
            // palette as the rest of the app. When `ChapterInfo` gains a
            // `thumbnailURL`, swap this for `CachedAsyncImage(url:)` with
            // this gradient as the failure fallback.
            LinearGradient(
                colors: [Color.white.opacity(0.08), Color.white.opacity(0.02)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if isCurrent {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(.white.opacity(0.9), .black.opacity(0.5))
            } else {
                Image(systemName: "film")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .aspectRatio(ContinuumTheme.thumbnailAspectRatio, contentMode: .fill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var info: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(chapter.title ?? "Chapter \(chapter.index + 1)")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(PlayerTimeFormatter.formatHMS(chapter.time))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .monospacedDigit()
            }
            Spacer()
            Text(String(format: "%02d", chapter.index + 1))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .monospacedDigit()
        }
    }
}
#endif

