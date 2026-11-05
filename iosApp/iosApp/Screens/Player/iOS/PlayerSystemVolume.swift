#if os(iOS)
import AVFoundation
import MediaPlayer
import SwiftUI

/// Reads and writes the device's output volume for the player's edge-swipe
/// gesture. iOS exposes no setter for `outputVolume`; the slider inside an
/// on-screen `MPVolumeView` is the supported way to move it. While that view
/// is in the window the system volume HUD stays hidden, so hardware-button
/// changes are reported through `onExternalChange` for the player's own gauge.
@MainActor
final class PlayerSystemVolume {
    var onExternalChange: ((Float) -> Void)?

    /// Lazy: SwiftUI builds a throwaway instance on every view init and keeps
    /// only the first, so only the kept one should create the view.
    private(set) lazy var volumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))

    private var observation: NSKeyValueObservation?

    var currentLevel: Float {
        AVAudioSession.sharedInstance().outputVolume
    }

    /// Returns false when there is no slider to move, such as on an output
    /// route without volume control, so the caller can skip its feedback.
    func apply(_ level: Float) -> Bool {
        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return false }
        slider.value = min(max(level, 0), 1)
        return true
    }

    func startObserving() {
        guard observation == nil else { return }
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let level = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.onExternalChange?(level)
            }
        }
    }

    func stopObserving() {
        observation?.invalidate()
        observation = nil
    }
}

struct PlayerSystemVolumeHost: UIViewRepresentable {
    let volume: PlayerSystemVolume

    func makeUIView(context: Context) -> MPVolumeView {
        volume.volumeView
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
#endif
