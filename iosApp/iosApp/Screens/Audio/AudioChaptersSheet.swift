import SwiftUI

/// Chapter list presented from the full player. The current chapter is
/// tinted with the cover accent and the list opens scrolled to it.
struct AudioChaptersSheet: View {
    let player: AudioPlayerViewModel

    @Environment(\.dismiss) private var dismiss

    private var sortedChapters: [AudioPlaybackChapter] {
        player.chapters.sorted { $0.startSeconds < $1.startSeconds }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(sortedChapters) { chapter in
                    chapterRow(chapter)
                        .id(chapter.id)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                #if !os(tvOS)
                .scrollContentBackground(.hidden)
                .background(Color.siloSurface)
                #endif
                .onAppear {
                    if let current = player.currentChapter {
                        proxy.scrollTo(current.id, anchor: .center)
                    }
                }
            }
            .navigationTitle("Chapters")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .preferredColorScheme(.dark)
    }

    private func chapterRow(_ chapter: AudioPlaybackChapter) -> some View {
        let isCurrent = chapter.id == player.currentChapter?.id
        return Button {
            player.jumpToChapter(chapter)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                if isCurrent {
                    Image(systemName: "waveform")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(player.palette.accent)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                } else {
                    Text("\(chapterNumber(chapter))")
                        .font(.footnote.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                }

                Text(chapter.title ?? "Chapter \(chapter.index + 1)")
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? player.palette.accent : Color.siloOnSurface)
                    .lineLimit(1)

                Spacer()

                Text(PlayerTimeFormatter.formatHMS(chapter.startSeconds))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chapterNumber(_ chapter: AudioPlaybackChapter) -> Int {
        (sortedChapters.firstIndex(where: { $0.id == chapter.id }) ?? chapter.index) + 1
    }
}
