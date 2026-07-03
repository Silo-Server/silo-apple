import Foundation

/// Pure decision logic for the tvOS HDMI display-criteria write the loopback
/// route performs before handing AVPlayer its item. Kept free of platform
/// guards so the mode selection and rollout gate stay unit-testable from the
/// iOS test target.
///
/// Dolby Vision criteria are long-shipped and stay ungated. Extending the
/// synchronous pre-item write to plain HDR10/HLG sources is new behavior
/// whose motivating OS account (manifest validation rejecting un-hostable
/// HDR variants) is unverified by us, so it rides behind a default-OFF
/// UserDefaults gate until it passes an on-device validation pass.
enum HDRDisplayCriteriaPolicy {
    /// Rollout gate for the non-DV HDR criteria write. Absent = disabled;
    /// DV behavior is unaffected by this key in either state.
    static let gateKey = "player.apple.hdr_display_criteria_enabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: gateKey)
    }

    /// Which display criteria the loopback route should request before
    /// creating the AVPlayerItem.
    enum CriteriaSelection: Equatable {
        case dolbyVision
        case hdr10
        case hlg
        case none
    }

    /// Maps the session's video mode plus the manifest video-range token
    /// ("PQ"/"HLG"/"SDR", see `ApplePlaybackRoutePlanner.videoRange`) to a
    /// criteria selection. DV modes always claim Dolby Vision regardless of
    /// the gate (shipped behavior); plain HEVC HDR only claims when the gate
    /// is on. H.264 is SDR — no criteria, matching today's behavior (no
    /// rate-only criteria for SDR sources in this pass).
    static func selection(
        videoMode: LoopbackSessionSpec.VideoMode,
        manifestVideoRange: String,
        hdrGateEnabled: Bool
    ) -> CriteriaSelection {
        switch videoMode {
        case .passthroughProfile5, .convertProfile7To81, .passthroughProfile8:
            return .dolbyVision
        case .passthroughHEVC:
            guard hdrGateEnabled else { return .none }
            switch manifestVideoRange {
            case "PQ": return .hdr10
            case "HLG": return .hlg
            default: return .none
            }
        case .passthroughH264:
            return .none
        }
    }

    // Poll budgets for `TVDisplayCriteria.waitForModeSwitchSettle`. The
    // renegotiation a criteria write requests only surfaces on
    // `isDisplayModeSwitchInProgress` after a short delay, so a lone
    // immediate check would race it: the wait first gives the switch up to
    // 100×10 ms to surface (bailing early when the panel already reports
    // HDR headroom), then up to 50×100 ms to finish. Whether the settled
    // mode is actually HDR is judged by post-settle EDR headroom, the only
    // public signal that separates a dynamic-range change from rate-only
    // matching.
    static let switchStartPollAttempts = 100
    static let switchStartPollIntervalMs = 10
    static let switchSettlePollAttempts = 50
    static let switchSettlePollIntervalMs = 100
    /// A panel hosting HDR reports EDR headroom above 1.0; the epsilon
    /// guards float noise on SDR panels reporting exactly 1.0.
    static let hdrHeadroomFloor: Double = 1.001

    /// Whether display criteria can survive an in-place pipeline reload
    /// (audio-track change etc.) without renegotiating the HDMI mode: same
    /// non-`.none` selection at effectively the same frame rate. Each
    /// gratuitous renegotiation costs seconds of black screen on device.
    static func shouldPreserveCriteriaAcrossReload(
        current: CriteriaSelection,
        next: CriteriaSelection,
        currentRate: Float,
        nextRate: Float
    ) -> Bool {
        guard current != .none, current == next else { return false }
        return abs(currentRate - nextRate) < 0.01
    }
}
