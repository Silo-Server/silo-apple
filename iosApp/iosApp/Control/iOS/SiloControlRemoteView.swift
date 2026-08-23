#if os(iOS)
import Foundation
import SwiftUI

/// Native "now-playing" remote for controlling Silo playback on an Apple TV.
/// Thin wrapper: observes the control session and drives the presentational
/// `RemoteNowPlayingContent` with plain state + a command callback.
struct SiloControlRemoteView: View {
    @Bindable var controller: SiloControlClient
    @Environment(\.dismiss) private var dismiss
    @State private var artwork = SiloControlArtworkResolver()
    @State private var isShowingPicker = false

    var body: some View {
        NavigationStack {
            ZStack {
                SiloControlArtworkBackground(urlString: artwork.backdropURL ?? artwork.posterURL)
                content
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        controller.hideRemoteControl()
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .accessibilityLabel("Minimize")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            isShowingPicker = true
                        } label: {
                            Label("Choose a Different TV", systemImage: "tv")
                        }
                        Button {
                            controller.send(.stop)
                        } label: {
                            Label("Stop Playback", systemImage: "stop.fill")
                        }
                        Divider()
                        Button(role: .destructive) {
                            controller.disconnect()
                            dismiss()
                        } label: {
                            Label("Disconnect", systemImage: "tv.slash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .accessibilityLabel("More options")
                }
            }
            .sheet(isPresented: $isShowingPicker) {
                SiloControlTargetPickerView(request: nil, controller: controller)
            }
        }
        .preferredColorScheme(.dark)
        .task(id: controller.state?.contentId) {
            await artwork.resolve(contentId: controller.state?.contentId)
        }
    }

    @ViewBuilder
    private var content: some View {
        if controller.isReconnecting {
            statusView(title: "Reconnecting…", showSpinner: true)
        } else if let state = controller.state, state.contentId == nil {
            idleConnectedView(state: state)
        } else if let state = controller.state {
            RemoteNowPlayingContent(
                state: state,
                clock: controller.clock,
                targetName: controller.activeTarget?.name,
                posterURL: artwork.posterURL ?? artwork.backdropURL,
                onCommand: { controller.send($0) },
                onTogglePlayPause: { controller.togglePlayPauseOptimistic() },
                onSeek: { controller.seekOptimistic(to: $0) },
                onPlayNext: { controller.playNext() },
                onSetVolume: { controller.setVolume($0) },
                onSetMuted: { controller.setMuted($0) }
            )
        } else {
            connectingView
        }
    }

    private func idleConnectedView(state: SiloControlPlaybackState) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "appletvremote.gen4")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Color.continuumOnSurface)
            Text("Connected to \(controller.activeTarget?.name ?? "Silo TV")")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.continuumOnSurface)
            Text("Pick something from your library to start playing.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.continuumSecondaryText)
        }
        .padding(32)
    }

    private func statusView(title: String, showSpinner: Bool) -> some View {
        VStack(spacing: 14) {
            if showSpinner { ProgressView() }
            Text(title).font(.headline).foregroundStyle(Color.continuumSecondaryText)
        }
        .padding(32)
    }

    private var connectingView: some View {
        VStack(spacing: 18) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.continuumSurfaceElevated)
                .frame(width: 150, height: 216)
            if let error = controller.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(Color.continuumOnSurface)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.continuumError.opacity(0.9)))
                Button {
                    isShowingPicker = true
                } label: {
                    Label("Choose a TV", systemImage: "tv")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(Color.continuumOnSurface)
            } else {
                ProgressView()
                Text("Connecting to \(controller.activeTarget?.name ?? "Silo TV")…")
                    .font(.headline)
                    .foregroundStyle(Color.continuumSecondaryText)
            }
        }
        .padding(24)
    }
}

/// Pure presentational now-playing layout — no controller dependency, so it
/// previews with mock `SiloControlPlaybackState`.
private struct RemoteNowPlayingContent: View {
    let state: SiloControlPlaybackState
    let clock: RemotePlaybackClock
    let targetName: String?
    let posterURL: String?
    let onCommand: (SiloControlCommand) -> Void
    let onTogglePlayPause: () -> Void
    let onSeek: (Double) -> Void
    let onPlayNext: () -> Void
    let onSetVolume: (Double) -> Void
    let onSetMuted: (Bool) -> Void

