import SwiftUI

/// Chapter list presented from the full player. The current chapter is
/// tinted with the cover accent and the list opens scrolled to it.
struct AudioChaptersSheet: View {
    let player: AudioPlayerViewModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let currentID = player.currentChapter?.id
        NavigationStack {
            ScrollViewReader { proxy in
                // `chapters` is already sorted, so the offset is the chapter number.
                List(Array(player.chapters.enumerated()), id: \.element.id) { offset, chapter in
                    chapterRow(chapter, number: offset + 1, isCurrent: chapter.id == currentID)
                        .id(chapter.id)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                #if !os(tvOS)
                .scrollContentBackground(.hidden)
                .siloSheetBackground(legacyColor: .siloSurface)
                #endif
                .onAppear {
                    if let currentID {
                        proxy.scrollTo(currentID, anchor: .center)
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

    private func chapterRow(_ chapter: AudioPlaybackChapter, number: Int, isCurrent: Bool) -> some View {
        Button {
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
                    Text("\(number)")
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
}
