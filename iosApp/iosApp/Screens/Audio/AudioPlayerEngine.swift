import AVFoundation
import Foundation

@MainActor
final class AudioPlayerEngine {
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var playbackRate: Float = 1.0

    var onTime: ((Double) -> Void)?
    var onEnded: (() -> Void)?

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.onTime?(time.seconds)
            }
        }
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    func load(url: URL, headers: [String: String], startSeconds: Double) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        var options: [String: Any] = [:]
        if !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onEnded?()
            }
        }
        player.replaceCurrentItem(with: item)
        seek(to: startSeconds)
    }

    func pause() {
        player.pause()
    }

    func setRate(_ rate: Double, shouldResume: Bool) {
        playbackRate = Float(min(max(rate, 0.5), 3.0))
        if shouldResume {
            player.playImmediately(atRate: playbackRate)
        }
    }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}