    @State private var scrubPreview: Double?
    private let speedOptions: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]
    private let subtitleDelayOptions = [-2_000, -1_500, -1_000, -500, -250, 0, 250, 500, 1_000, 1_500, 2_000]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            artwork
            Spacer(minLength: 16)
            titleBlock
            playingOnPill.padding(.top, 10)
            scrubber.padding(.top, 22)
            transport.padding(.top, 18)
            volumeRow.padding(.top, 18)
            Spacer(minLength: 16)
            secondaryControls
            if let error = state.error, !error.isEmpty {
                errorBanner(error).padding(.top, 12)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private var artwork: some View {
        Group {
            if let posterURL, !posterURL.isEmpty {
                AsyncImageView(url: posterURL, contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.continuumSurfaceElevated)
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay {
                        Image(systemName: "tv")
                            .font(.system(size: 36))
                            .foregroundStyle(Color.continuumSecondaryText)
                    }
            }
        }
        .frame(maxHeight: 300)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
    }

    private var titleBlock: some View {
        VStack(spacing: 4) {
            Text(state.title.isEmpty ? "Loading" : state.title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .foregroundStyle(Color.continuumOnSurface)
            if let subtitle = state.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .foregroundStyle(Color.continuumSecondaryText)
            }
        }
    }

    @ViewBuilder
    private var playingOnPill: some View {
        if let targetName, !targetName.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "appletvremote.gen4")
                    .font(.system(size: 12, weight: .semibold))
                Text("Playing on \(targetName)")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(Color.continuumSecondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.continuumChromeRestingFill))
        }
    }

    private var scrubber: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let live = scrubPreview ?? clock.displayTime(asOf: ctx.date)
            VStack(spacing: 8) {
                Slider(
                    value: Binding(get: { live }, set: { scrubPreview = $0 }),
                    in: 0...max(state.duration, 1),
                    onEditingChanged: { editing in
                        guard !editing, let scrubPreview else { return }
                        onSeek(scrubPreview)
                        self.scrubPreview = nil
                    }
                )
                .tint(Color.continuumOnSurface)
                .disabled(state.duration <= 0)
                .accessibilityLabel("Playback position")
                .accessibilityValue(PlayerTimeFormatter.formatHMS(live))

                HStack {
                    Text(PlayerTimeFormatter.formatHMS(live))
                    Spacer()
                    Text(remainingLabel(live: live))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.continuumSecondaryText)
            }
        }
    }

    private func remainingLabel(live: Double) -> String {
        guard state.duration > 0 else { return PlayerTimeFormatter.formatHMS(state.duration) }
        return "-" + PlayerTimeFormatter.formatHMS(max(0, state.duration - live))
    }

    private var transport: some View {
        HStack(spacing: 28) {
            Button {
                onSeek(max(0, clock.displayTime() - 10))
            } label: {
                Image(systemName: "gobackward.10").font(.system(size: 30, weight: .regular))
            }
            .accessibilityLabel("Back 10 seconds")

            Button {
                onTogglePlayPause()
            } label: {
                ZStack {
                    Circle().fill(Color.continuumOnSurface).frame(width: 64, height: 64)
                    if state.isLoading || state.isBuffering {
                        ProgressView().tint(Color.continuumBackground)
                    } else {
                        Image(systemName: clock.isPlaying() ? "pause.fill" : "play.fill")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(Color.continuumBackground)
                    }
                }
            }
            .accessibilityLabel(clock.isPlaying() ? "Pause" : "Play")

            Button {
                let base = clock.displayTime()
                let target = state.duration > 0 ? min(state.duration, base + 30) : base + 30
                onSeek(target)
            } label: {
                Image(systemName: "goforward.30").font(.system(size: 30, weight: .regular))
            }
            .accessibilityLabel("Forward 30 seconds")

            if state.hasNextEpisode {
                Button { onPlayNext() } label: {
                    Image(systemName: "forward.end.fill").font(.system(size: 24, weight: .regular))
                }
                .accessibilityLabel(state.nextEpisodeTitle.map { "Next: \($0)" } ?? "Next episode")
            }
        }
        .foregroundStyle(Color.continuumOnSurface)
        .buttonStyle(.plain)
    }

    private var volumeRow: some View {
        HStack(spacing: 14) {
            Button { onSetMuted(!state.isMuted) } label: {
                Image(systemName: state.isMuted || state.volume <= 0.001
                      ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 28)
            }
            .accessibilityLabel(state.isMuted ? "Unmute" : "Mute")

            Slider(
                value: Binding(
                    get: { state.isMuted ? 0 : state.volume },
                    set: { onSetVolume($0) }
                ),
                in: 0...1
            )
            .tint(Color.continuumOnSurface)
            .accessibilityLabel("Volume")
            .accessibilityValue("\(Int((state.isMuted ? 0 : state.volume) * 100)) percent")
        }
        .foregroundStyle(Color.continuumOnSurface)
        .buttonStyle(.plain)
    }

    private var secondaryControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                if !state.audioTracks.isEmpty { audioMenu.frame(minWidth: 76) }
                if hasSubtitleControls { subtitleMenu.frame(minWidth: 76) }
                if !state.qualityOptions.isEmpty { qualityMenu.frame(minWidth: 76) }
                speedMenu.frame(minWidth: 76)
                if state.supportsVideoGravity { displayMenu.frame(minWidth: 76) }
            }
            .padding(.horizontal, 2)
        }
    }

    private var hasSubtitleControls: Bool {
        !state.subtitleTracks.isEmpty
            || state.supportsSubtitleDelay == true
            || state.supportsSubtitlePosition == true
    }

    private var audioMenu: some View {
        Menu {
            ForEach(state.audioTracks) { track in
                Button { onCommand(.selectAudioTrack(track.trackId)) } label: {
                    Label(track.title, systemImage: state.selectedAudioTrackId == track.trackId ? "checkmark" : "waveform")
                }
            }
        } label: { RemoteChipLabel(systemImage: "waveform", caption: "Audio") }
        .accessibilityValue(state.audioTracks.first(where: { $0.trackId == state.selectedAudioTrackId })?.title ?? "None")
    }

    private var subtitleMenu: some View {
        Menu {
            if !state.subtitleTracks.isEmpty {
                Section("Track") {
                    Button { onCommand(.selectSubtitleTrack(nil)) } label: {
                        Label("Off", systemImage: state.selectedSubtitleTrackId == nil ? "checkmark" : "captions.bubble")
                    }
                    ForEach(state.subtitleTracks) { track in
                        Button { onCommand(.selectSubtitleTrack(track.trackId)) } label: {
                            Label(track.title, systemImage: state.selectedSubtitleTrackId == track.trackId ? "checkmark" : "captions.bubble")
                        }
                    }
                }
            }

            if state.supportsSubtitleDelay == true {
                Section("Delay") {
                    ForEach(subtitleDelayMenuOptions, id: \.self) { milliseconds in
                        Button { onCommand(.setSubtitleSyncMs(milliseconds)) } label: {
                            Label(
                                subtitleDelayLabel(milliseconds),
                                systemImage: subtitleDelaySelectionSystemImage(milliseconds)
                            )
                        }
                    }
                }
            }

            if state.supportsSubtitlePosition == true {
                Section("Position") {
                    ForEach(SubtitlePositionPreset.allCases) { position in
                        Button { onCommand(.setSubtitlePosition(position.rawValue)) } label: {
                            Label(
                                position.label,
                                systemImage: state.subtitlePosition == position.rawValue ? "checkmark" : "textformat"
                            )
                        }
                    }
                }
            }
        } label: { RemoteChipLabel(systemImage: "captions.bubble", caption: "Subtitles") }
        .accessibilityValue(subtitleAccessibilityValue)
    }

    private var subtitleDelayMenuOptions: [Int] {
        let current = state.subtitleSyncMs ?? 0
        if subtitleDelayOptions.contains(current) {
            return subtitleDelayOptions
        }
        return (subtitleDelayOptions + [current]).sorted()
    }

    private var subtitleAccessibilityValue: String {
        var values: [String] = [
            state.subtitleTracks.first(where: { $0.trackId == state.selectedSubtitleTrackId })?.title ?? "Off"
        ]
        if state.supportsSubtitleDelay == true {
            values.append("Delay \(subtitleDelayLabel(state.subtitleSyncMs ?? 0))")
        }
        if state.supportsSubtitlePosition == true {
            values.append(SubtitlePositionPreset(rawValue: state.subtitlePosition ?? "")?.label ?? "Bottom")
        }
        return values.joined(separator: ", ")
    }

    private func subtitleDelaySelectionSystemImage(_ milliseconds: Int) -> String {
        abs((state.subtitleSyncMs ?? 0) - milliseconds) < 1 ? "checkmark" : "timer"
    }

    private var qualityMenu: some View {
        Menu {
            ForEach(state.qualityOptions) { option in
                Button { onCommand(.setQuality(option.id)) } label: {
                    Label(option.label, systemImage: state.activeQualityId == option.id ? "checkmark" : "slider.horizontal.3")
                }
            }
        } label: { RemoteChipLabel(systemImage: "slider.horizontal.3", caption: "Quality") }
        .accessibilityValue(state.qualityOptions.first(where: { $0.id == state.activeQualityId })?.label ?? state.activeQualityId)
        .disabled(state.isQualitySwitching)
    }

    private var speedMenu: some View {
        Menu {
            ForEach(speedOptions, id: \.self) { speed in
                Button { onCommand(.setPlaybackSpeed(speed)) } label: {
                    Label(speedLabel(speed), systemImage: abs(state.playbackSpeed - speed) < 0.01 ? "checkmark" : "speedometer")
                }
            }
        } label: { RemoteChipLabel(systemImage: "speedometer", caption: "Speed") }
        .accessibilityValue(speedLabel(state.playbackSpeed))
    }

    private var displayMenu: some View {
        Menu {
            if state.supportsVideoGravity {
                ForEach(VideoGravity.allCases, id: \.rawValue) { gravity in
                    Button { onCommand(.setVideoGravity(gravity.rawValue)) } label: {
                        Label(gravity.label, systemImage: state.videoGravity == gravity.rawValue ? "checkmark" : "rectangle.inset.filled")
                    }
                }
            }
        } label: { RemoteChipLabel(systemImage: "rectangle.inset.filled", caption: "Aspect") }
        .accessibilityValue(VideoGravity(rawValue: state.videoGravity)?.label ?? state.videoGravity)
    }

    private func speedLabel(_ speed: Double) -> String {
        switch speed {
        case 1.0: return "1.0×"
        case 0.75: return "0.75×"
        case 1.25: return "1.25×"
        case 1.5: return "1.5×"
        case 2.0: return "2.0×"
        default: return "\(speed)×"
        }
    }

    private func subtitleDelayLabel(_ milliseconds: Int) -> String {
        guard milliseconds != 0 else { return "0.0s" }
        let seconds = Double(milliseconds) / 1000.0
        return String(format: "%+.1fs", seconds)
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(Color.continuumOnSurface)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.continuumError.opacity(0.9)))
    }
}

