#if os(tvOS)
import SwiftUI

/// Full-screen chapter picker presented over the Lounge screen — the deep
/// "jump to an arbitrary chapter" task on its own screen (a native tvOS
/// pattern) instead of dozens of always-present focus targets on the main
/// page. Source of truth: the shared `.pk` frame in
/// `docs/audiobook-detail-redesign/tvos-mockups-v2.html`.
///
/// Focus: the list is a native graph of row `Button`s inside a
/// `focusSection`. On appear a `ScrollViewReader` scrolls to the current
/// chapter and `defaultFocus` lands focus there — the "landing inside an
/// already-entered scope" case from the tvOS focus playbook.
struct TVAudiobookChaptersView: View {
    let detail: ItemDetail
    let libraryId: Int?

    @Environment(AudioPlaybackStore.self) private var audioStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedRow: String?

    private let model: TVAudiobookViewModel
    /// Real chapters when present, else the parts list. Built once here
    /// because `body` re-runs on every focus move.
    private let rows: [Row]
    private let defaultRowId: String?

    init(detail: ItemDetail, libraryId: Int? = nil) {
        self.detail = detail
        self.libraryId = libraryId
        let model = TVAudiobookViewModel(detail: detail)
        let rows = Self.makeRows(model)
        self.model = model
        self.rows = rows
        self.defaultRowId = rows.first(where: \.isCurrent)?.id ?? rows.first?.id
    }

