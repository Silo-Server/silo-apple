import AVFoundation
import QuartzCore
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Full-screen startup animation shown while the app resolves its initial auth route.
struct StartupSplashView: View {
    private static let maximumDisplayDuration: TimeInterval = 4.0

    let onFinished: () -> Void

    @State private var player = AVPlayer()
    @State private var playerItem: AVPlayerItem?
    @State private var playbackEndObserver: NSObjectProtocol?
    @State private var playbackFailureObserver: NSObjectProtocol?
    @State private var completionTask: Task<Void, Never>?
    @State private var isVideoAvailable = true
    @State private var didFinish = false

    var body: some View {
        ZStack {
            Color.siloBackground.ignoresSafeArea()

            if isVideoAvailable {
                startupVideo
            } else {
                fallbackContent
            }
        }
        .accessibilityLabel("Loading Silo")
        .onAppear(perform: startPlayback)
        .onDisappear(perform: stopPlayback)
    }

    @ViewBuilder
    private var startupVideo: some View {
        #if os(tvOS)
        GeometryReader { proxy in
            let videoWidth = min(proxy.size.width * 0.25, 440)

            StartupSplashPlayerSurface(player: player)
                .frame(width: videoWidth, height: videoWidth * 9.0 / 16.0)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .ignoresSafeArea()
        #elseif os(iOS)
        GeometryReader { proxy in
            let videoWidth = min(proxy.size.width * 0.6, 320)

            StartupSplashPlayerSurface(player: player)
                .frame(width: videoWidth, height: videoWidth * 9.0 / 16.0)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .ignoresSafeArea()
        #else
        StartupSplashPlayerSurface(player: player)
            .ignoresSafeArea()
        #endif
    }

    private var fallbackContent: some View {
        VStack(spacing: 20) {
            SiloWordmarkView(width: 132)

            ProgressView()
                .tint(.siloOnSurface)
                .scaleEffect(1.2)
        }
    }

    private func startPlayback() {
        scheduleCompletion()

        if playerItem == nil {
            guard let url = Bundle.main.url(forResource: "startup_splash", withExtension: "mp4") else {
                isVideoAvailable = false
                return
            }

            let item = AVPlayerItem(url: url)
            playerItem = item
            player.replaceCurrentItem(with: item)
            player.isMuted = true
            installPlaybackObservers(for: item)
        }

        player.play()
    }

    private func stopPlayback() {
        player.pause()
        completionTask?.cancel()
        completionTask = nil
        removePlaybackObservers()
    }

    private func installPlaybackObservers(for item: AVPlayerItem) {
        removePlaybackObservers()

        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            finish()
        }

        playbackFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            isVideoAvailable = false
        }
    }

    private func removePlaybackObservers() {
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
            self.playbackEndObserver = nil
        }
        if let playbackFailureObserver {
            NotificationCenter.default.removeObserver(playbackFailureObserver)
            self.playbackFailureObserver = nil
        }
    }

    private func scheduleCompletion() {
        guard completionTask == nil else { return }
        completionTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.maximumDisplayDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { finish() }
        }
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        completionTask?.cancel()
        completionTask = nil
        removePlaybackObservers()
        isVideoAvailable = false
        onFinished()
    }
}

#if os(macOS)
private struct StartupSplashPlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> StartupSplashPlayerLayerView {
        let view = StartupSplashPlayerLayerView()
        view.attach(player: player)
        return view
    }

    func updateNSView(_ nsView: StartupSplashPlayerLayerView, context: Context) {
        nsView.attach(player: player)
    }
}

private final class StartupSplashPlayerLayerView: NSView {
    private let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(player: AVPlayer) {
        if playerLayer.player === player { return }
        playerLayer.player = player
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
#else
private struct StartupSplashPlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> StartupSplashPlayerLayerView {
        let view = StartupSplashPlayerLayerView()
        view.attach(player: player)
        return view
    }

    func updateUIView(_ uiView: StartupSplashPlayerLayerView, context: Context) {
        uiView.attach(player: player)
    }
}

private final class StartupSplashPlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer {
        // swiftlint:disable:next force_cast
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        playerLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(player: AVPlayer) {
        if playerLayer.player === player { return }
        playerLayer.player = player
    }
}
#endif
