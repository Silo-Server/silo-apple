#if os(macOS)
import AppKit
import Foundation
import SwiftUI

struct MacPlayerControls: View {
    let viewModel: PlayerViewModel
    let showTransportControls: Bool
    @Binding var isOptionsPresented: Bool
    @Binding var selectedOptionsTab: MacPlayerOptionsPanel.Tab
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if showTransportControls {
                topBar
            }
            Spacer(minLength: 0)
            if !isOptionsPresented && (viewModel.showIntroSkip || viewModel.showSecondaryMarkerSkip) {
                markerSkipControls
                    .padding(.bottom, showTransportControls ? 12 : 0)
            }
            if showTransportControls {
                bottomControls
            }
        }
        .padding(20)
    }

    private var markerSkipControls: some View {
        HStack(spacing: 8) {
            Spacer()
            if viewModel.showIntroSkip {
                if viewModel.introAutoSkipCountdownSeconds != nil {
                    markerButton("Cancel", systemImage: "xmark", action: viewModel.cancelIntroAutoSkip)
                        .accessibilityLabel("Cancel Auto-Skip Intro")
                }
                markerButton(introSkipTitle, action: viewModel.skipIntro)
                    .accessibilityLabel(
                        viewModel.introAutoSkipCountdownSeconds == nil ? "Skip Intro" : "Skip Intro Now"
                    )
            } else if viewModel.showSecondaryMarkerSkip {
                markerButton(viewModel.secondaryMarkerSkipTitle, action: viewModel.skipSecondaryMarker)
            }
        }
    }

    private var introSkipTitle: String {
        if let countdown = viewModel.introAutoSkipCountdownSeconds {
            return "Skip Intro · \(countdown)"
        }
        return "Skip Intro"
    }

    private func markerButton(
        _ title: String,
        systemImage: String = "forward.end.fill",
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 14)
                .frame(height: 32)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.black)
        .background(Capsule(style: .continuous).fill(Color.white))
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.title.isEmpty ? "Silo" : viewModel.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if !viewModel.metadata.badges.isEmpty {
                    Text(viewModel.metadata.badges.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.66))
                        .lineLimit(1)
                }
            }

            Spacer()

            iconButton("xmark", help: "Close", action: onDismiss)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.50))
        )
    }

    private var bottomControls: some View {
        VStack(spacing: 12) {
            MacPlayerTimeline(viewModel: viewModel)

            HStack(spacing: 10) {
                iconButton("gobackward.15", help: "Back 15 seconds") {
                    viewModel.skipBackward(15)
                }

                Button {
                    viewModel.togglePlayPause()
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 38, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white)
                )
                .help(viewModel.isPlaying ? "Pause" : "Play")

                iconButton("goforward.15", help: "Forward 15 seconds") {
                    viewModel.skipForward(15)
                }

                Divider()
                    .frame(height: 24)
                    .overlay(Color.white.opacity(0.18))
                    .padding(.horizontal, 4)

                iconButton("captions.bubble", help: "Audio and subtitle options") {
                    selectedOptionsTab = .subtitles
                    isOptionsPresented.toggle()
                }
                .disabled(!viewModel.hasTrackSelectionOptions)
                .opacity(viewModel.hasTrackSelectionOptions ? 1 : 0.45)

                iconButton("list.bullet", help: "Chapters") {
                    selectedOptionsTab = .chapters
                    isOptionsPresented.toggle()
                }
                .disabled(viewModel.chapters.isEmpty)
                .opacity(viewModel.chapters.isEmpty ? 0.45 : 1)

                iconButton("speedometer", help: "Playback speed") {
                    selectedOptionsTab = .playback
                    isOptionsPresented.toggle()
                }

                iconButton("chart.line.uptrend.xyaxis", help: "Stats and route") {
                    selectedOptionsTab = .playback
                    isOptionsPresented.toggle()
                }

                Spacer(minLength: 8)

                Text(speedLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.70))
                    .monospacedDigit()

                iconButton("arrow.up.left.and.arrow.down.right", help: "Fullscreen") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.42))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func iconButton(
        _ systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 31, height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .help(help)
    }

    private var speedLabel: String {
        let speed = viewModel.settings.playbackSpeed
        if abs(speed - 1.0) < 0.01 { return "1x" }
        return String(format: "%.2gx", speed)
    }
}
#endif
