import AVFoundation
import CoreMedia
import Foundation
import Libavcodec
import Libavutil
import Libswresample

final class AudioDecodePipeline {
    struct ResamplingOutput {
        let swrContext: OpaquePointer
        let config: NegotiatedAudioOutput
    }

    struct DecodedChunk {
        let chunk: DecodedAudioChunk
        let ptsSeconds: Double
        let convertedSamples: Int32
    }

    func decodePacket(
        _ packet: UnsafeMutablePointer<AVPacket>,
        codecContext: UnsafeMutablePointer<AVCodecContext>,
        timeBase: AVRational,
        eagain: Int32,
        outputForFrame: (UnsafeMutablePointer<AVFrame>) -> ResamplingOutput?,
        onChunk: (DecodedChunk) -> Void
    ) {
        let sendResult = avcodec_send_packet(codecContext, packet)
        if sendResult < 0 && sendResult != eagain {
            return
        }

        while true {
            guard let frame = av_frame_alloc() else { return }
            let receiveResult = avcodec_receive_frame(codecContext, frame)
            if receiveResult < 0 {
                var frameToFree: UnsafeMutablePointer<AVFrame>? = frame
                av_frame_free(&frameToFree)
                return
            }
            autoreleasepool {
                if let output = outputForFrame(frame),
                   let decoded = resample(
                       frame: frame,
                       swrContext: output.swrContext,
                       config: output.config,
                       timeBase: timeBase
                   ) {
                    onChunk(decoded)
                }
            }
            var frameToFree: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&frameToFree)
        }
    }

    private func resample(
        frame: UnsafeMutablePointer<AVFrame>,
        swrContext: OpaquePointer,
        config: NegotiatedAudioOutput,
        timeBase: AVRational
    ) -> DecodedChunk? {
        let inSamples = frame.pointee.nb_samples
        let outSamplesMax = swr_get_out_samples(swrContext, inSamples) + 32
        guard outSamplesMax > 0 else { return nil }

        let bytesPerSample = config.bytesPerSample
        let planeCount = max(1, Int(config.channelCount))
        var outPtrs = Array<UnsafeMutablePointer<UInt8>?>(repeating: nil, count: planeCount)
        var outLineSize: Int32 = 0
        let allocResult = av_samples_alloc(
            &outPtrs,
            &outLineSize,
            config.channelCount,
            outSamplesMax,
            AV_SAMPLE_FMT_FLTP,
            1
        )
        guard allocResult >= 0 else { return nil }
        defer { av_freep(&outPtrs[0]) }

        var inPtrs = withUnsafeBytes(of: frame.pointee.data) { raw -> [UnsafePointer<UInt8>?] in
            let ptrs = raw.bindMemory(to: UnsafeMutablePointer<UInt8>?.self)
            return ptrs.map { $0.map { UnsafePointer($0) } }
        }
        let converted = outPtrs.withUnsafeMutableBufferPointer { outBP -> Int32 in
            inPtrs.withUnsafeMutableBufferPointer { inBP -> Int32 in
                swr_convert(
                    swrContext,
                    outBP.baseAddress,
                    outSamplesMax,
                    inBP.baseAddress,
                    inSamples
                )
            }
        }
        guard converted > 0 else { return nil }

        let planeByteSize = Int(converted) * bytesPerSample
        let planes = outPtrs.prefix(planeCount).map { planePtr -> Data in
            guard let planePtr else { return Data() }
            return Data(bytes: planePtr, count: planeByteSize)
        }

        let noPts = Int64.min
        let ptsRaw: Int64 = {
            let best = frame.pointee.best_effort_timestamp
            if best != noPts { return best }
            let pts = frame.pointee.pts
            if pts != noPts { return pts }
            return 0
        }()
        let ptsSeconds = Double(ptsRaw) * Double(timeBase.num) / Double(timeBase.den)
        let pts = CMTime(seconds: ptsSeconds, preferredTimescale: 600)
        let duration = CMTime(
            value: CMTimeValue(converted),
            timescale: CMTimeScale(config.sampleRate)
        )
        let chunk = DecodedAudioChunk(
            pts: pts,
            duration: duration,
            sampleRate: config.sampleRate,
            channelCount: config.channelCount,
            frameCount: AVAudioFrameCount(converted),
            bytesPerSample: bytesPerSample,
            audioFormat: config.audioFormat,
            planes: planes
        )
        return DecodedChunk(chunk: chunk, ptsSeconds: ptsSeconds, convertedSamples: converted)
    }
}
