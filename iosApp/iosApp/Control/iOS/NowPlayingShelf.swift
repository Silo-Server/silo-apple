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

    /// Single source of truth for "is a now-playing bar currently shown".
    /// TV control (when not showing the full remote) takes priority over audio.
    #if os(iOS)
    static func hasActiveAccessory(control: SiloControlClient, audio: AudioPlaybackStore) -> Bool {
        if controlBarVisible(control) { return true }
        return audio.player.hasActiveSession
    }

    /// Mirrors `SiloControlMiniBar.isVisible`: a live session (excluding a
    /// still-unconfirmed auto-resume probe) or an in-flight reconnect. The bar
    /// stays mounted while the full remote sheet is up — detaching the
    /// tabViewBottomAccessory there made it re-insert (with a system slide-in)
    /// every time the sheet was swiped away.
    static func controlBarVisible(_ control: SiloControlClient) -> Bool {
        (control.hasActiveSession && !control.isAutoResuming) || control.isReconnecting
    }
    #else
    static func hasActiveAccessory(audio: AudioPlaybackStore) -> Bool {
        audio.player.hasActiveSession
    }
    #endif

    var body: some View {
        #if os(iOS)
        if Self.controlBarVisible(siloControl) {
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
/// Hosts `NowPlayingShelf` on a `TabView` so it rests above the tab bar via the
/// native `tabViewBottomAccessory` (Liquid Glass, chromeless content). The
/// accessory is only attached while something is playing, so no empty bar shows
/// when idle.
struct NowPlayingShelfAttachment: ViewModifier {
    @Environment(SiloControlClient.self) private var siloControl
    @Environment(AudioPlaybackStore.self) private var audioStore

    private var isActive: Bool {
        NowPlayingShelf.hasActiveAccessory(control: siloControl, audio: audioStore)
    }

    func body(content: Content) -> some View {
        if isActive {
            content.tabViewBottomAccessory {
                NowPlayingShelf(style: .accessory)
            }
        } else {
            content
        }
    }
}
#endif
