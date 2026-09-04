#if os(macOS)
import Foundation
import SwiftUI

struct MacPlayerOptionsPanel: View {
    enum Tab: String, CaseIterable, Identifiable {
        case audio = "Audio"
        case subtitles = "Subtitles"
        case chapters = "Chapters"
        case playback = "Playback"

        var id: String { rawValue }
    }

    let viewModel: PlayerViewModel
    @Binding var selectedTab: Tab
    let onDismiss: () -> Void

    private let playbackSpeeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Options", selection: $selectedTab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close options")
            }
            .padding(14)

            Divider().overlay(Color.white.opacity(0.12))

            content
                .frame(width: 420, height: 330)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 22, y: 12)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .audio:
            optionList {
                if viewModel.audioTracks.isEmpty {
                    unavailable("No alternate audio tracks", systemImage: "speaker.slash")
                } else {
                    ForEach(viewModel.audioTracks) { track in
                        trackButton(
                            title: track.primaryLabel,
                            detail: track.attributesLabel,
                            selected: viewModel.selectedAudioId == track.trackId
                        ) {
                            viewModel.selectAudio(track)
                        }
                    }
                }
            }
        case .subtitles:
            optionList {
                trackButton(
                    title: "Off",
                    detail: nil,
                    selected: viewModel.selectedSubtitleId == nil
                ) {
                    viewModel.disableSubtitles()
                }
                ForEach(viewModel.orderedSubtitleTracks) { track in
                    trackButton(
                        title: track.primaryLabel,
                        detail: subtitleDetail(for: track),
                        selected: viewModel.selectedSubtitleId == track.trackId
                    ) {
                        viewModel.selectSubtitle(track)
                    }
                }

                if viewModel.subtitleTracks.isEmpty {
                    Text("No subtitle tracks available on this route.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.58))
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                }
            }
        case .chapters:
            optionList {
                if viewModel.chapters.isEmpty {
                    unavailable("No chapters", systemImage: "bookmark.slash")
                } else {
                    ForEach(viewModel.chapters) { chapter in
                        trackButton(
                            title: chapter.title ?? "Chapter \(chapter.index + 1)",
                            detail: PlayerTimeFormatter.formatHMS(chapter.time),
                            selected: chapter.index == currentChapterIndex
                        ) {
                            viewModel.seekTo(seconds: chapter.time)
                        }
                    }
                }
            }
        case .playback:
            optionList {
                Text("Speed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.62))
                    .padding(.horizontal, 12)
                    .padding(.top, 2)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 8)], spacing: 8) {
                    ForEach(playbackSpeeds, id: \.self) { speed in
                        Button {
                            viewModel.setPlaybackSpeed(speed)
                        } label: {
                            Text(speedLabel(speed))
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(abs(viewModel.settings.playbackSpeed - speed) < 0.01 ? Color.white : Color.gray)
                    }
                }
                .padding(.horizontal, 12)

                routeStatus
                    .padding(.top, 8)

                // Same rows tvOS and iOS report, in the single-column
                // sectioned dressing — the panel is narrow, so the tvOS
                // two-column split would crush the value column.
                PlaybackStatsPanel(stats: viewModel.playbackStats)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }
        }
    }

    private func optionList<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(12)
        }
        .background(Color.black.opacity(0.72))
    }

    private func trackButton(
        title: String,
        detail: String?,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selected ? .white : .white.opacity(0.32))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.58))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.14) : Color.white.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
    }

    private func unavailable(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.42))
            Text(title)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.72))
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private var routeStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Route")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.62))
            ForEach(viewModel.routeStatusRows) { row in
                HStack {
                    Text(row.label)
                        .foregroundStyle(.white.opacity(0.58))
                    Spacer()
                    Text(row.value)
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(1)
                }
                .font(.caption)
            }
        }
        .padding(12)
    }

    private var currentChapterIndex: Int? {
        viewModel.chapters.lastIndex { $0.time <= viewModel.currentTime }
    }

    private func subtitleDetail(for track: PlayerTrack) -> String? {
        var parts: [String] = []
        if let attributes = track.attributesLabel, !attributes.isEmpty {
            parts.append(attributes)
        }
        parts.append(track.isExternal ? "External" : "Embedded")
        return parts.joined(separator: " · ")
    }

    private func speedLabel(_ speed: Double) -> String {
        if abs(speed - 1.0) < 0.01 { return "Normal" }
        return String(format: "%.2gx", speed)
    }
}
#endif