private struct RemoteChipLabel: View {
    let systemImage: String
    let caption: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .regular))
            Text(caption)
                .font(.caption2)
        }
        .foregroundStyle(Color.continuumOnSurface.opacity(0.9))
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

#if DEBUG
private extension SiloControlPlaybackState {
    static func previewPlaying() -> SiloControlPlaybackState {
        SiloControlPlaybackState(
            contentId: "preview", sessionId: "s1", title: "The Bear",
            subtitle: "Season 3 · Episode 4 · Children",
            isPlaying: true, isLoading: false, isBuffering: false,
            currentTime: 1104, duration: 2895,
            audioTracks: [SiloControlTrack(kind: "audio", trackId: 1, title: "English 5.1", detail: "AC-3")],
            subtitleTracks: [SiloControlTrack(kind: "subtitle", trackId: 10, title: "English", detail: nil)],
            selectedAudioTrackId: 1, selectedSubtitleTrackId: nil,
            qualityOptions: [SiloControlOption(id: "auto", label: "Auto", detail: nil),
                             SiloControlOption(id: "1080", label: "1080p", detail: nil)],
            activeQualityId: "auto", isQualitySwitching: false,
            playbackSpeed: 1.0, videoGravity: VideoGravity.fit.rawValue, hdrEnabled: false,
            supportsVideoGravity: true,
            volume: 0.8,
            isMuted: false,
            hasNextEpisode: true,
            nextEpisodeTitle: "Forks",
            error: nil
        )
    }
}

#Preview("Now Playing") {
    ZStack {
        SiloControlArtworkBackground(urlString: nil)
        RemoteNowPlayingContent(
            state: .previewPlaying(),
            clock: RemotePlaybackClock(),
            targetName: "Living Room",
            posterURL: nil,
            onCommand: { _ in },
            onTogglePlayPause: {},
            onSeek: { _ in },
            onPlayNext: {},
            onSetVolume: { _ in },
            onSetMuted: { _ in }
        )
    }
    .preferredColorScheme(.dark)
}
#endif
#endif