    private static func makeRows(_ model: TVAudiobookViewModel) -> [Row] {
        let chapters = model.chapters
        guard !chapters.isEmpty else {
            return model.tracks.map { track in
                Row(
                    id: "part-\(track.index)",
                    number: track.index + 1,
                    title: partTitle(track),
                    duration: track.durationSeconds,
                    startSeconds: track.startOffsetSeconds,
                    isCurrent: false,
                    isDone: false,
                    progress: nil
                )
            }
        }
        let totalDuration = model.totalDuration
        let position = model.position
        let isFinished = model.isFinished
        let currentIndex = model.currentChapterIndex
        return chapters.enumerated().map { index, chapter in
            let duration = AudiobookProgress.chapterDuration(
                chapters: chapters, at: index, totalDuration: totalDuration
            )
            let isCurrent = currentIndex == index
            return Row(
                id: chapter.id,
                number: index + 1,
                title: model.chapterTitle(index),
                duration: duration,
                startSeconds: chapter.startSeconds,
                isCurrent: isCurrent,
                isDone: isFinished
                    || AudiobookProgress.isChapterFinished(
                        chapters: chapters, at: index,
                        position: position, totalDuration: totalDuration
                    ),
                // Fraction listened within the current chapter.
                progress: isCurrent && duration > 0
                    ? min(1, max(0, position - chapter.startSeconds) / duration)
                    : nil
            )
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.031, green: 0.071, blue: 0.063), .black],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        list
                    }
                    .padding(.horizontal, SiloTheme.safePadding)
                    .padding(.top, 80)
                    .padding(.bottom, 80)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear {
                    if let defaultRowId {
                        proxy.scrollTo(defaultRowId, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 42) {
            cover
            VStack(alignment: .leading, spacing: 8) {
                Text("Chapters")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundColor(.white)
                Text(subline)
                    .font(.system(size: 23))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var cover: some View {
        Group {
            if let url = detail.posterUrl, !url.isEmpty {
                AsyncImageView(
                    url: url,
                    thumbhash: detail.posterThumbhash,
                    targetSize: CGSize(width: 146, height: 146),
                    contentMode: .fill
                )
            } else {
                RoundedRectangle(cornerRadius: SiloTheme.cornerRadius, style: .continuous)
                    .fill(Color.siloSurfaceElevated)
                    .overlay {
                        Image(systemName: "book.closed").foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 146, height: 146)
        .clipShape(RoundedRectangle(cornerRadius: SiloTheme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SiloTheme.cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
    }

    /// "62% · Chapter 24 of 38 · 5h 28m left" (in progress) or
    /// "38 chapters · 14h 22m" (not started); pieces omitted when N/A.
    private var subline: String {
        let model = self.model
        var pieces: [String] = []
        let hasChapters = !model.chapters.isEmpty
        if model.resumePosition != nil {
            pieces.append("\(model.percentComplete)%")
            if let index = model.currentChapterIndex, hasChapters {
                pieces.append("Chapter \(index + 1) of \(model.chapters.count)")
            }
            let left = PlayerTimeFormatter.formatRuntime(max(0, model.totalDuration - model.position))
            if !left.isEmpty { pieces.append("\(left) left") }
        } else {
            if hasChapters {
                pieces.append("\(model.chapters.count) chapters")
            } else if model.tracks.count > 1 {
                pieces.append("\(model.tracks.count) parts")
            }
            if !model.runtimeLabel.isEmpty { pieces.append(model.runtimeLabel) }
        }
        return pieces.joined(separator: " · ")
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 10) {
            ForEach(rows) { row in
                rowButton(row)
                    .id(row.id)
                    .focused($focusedRow, equals: row.id)
            }
        }
        .frame(maxWidth: 1380, alignment: .leading)
        .focusSection()
        .defaultFocus($focusedRow, defaultRowId, priority: .userInitiated)
    }

    private func rowButton(_ row: Row) -> some View {
        Button {
            audioStore.play(contentId: detail.contentId, restart: false, startPosition: row.startSeconds, libraryId: libraryId)
            dismiss()
        } label: {
            TVAudiobookRowLabel(row: row)
        }
        .buttonStyle(TVAudiobookRowStyle(isCurrent: row.isCurrent, progress: row.progress))
    }

    // MARK: - Data helpers

    private static func partTitle(_ track: AudioPlaybackTrack) -> String {
        if let fileName = track.fileName, !fileName.isEmpty { return fileName }
        return "Part \(track.index + 1)"
    }

    struct Row: Identifiable {
        let id: String
        let number: Int
        let title: String
        let duration: Double
        let startSeconds: Double
        let isCurrent: Bool
        let isDone: Bool
        /// Fraction listened within the current chapter (0...1), else nil.
        let progress: Double?
    }
}

// MARK: - Row label

/// Content of one picker row; recolors its text for the style's focused fill.
private struct TVAudiobookRowLabel: View {
    let row: TVAudiobookChaptersView.Row

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 20) {
            Text("\(row.number)")
                .font(.system(size: 22, weight: .bold))
                .monospacedDigit()
                .foregroundColor(numberColor)
                .frame(width: 46, alignment: .leading)

            Text(row.title)
                .font(.system(size: 27, weight: .semibold))
                .foregroundColor(titleColor)
                .lineLimit(1)

            if row.isDone && !isFocused {
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
            }

            if row.isCurrent {
                Text("NOW")
                    .font(.system(size: 15, weight: .bold))
                    .tracking(1)
                    .foregroundColor(isFocused ? .white : .black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isFocused ? Color.black : Color.white)
                    )
            }

            Spacer(minLength: 24)

            Text(PlayerTimeFormatter.formatRuntime(row.duration))
                .font(.system(size: 22))
                .monospacedDigit()
                .foregroundColor(durationColor)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 22)
        .contentShape(Rectangle())
    }

    private var titleColor: Color {
        if isFocused { return .black }
        return row.isDone ? .white.opacity(0.72) : .white
    }

    private var numberColor: Color {
        isFocused ? .black.opacity(0.5) : .white.opacity(0.38)
    }

    private var durationColor: Color {
        isFocused ? .black.opacity(0.5) : .white.opacity(0.55)
    }
}

// MARK: - Row style

/// List-row focus grammar for the chapter picker and narration rows: white
/// fill and dark text on focus, faint resting fill; the current row keeps a
/// raised fill and a progress underline.
struct TVAudiobookRowStyle: ButtonStyle {
    var isCurrent: Bool = false
    var progress: Double? = nil

    func makeBody(configuration: Configuration) -> some View {
        TVAudiobookRowBody(configuration: configuration, isCurrent: isCurrent, progress: progress)
    }
}

private struct TVAudiobookRowBody: View {
    let configuration: ButtonStyleConfiguration
    let isCurrent: Bool
    let progress: Double?

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay {
                if isCurrent && !isFocused {
                    RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                }
            }
            .overlay(alignment: .bottomLeading) { progressUnderline }
            .clipShape(RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius, style: .continuous))
            .shadow(
                color: isFocused ? .black.opacity(0.4) : .clear,
                radius: isFocused ? 18 : 0,
                y: isFocused ? 8 : 0
            )
            .scaleEffect(isFocused ? 1.015 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isFocused)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }

    @ViewBuilder
    private var progressUnderline: some View {
        if isCurrent, !isFocused, let progress, progress > 0 {
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.white)
                    .frame(width: geo.size.width * CGFloat(min(1, max(0, progress))), height: 5)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .allowsHitTesting(false)
        }
    }

    private var fill: Color {
        if isFocused { return .white }
        return isCurrent ? Color.white.opacity(0.10) : Color.white.opacity(0.06)
    }
}
#endif
