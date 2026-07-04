//
//  DisplayRefreshRateSnap.swift
//  Continuum (iOS + tvOS)
//
//  Quantizes a probed stream frame rate to the standard HDMI refresh
//  rates before it reaches `AVDisplayCriteria`. Container-probed rates
//  are frequently off-grid (a Matroska `avg_frame_rate` of 23.98, a VFR
//  average of 24.42), and an off-grid criteria rate can miss the
//  panel's mode table entirely instead of engaging the intended mode.
//
//  Pure and platform-independent so the table and the film-cadence rule
//  are unit-testable; both TVDisplayCriteria (PlayerCore route) and
//  AVPlayerBackend (loopback route) call through here.
//

import Foundation

enum DisplayRefreshRateSnap {

    /// The HDMI refresh rates tvOS display-criteria matching can target.
    static let standardRates: [Double] = [
        23.976, 24.0, 25.0, 29.97, 30.0, 48.0, 50.0, 59.94, 60.0,
    ]

    /// Half-window around a standard rate that still counts as a match.
    static let tolerance = 0.5

    /// Nearest standard rate within ±`tolerance`, or nil when the source
    /// rate is too far off-grid to make a confident mode claim.
    ///
    /// The 23.5...24.05 window always snaps to 23.976, including an exact
    /// 24.0: panels that accept 24 universally accept 23.976 (not vice
    /// versa), and content probed as "24" is nearly always 24000/1001.
    /// True-24 material on a 23.976 mode repeats one frame about every
    /// 41 s, which beats requesting a mode the panel may not have.
    static func snap(_ fps: Double) -> Double? {
        guard fps.isFinite, fps > 0 else { return nil }
        if fps >= 23.5, fps <= 24.05 {
            return 23.976
        }
        guard let nearest = standardRates.min(by: {
            abs($0 - fps) < abs($1 - fps)
        }) else { return nil }
        return abs(nearest - fps) <= tolerance ? nearest : nil
    }

    /// Convenience for the `AVDisplayCriteria` call sites, which must
    /// always pass some rate (the criteria also carries the dynamic-range
    /// claim, so "leave the panel alone" is not an option there). Unknown
    /// or off-grid rates fall back to 23.976, the dominant film cadence.
    static func snapOrFilmDefault(_ fps: Float) -> Float {
        Float(snap(Double(fps)) ?? 23.976)
    }
}
