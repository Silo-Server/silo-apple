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
///
/// On iOS 26.1 and later the same slot shows the iPhone Libraries tab's dock
/// while that tab is on screen and nothing is playing, so the dock shrinks
/// with the tab bar. Now playing always keeps priority; the dock then stays
/// in its page.
struct NowPlayingShelfAttachment: ViewModifier {
    /// Shows the shelf as a card above the page instead of the tab bar
    /// accessory, for layouts that hide the system tab bar.
    var showsCard = false

    @Environment(SiloControlClient.self) private var siloControl
    @Environment(AudioPlaybackStore.self) private var audioStore
    @Environment(LibraryDockHost.self) private var dockHost: LibraryDockHost?

    private var isActive: Bool {
        NowPlayingShelf.hasActiveAccessory(control: siloControl, audio: audioStore)
    }

    /// The library dock to show in the slot, when the slot is free for it.
    private var slotDock: LibraryDockModel? {
        guard !isActive, !showsCard else { return nil }
        return dockHost?.dock
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            // Toggling `isEnabled` keeps the TabView's structural identity, so
            // tabs keep their state when playback starts or stops, when the
            // Libraries tab comes and goes, or when the layout switches
            // between the accessory and the card.
            content
                .tabViewBottomAccessory(isEnabled: (isActive && !showsCard) || slotDock != nil) {
                    Group {
                        if isActive {
                            NowPlayingShelf(style: .accessory)
                        } else if let slotDock {
                            LibraryDockAccessory(model: slotDock)
                        }
                    }
                    .modifier(NowPlayingAccessoryPlacementReader())
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if isActive && showsCard {
                        NowPlayingShelf(style: .card)
                    }
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
