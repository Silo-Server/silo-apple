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

/// Black bars encoded *into* the picture, as fractions of the frame height.
///
/// A 2.39:1 image mastered inside a 1920x1080 frame — common on WEB-DLs — is
/// a 16:9 video as far as every layer of the stack is concerned, so
/// `AVPlayerLayer.videoRect` covers the full height and a bottom-anchored cue
/// lands in the black bar instead of over the image. Nothing in the container
/// says so; only the pixels do, which is why the measurement arrives from the
/// server (`letterbox_top_fraction` / `letterbox_bottom_fraction`) rather than
/// being derived here.
struct BakedLetterbox: Equatable {
    var topFraction: CGFloat
    var bottomFraction: CGFloat

    static let none = BakedLetterbox(topFraction: 0, bottomFraction: 0)

    var isDetected: Bool { topFraction > 0 || bottomFraction > 0 }

    init(topFraction: CGFloat, bottomFraction: CGFloat) {
        self.topFraction = Self.sanitize(topFraction)
        self.bottomFraction = Self.sanitize(bottomFraction)
    }

    /// Clamped independently of the server's own sanitising: a bad or hostile
    /// measurement must not be able to push subtitles into the middle of the
    /// picture, and a bar this thin is not worth moving them for.
    private static func sanitize(_ fraction: CGFloat) -> CGFloat {
        guard fraction.isFinite, fraction >= minFraction, fraction <= maxFraction else { return 0 }
        return fraction
    }

    private static let minFraction: CGFloat = 0.02
    private static let maxFraction: CGFloat = 0.25
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

    /// The rect the actual *image* occupies inside a displayed video rect,
    /// once bars baked into the frame are taken off.
    ///
    /// Only applied under `.resizeAspect`. The fill/zoom gravities crop the
    /// frame by an amount this function cannot see, so the bars that survive
    /// on screen are smaller than the fractions describe — insetting by the
    /// full amount would push cues *into* the picture, which is worse than
    /// the problem being fixed. Leaving those modes alone keeps today's
    /// behaviour for them.
    static func pictureRect(
        in videoRect: CGRect,
        letterbox: BakedLetterbox,
        gravity: AVLayerVideoGravity
    ) -> CGRect {
        guard gravity == .resizeAspect, letterbox.isDetected, !videoRect.isEmpty else {
            return videoRect
        }
        let top = videoRect.height * letterbox.topFraction
        let bottom = videoRect.height * letterbox.bottomFraction
        let remaining = videoRect.height - top - bottom
        guard remaining > 0 else { return videoRect }
        return CGRect(
            x: videoRect.minX,
            y: videoRect.minY + top,
            width: videoRect.width,
            height: remaining
        )
    }
}
