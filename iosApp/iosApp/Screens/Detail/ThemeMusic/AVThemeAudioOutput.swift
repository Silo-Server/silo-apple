import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Theme audio through `AVPlayer`. The signed URL goes into the player item or
/// the one download request and nowhere else: nothing here logs it.
///
/// Original audio streams straight from its URL; it supports byte ranges. A
/// converted theme is progressive AAC in fragmented MP4 with no length and no
/// byte ranges, which `AVPlayer` refuses over HTTP, so it is read into memory
/// first (themes are short and the server caps the bitrate) and served to the
/// player from there. Nothing is written to disk.
///
/// The audio session stays as the app left it. Aether declares its category
/// once, when an engine is created, and a long-lived audiobook engine would
/// later play under any category changed here; on tvOS an extra activation can
/// also latch the HDMI route. So the player only declines to start over another
/// app's audio, which leaves it nothing to hand back, and takes no part in
/// releasing the session: it never deactivates it (that could land while a
/// video is starting) and holds no ownership claim (that would keep a video or
/// audiobook teardown from releasing it, with nothing left to release it
/// later). If such a teardown ends the session under a playing theme, the
/// optional theme simply stops.
@MainActor
final class AVThemeAudioOutput: ThemeAudioOutput {
    /// A converted theme larger than this is not a theme; give up on it.
    static let maxConvertedBytes = 32 * 1024 * 1024

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    var isLooping = false
    private(set) var isPlaying = false
    var onEnded: (() -> Void)?
    var onFailed: (() -> Void)?
    var onProgress: (() -> Void)?

    private let player = AVPlayer()
    private var observers: [NSObjectProtocol] = []
    private var statusObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var reportedProgress = false
    private var download: Task<Void, Never>?
    /// Kept alive for the item: the asset holds its delegate weakly.
    private var memoryLoader: ThemeMemoryLoader?
    private var isTornDown = false

    init(grant: ThemeMusicGrant) {
        player.volume = 0
        #if os(iOS) || os(tvOS)
        player.allowsExternalPlayback = false
        #endif
        player.preventsDisplaySleepDuringVideoPlayback = false
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.reportedProgress, time.seconds > 0 else { return }
                self.reportedProgress = true
                self.onProgress?()
            }
        }
        if grant.isConverted {
            let url = grant.url
            download = Task { [weak self] in
                let data = await Self.read(url)
                guard let self, !self.isTornDown, !Task.isCancelled else { return }
                guard let data else {
                    self.onFailed?()
                    return
                }
                let loader = ThemeMemoryLoader(data: data)
                self.memoryLoader = loader
                self.attach(AVPlayerItem(asset: loader.asset))
            }
        } else {
            attach(AVPlayerItem(url: grant.url))
        }
    }

    func play() {
        #if os(iOS) || os(tvOS)
        // Another app's music, a call or Siri: a page's theme is not worth interrupting it.
        guard !AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint else { return }
        #endif
        isPlaying = true
        // Before a converted theme has arrived this only records the intent;
        // `attach` starts the item.
        player.play()
    }

    func pause() {
        isPlaying = false
        player.pause()
    }

    func tearDown() {
        isTornDown = true
        isPlaying = false
        download?.cancel()
        download = nil
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        detachItem()
        player.replaceCurrentItem(with: nil)
        memoryLoader = nil
        onEnded = nil
        onFailed = nil
        onProgress = nil
    }

    private func attach(_ item: AVPlayerItem) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ended() }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onFailed?() }
        })
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.onFailed?() }
        }
        player.replaceCurrentItem(with: item)
        if isPlaying { player.play() }
    }

    private func detachItem() {
        statusObservation = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func ended() {
        if isLooping {
            player.seek(to: .zero)
            player.play()
        } else {
            isPlaying = false
            onEnded?()
        }
    }

    /// The whole converted stream, or nil on any failure or past the size cap.
    /// An ephemeral session keeps it off disk.
    private nonisolated static func read(_ url: URL) async -> Data? {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (bytes, response) = try? await session.bytes(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        var data = Data()
        do {
            for try await chunk in bytes.chunked() {
                data.append(contentsOf: chunk)
                if data.count > maxConvertedBytes { return nil }
            }
        } catch {
            return nil
        }
        return data.isEmpty ? nil : data
    }
}

private extension URLSession.AsyncBytes {
    /// Bytes in 64 KB pieces, so a large read is not one append per byte.
    func chunked() -> AsyncThrowingStream<[UInt8], Error> {
        var iterator = makeAsyncIterator()
        return AsyncThrowingStream {
            var chunk: [UInt8] = []
            chunk.reserveCapacity(65_536)
            while chunk.count < 65_536, let byte = try await iterator.next() {
                chunk.append(byte)
            }
            return chunk.isEmpty ? nil : chunk
        }
    }
}

/// Serves an in-memory converted theme to `AVPlayer` with byte ranges, which
/// the stream itself lacks.
private final class ThemeMemoryLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let data: Data
    private let queue = DispatchQueue(label: "org.siloserver.silo.theme-music.loader")
    let asset: AVURLAsset

    init(data: Data) {
        self.data = data
        // A custom scheme sends every read to the delegate; the URL carries nothing.
        asset = AVURLAsset(url: URL(string: "silo-theme://memory/theme.m4a")!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        if let info = request.contentInformationRequest {
            info.contentType = UTType.mpeg4Audio.identifier
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = true
        }
        if let range = request.dataRequest {
            let start = Int(range.requestedOffset)
            guard start <= data.count else {
                request.finishLoading(with: URLError(.badServerResponse))
                return true
            }
            let length = range.requestsAllDataToEndOfResource ? data.count - start : range.requestedLength
            range.respond(with: data.subdata(in: start..<min(data.count, start + length)))
        }
        request.finishLoading()
        return true
    }
}
