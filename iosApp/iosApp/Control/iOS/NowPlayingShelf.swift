import SwiftUI

/// The single now-playing accessory shown above the tab bar. Only one bar shows
/// at a time: a TV control session takes priority over an audiobook session. Renders
/// nothing (zero space) when neither is active.
struct NowPlayingShelf: View {
    var style: NowPlayingBarStyle = .card

    #if os(iOS)
    @Environment(SiloControlClient.self) private var siloControl
    #endif
    @Environment(AudioPlaybackStore.self) private var audioStore

    #if os(iOS)
    /// Whether a now-playing bar is showing. A TV control session takes
    /// priority over audio.
    static func hasActiveAccessory(control: SiloControlClient, audio: AudioPlaybackStore) -> Bool {
        control.remotePlaybackEngaged || audio.player.hasActiveSession
    }
    #endif

    var body: some View {
        #if os(iOS)
        // Stays mounted under the full remote sheet so dismissing the sheet
        // doesn't re-insert the accessory.
        if siloControl.remotePlaybackEngaged {
            SiloControlMiniBar(controller: siloControl, style: style)
                .animation(.snappy, value: siloControl.hasActiveSession)
                .animation(.snappy, value: siloControl.isReconnecting)
        } else if audioStore.player.hasActiveSession {
            AudioMiniPlayerView(style: style)
                .animation(.snappy, value: audioStore.player.hasActiveSession)
        }
        #else
        if audioStore.player.hasActiveSession {
            AudioMiniPlayerView(style: style)
                .animation(.snappy, value: audioStore.player.hasActiveSession)
        }
        #endif
    }
}

#if os(iOS)
/// Hosts `NowPlayingShelf` on a `TabView` so it rests above the tab bar.
/// iOS 26 uses the native Liquid Glass accessory; iOS 18 uses the card-styled
/// shelf in a safe-area inset. Nothing is attached while playback is idle.
struct NowPlayingShelfAttachment: ViewModifier {
    @Environment(SiloControlClient.self) private var siloControl
    @Environment(AudioPlaybackStore.self) private var audioStore

    private var isActive: Bool {
        NowPlayingShelf.hasActiveAccessory(control: siloControl, audio: audioStore)
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            // Toggling `isEnabled` keeps the TabView's structural identity, so
            // tabs keep their state when playback starts or stops.
            content.tabViewBottomAccessory(isEnabled: isActive) {
                NowPlayingShelf(style: .accessory)
                    .modifier(NowPlayingAccessoryPlacementReader())
            }
        } else if #available(iOS 26.0, *) {
            if isActive {
                content.tabViewBottomAccessory {
                    NowPlayingShelf(style: .accessory)
                        .modifier(NowPlayingAccessoryPlacementReader())
                }
            } else {
                content
            }
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                if isActive {
                    NowPlayingShelf(style: .card)
                }
            }
        }
    }
}
#endif
