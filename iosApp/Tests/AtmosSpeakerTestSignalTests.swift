import AVFoundation
import XCTest
@testable import Silo

/// The speaker test is only useful if the burst for a speaker comes out of that speaker. Each
/// channel's APAC file must decode with its energy on that channel and nowhere else, in the
/// 7.1.4 order the TrueHD Atmos path also renders into.
final class AtmosSpeakerTestSignalTests: XCTestCase {
    func testEachSpeakersBurstDecodesOnItsOwnChannel() throws {
        guard #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) else { throw XCTSkip("APAC needs OS 26") }
        for speaker in AtmosTestSpeaker.allCases {
            let energy = try decodedChannelEnergy(try AtmosSpeakerTestSignal.file(for: speaker))
            let total = energy.reduce(0, +)
            XCTAssertGreaterThan(total, 0, "\(speaker.name) produced no audio")
            XCTAssertGreaterThan(energy[speaker.channelIndex] / total, 0.99,
                                 "\(speaker.name) leaked into other channels: \(energy)")
        }
    }

    func testBurstIsCalibrationLevelWithSilenceBetweenLoops() {
        guard #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) else { return }
        for lowPass in [false, true] {
            let samples = AtmosSpeakerTestSignal.burst(lowPass: lowPass)
            let active = Int(AtmosSpeakerTestSignal.sampleRate * AtmosSpeakerTestSignal.burstSeconds)
            let rms = (samples[..<active].reduce(0) { $0 + $1 * $1 } / Float(active)).squareRoot()
            XCTAssertEqual(rms, AtmosSpeakerTestSignal.targetRMS, accuracy: 0.01)
            XCTAssertTrue(samples[active...].allSatisfy { $0 == 0 })
            XCTAssertLessThanOrEqual(samples.map(abs).max() ?? 0, 1)
        }
    }

    @available(iOS 26.0, tvOS 26.0, macOS 26.0, *)
    private func decodedChannelEnergy(_ url: URL) throws -> [Double] {
        let channels = AtmosSpeakerTestSignal.channelCount
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Atmos_7_1_4
        let asset = AVURLAsset(url: url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: channels,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var energy = [Double](repeating: 0, count: channels)
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &length, dataPointerOut: &pointer)
            guard let pointer else { continue }
            let floats = UnsafeRawPointer(pointer).bindMemory(to: Float.self, capacity: length / 4)
            for i in 0..<(length / 4) { energy[i % channels] += Double(floats[i] * floats[i]) }
        }
        XCTAssertEqual(reader.status, .completed)
        return energy
    }
}
