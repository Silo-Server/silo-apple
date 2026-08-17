//
//  VideoDisplayRect.swift
//  Silo (iOS + tvOS + macOS)
//
//  Describes where the displayed video sits inside a full-frame subtitle
//  overlay, so the libass subtitle overlay can be sized to the video rather
//  than the full view (which would make text tiny in landscape and huge in
//  portrait). The player surface supplies the video rect from
//  `AVPlayerLayer.videoRect`.

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
