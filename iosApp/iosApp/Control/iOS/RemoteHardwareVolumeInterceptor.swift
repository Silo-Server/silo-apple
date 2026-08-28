#if os(iOS)
import AVFoundation
import MediaPlayer
import SwiftUI

/// Converts hardware volume changes into remote volume steps while its hidden
/// `MPVolumeView` suppresses the system HUD. The system volume is held at a
/// baseline: every user press is detected as a delta from the baseline and then
/// snapped back, so the buttons act only as remote controls (local audio volume
/// is left alone) and every subsequent press still produces a delta.
@MainActor
final class RemoteHardwareVolumeInterceptor {
    var onVolumeStep: ((Int) -> Void)?

    let volumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))

    private(set) var isActive = false
    private var originalSystemVolume: Float?
    private var baselineVolume: Float = 0.5
    private var pendingProgrammaticVolume: Float?
    private var claim: AetherAudioSessionOwnership.Claim?
    private var observation: NSKeyValueObservation?

    func start() {
        guard !isActive else { return }
        isActive = true
        pendingProgrammaticVolume = nil

        let session = AVAudioSession.sharedInstance()
        originalSystemVolume = session.outputVolume
        // Opening the remote must not interrupt another app's audio. The session
        // can already be `.playback` *without* `.mixWithOthers` — a stopped
        // Aether engine leaves it that way — and category alone is not enough to
        // tell: activating a non-mixing session is what does the interrupting.
        if session.category != .playback {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        } else if !session.categoryOptions.contains(.mixWithOthers) {
            // Keep the mode and options local playback established; add mixing.
            try? session.setCategory(
                .playback,
                mode: session.mode,
                options: session.categoryOptions.union(.mixWithOthers)
            )
        }
        try? session.setActive(true)

        claim = AetherAudioSessionOwnership.Claim(isHoldingAudio: { [weak self] in
            self?.isActive ?? false
        })

        // Hold near the current volume, clamped one hardware step away from the
        // rails so presses in both directions keep producing deltas.
        baselineVolume = min(max(session.outputVolume, 0.0625), 0.9375)

        observation = session.observe(\.outputVolume, options: [.old, .new]) { [weak self] _, change in
            Task { @MainActor [weak self] in
                guard let self, isActive,
                      let old = change.oldValue, let new = change.newValue else { return }
                if let pending = pendingProgrammaticVolume, abs(new - pending) < 0.001 {
                    pendingProgrammaticVolume = nil
                    return
                }
                if new > old {
                    onVolumeStep?(1)
                } else if new < old {
                    onVolumeStep?(-1)
                }
                setSystemVolume(to: baselineVolume)
            }
        }

        if session.outputVolume != baselineVolume {
            setSystemVolume(to: baselineVolume)
        }
    }

    private func setSystemVolume(to value: Float) {
        // Strong capture of the view (not self): restoration on stop() must run
        // even after SwiftUI has released this interceptor with the dismissed
        // sheet.
        let volumeView = volumeView
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first
                else { return }
                // Claim the value as ours only here, immediately before a write
                // that will actually move the volume. Claiming it at schedule
                // time would swallow a real press that lands on the same value
                // first — an up press followed by a down press inside the delay
                // returns to the baseline — and claiming a no-op write would
                // swallow the next genuine press at that value.
                if abs(AVAudioSession.sharedInstance().outputVolume - value) >= 0.001 {
                    self?.pendingProgrammaticVolume = value
                }
                slider.value = value
            }
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        observation?.invalidate()
        observation = nil

        if let originalSystemVolume {
            setSystemVolume(to: originalSystemVolume)
            self.originalSystemVolume = nil
        }

        if let claim {
            self.claim = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                Task { @MainActor in
                    // Ownership can change during the delay (playback starting,
                    // this remote reopening), so decide at execution time. The
                    // captured claim stays registered until this runs, but its
                    // probe reports inactive, so it blocks no one else.
                    guard AetherAudioSessionOwnership.canReleaseSharedSession(excluding: claim)
                    else { return }
                    try? AVAudioSession.sharedInstance().setActive(
                        false,
                        options: .notifyOthersOnDeactivation
                    )
                }
            }
        }
    }
}

struct HiddenVolumeHost: UIViewRepresentable {
    let interceptor: RemoteHardwareVolumeInterceptor

    func makeUIView(context: Context) -> MPVolumeView {
        interceptor.volumeView
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
#endif
