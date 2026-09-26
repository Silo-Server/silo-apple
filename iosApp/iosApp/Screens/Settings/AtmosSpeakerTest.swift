import AVFoundation
import Foundation
import Observation

/// One speaker in the 7.1.4 bed the TrueHD Atmos path renders into, in CoreAudio's
/// `kAudioChannelLayoutTag_Atmos_7_1_4` channel order.
enum AtmosTestSpeaker: Int, CaseIterable, Identifiable, Sendable {
    case frontLeft, frontRight, center, subwoofer
    case sideLeft, sideRight, rearLeft, rearRight
    case topFrontLeft, topFrontRight, topRearLeft, topRearRight

    var id: Int { rawValue }
    var channelIndex: Int { rawValue }

    var name: String {
        switch self {
        case .frontLeft: return "Front Left"
        case .frontRight: return "Front Right"
        case .center: return "Center"
        case .subwoofer: return "Subwoofer"
        case .sideLeft: return "Surround Left"
        case .sideRight: return "Surround Right"
        case .rearLeft: return "Rear Surround Left"
        case .rearRight: return "Rear Surround Right"
        case .topFrontLeft: return "Top Front Left"
        case .topFrontRight: return "Top Front Right"
        case .topRearLeft: return "Top Rear Left"
        case .topRearRight: return "Top Rear Right"
        }
    }

    var isHeight: Bool { rawValue >= Self.topFrontLeft.rawValue }

    static let floor: [AtmosTestSpeaker] = allCases.filter { !$0.isHeight }
    static let height: [AtmosTestSpeaker] = allCases.filter(\.isHeight)
}

/// Plays a pink-noise burst on one speaker of a 7.1.4 bed, through the same route TrueHD Atmos
/// playback uses: 7.1.4 Apple Positional Audio in AVPlayer, which Apple TV sends to an Atmos
/// receiver or soundbar as Dolby Atmos and iPhone renders as Spatial Audio. A burst from the
/// wrong speaker, or none from a height, shows a problem with that route or the room, not with
/// one film.
///
/// Each channel's test file is encoded once on first use and cached.
@available(iOS 26.0, tvOS 26.0, macOS 26.0, *)
@MainActor
@Observable
final class AtmosSpeakerTestPlayer {
    enum State: Equatable {
        case idle
        case preparing(AtmosTestSpeaker)
        case playing(AtmosTestSpeaker)
        case failed(String)
    }

    private(set) var state: State = .idle

    @ObservationIgnored private var player: AVQueuePlayer?
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var request = 0

    var activeSpeaker: AtmosTestSpeaker? {
        switch state {
        case .preparing(let speaker), .playing(let speaker): return speaker
        case .idle, .failed: return nil
        }
    }

    /// Start `speaker`, or stop it when it is already the one playing.
    func toggle(_ speaker: AtmosTestSpeaker) {
        if activeSpeaker == speaker { stop() } else { play(speaker) }
    }

    func play(_ speaker: AtmosTestSpeaker) {
        stop()
        request += 1
        let current = request
        state = .preparing(speaker)
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try AtmosSpeakerTestSignal.file(for: speaker)
                }.value
                guard current == request else { return }
                activateAudioSession()
                let item = AVPlayerItem(url: url)
                let queue = AVQueuePlayer()
                looper = AVPlayerLooper(player: queue, templateItem: item)
                player = queue
                queue.play()
                state = .playing(speaker)
            } catch {
                guard current == request else { return }
                state = .failed("The test signal could not be created (\(error.localizedDescription)).")
            }
        }
    }

    func stop() {
        request += 1
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
        if case .failed = state { return }
        state = .idle
    }

    private func activateAudioSession() {
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        #if os(iOS)
        try? session.setSupportsMultichannelContent(true)
        #endif
        try? session.setActive(true)
        #endif
    }
}

