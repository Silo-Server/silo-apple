#if os(iOS)
import SwiftUI

/// Chapter picker for iPhone and iPad. A sheet rather than a native menu so it
/// opens scrolled to the chapter that is playing, which a long menu cannot do.
struct ChapterListSheet: View {
    let viewModel: PlayerViewModel
    let onDismiss: () -> Void

    var body: some View {
        let current = viewModel.chapters.lastIndex(where: { $0.time <= viewModel.currentTime })
        NavigationStack {
            ScrollViewReader { reader in
                List(viewModel.chapters) { chapter in
                    ChapterListRow(chapter: chapter, isCurrent: current == chapter.index) {
                        viewModel.seekTo(seconds: chapter.time)
                        onDismiss()
                    }
                    .id(chapter.index)
                }
                .listStyle(.insetGrouped)
                .contentMargins(.top, 8, for: .scrollContent)
                .onAppear {
                    // The chapter before the playing one at the top: the list
                    // opens on whole rows, with the playing one in view.
                    if let current { reader.scrollTo(max(current - 1, 0), anchor: .top) }
                }
            }
            .navigationTitle(Text(.optionsChapters))
            .navigationBarTitleDisplayMode(.inline)
            .playerSheetNavigationBar()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { onDismiss() } label: { Text(.commonDone) }
                }
            }
        }
    }
}

private struct ChapterListRow: View {
    let chapter: PlayerChapterInfo
    let isCurrent: Bool
    let action: () -> Void
    @Environment(\.locale) private var locale

    private var number: String { LocaleFormat.integer(chapter.index + 1, locale: locale) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(verbatim: number)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 22, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(chapter.title ?? AppLanguage.string(.optionsChapterNumbered(number), locale: locale))
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .lineLimit(2)
                    Text(PlayerTimeFormatter.formatHMS(chapter.time, locale: locale))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                // One mark for the chapter playing, so its title keeps the width.
                if isCurrent {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityValue(isCurrent ? Text(.playerChaptersA11YNowPlaying) : Text(verbatim: ""))
    }
}
#endif
