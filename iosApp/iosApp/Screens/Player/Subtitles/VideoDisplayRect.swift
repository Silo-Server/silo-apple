//
//  VideoDisplayRect.swift
//  Silo (iOS + tvOS + macOS)
//
//  Computes the rect the video occupies inside a host view's bounds for a
//  given gravity — the AVSampleBufferDisplayLayer equivalent of
//  `AVPlayerLayer.videoRect`. The CoreMedia player surfaces use it to size
//  the libass subtitle overlay to the displayed video, so subtitle font
//  scale tracks the video frame rather than the full view (which would make
//  text tiny in landscape and huge in portrait).

import AVFoundation
import CoreGraphics

/// Distances (in points) from a full-frame subtitle overlay's edges to the
/// displayed video rect inside it. Passed to libass via `ass_set_margins`
/// so font scaling stays keyed to the video area while `use_margins`
/// placement can render regular cues into the letterbox bars.
struct SubtitleVideoInsets: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
    var left: CGFloat = 0
    var right: CGFloat = 0

    static let zero = SubtitleVideoInsets()

    init() {}

    init(videoRect: CGRect, bounds: CGRect) {
        guard !bounds.isEmpty, !videoRect.isEmpty else { return }
        top = max(0, videoRect.minY - bounds.minY)
        bottom = max(0, bounds.maxY - videoRect.maxY)
        left = max(0, videoRect.minX - bounds.minX)
        right = max(0, bounds.maxX - videoRect.maxX)
    }
}

enum VideoDisplayRect {
    /// - Parameters:
    ///   - videoSize: pixel-aspect-corrected presentation size of the video;
    ///     pass `.zero` when unknown to fall back to `bounds`.
    ///   - bounds: the host view's bounds.
    ///   - gravity: the display layer's video gravity.
    static func compute(
        videoSize: CGSize,
        bounds: CGRect,
        gravity: AVLayerVideoGravity
    ) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0, !bounds.isEmpty else {
            return bounds
        }
        switch gravity {
        case .resizeAspect:
            return AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
        default:
            // .resizeAspectFill and .resize cover the whole view; the
            // visible video region is the full bounds.
            return bounds
        }
    }
}