/// The per-channel test files: 1.5 s of pink noise at −20 dBFS RMS (the level speaker
/// calibration uses) followed by 0.5 s of silence, on one channel of a 7.1.4 bed, encoded as
/// APAC in an MP4. The subwoofer channel gets the same noise low-passed at 120 Hz.
@available(iOS 26.0, tvOS 26.0, macOS 26.0, *)
enum AtmosSpeakerTestSignal {
    static let sampleRate = 48_000.0
    static let channelCount = 12
    static let burstSeconds = 1.5
    static let loopSeconds = 2.0
    static let targetRMS: Float = 0.1  // −20 dBFS
    /// Bump when the signal or encoding changes so cached files are rebuilt.
    static let version = 1

    enum SignalError: Error, LocalizedError {
        case writerFailed(String)
        var errorDescription: String? {
            switch self { case .writerFailed(let why): return why }
        }
    }

    static func file(for speaker: AtmosTestSpeaker) throws -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AtmosSpeakerTest", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("v\(version)-ch\(speaker.channelIndex).mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let partial = directory.appendingPathComponent(UUID().uuidString + ".mp4")
        try write(samples: burst(lowPass: speaker == .subwoofer), channel: speaker.channelIndex, to: partial)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: partial, to: url)
        return url
    }

    /// One loop of the burst, mono: noise with 20 ms fades, then silence.
    static func burst(lowPass: Bool) -> [Float] {
        let total = Int(sampleRate * loopSeconds)
        let active = Int(sampleRate * burstSeconds)
        var samples = [Float](repeating: 0, count: total)
        var seed: UInt32 = 0x5EED
        var b0: Float = 0, b1: Float = 0, b2: Float = 0, lp: Float = 0
        let lpCoefficient = Float(1 - exp(-2 * Double.pi * 120 / sampleRate))
        for i in 0..<active {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let white = Float(seed >> 8) / Float(1 << 23) - 1
            // Paul Kellet's economy pink-noise filter.
            b0 = 0.99765 * b0 + white * 0.0990460
            b1 = 0.96300 * b1 + white * 0.2965164
            b2 = 0.57000 * b2 + white * 1.0526913
            var value = b0 + b1 + b2 + white * 0.1848
            if lowPass {
                lp += lpCoefficient * (value - lp)
                value = lp
            }
            samples[i] = value
        }
        let rms = (samples[..<active].reduce(0) { $0 + $1 * $1 } / Float(active)).squareRoot()
        let fade = Int(sampleRate * 0.02)
        for i in 0..<active {
            let ramp = min(1, Float(min(i, active - 1 - i)) / Float(fade))
            samples[i] *= (rms > 0 ? targetRMS / rms : 0) * ramp
        }
        return samples
    }

    static func write(samples: [Float], channel: Int, to url: URL) throws {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Atmos_7_1_4
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAPAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVChannelLayoutKey: layoutData,
            AVEncoderBitRateKey: channelCount * 320_000,
            AVEncoderContentSourceKey: AVAudioContentSource.appleAV_Spatial_Offline.rawValue,
            AVEncoderDynamicRangeControlConfigurationKey: AVAudioDynamicRangeControlConfiguration.none.rawValue,
        ]
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channelCount), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channelCount), mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        guard let format else { throw SignalError.writerFailed("no PCM format") }

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw SignalError.writerFailed("APAC is unavailable on this device") }
        writer.add(input)
        guard writer.startWriting() else {
            throw SignalError.writerFailed(writer.error?.localizedDescription ?? "writer did not start")
        }
        writer.startSession(atSourceTime: .zero)

        var interleaved = [Float](repeating: 0, count: samples.count * channelCount)
        for (i, value) in samples.enumerated() { interleaved[i * channelCount + channel] = value }
        let byteCount = interleaved.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block)
        guard let block else { throw SignalError.writerFailed("no sample memory") }
        interleaved.withUnsafeBytes {
            _ = CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        var sampleBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: samples.count,
            presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sampleBuffer)
        guard let sampleBuffer else { throw SignalError.writerFailed("no sample buffer") }
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
        guard input.append(sampleBuffer) else {
            throw SignalError.writerFailed(writer.error?.localizedDescription ?? "append failed")
        }
        input.markAsFinished()

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw SignalError.writerFailed(writer.error?.localizedDescription ?? "writer did not finish")
        }
    }
}
