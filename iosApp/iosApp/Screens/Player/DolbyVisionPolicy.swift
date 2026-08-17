import Foundation

/// Pure decision logic for whether a Dolby Vision source presents as Dolby
/// Vision or falls back to its base layer, given the user's Dolby Vision
/// setting and the narrower Profile 7 HDR10 Fallback toggle. Single source
/// of truth consulted by the loopback route planner, so the precedence
/// between the two settings can never diverge. Kept free of platform state
/// so it stays unit-testable, mirroring `HDRDisplayCriteriaPolicy`.
enum DolbyVisionPolicy {
    /// Settings captured once at plan/load time. Dolby Vision off supersedes
    /// the Profile 7 fallback toggle.
    struct Snapshot: Equatable {
        let dolbyVisionEnabled: Bool
        let preferProfile7HDR10Fallback: Bool

        static let `default` = Snapshot(
            dolbyVisionEnabled: true,
            preferProfile7HDR10Fallback: false
        )
    }

    /// How a given DV profile should present for this session. The engine
    /// maps a resolution onto its own vocabulary (`LoopbackSessionSpec
    /// .VideoMode`); the policy only decides intent.
    enum Resolution: Equatable {
        /// Present as Dolby Vision, as far as the engine supports the
        /// profile.
        case dolbyVision
        /// Present the Profile 7 base layer as HDR10 because the user opted
        /// into the Profile 7 fallback while Dolby Vision itself is on.
        case profile7HDR10Fallback
        /// Present the base layer without Dolby Vision because the user
        /// turned Dolby Vision off in Settings.
        case dolbyVisionDisabled
    }

    /// Profile 5 carries IPT-encoded pixels with no HDR10-compatible base
    /// layer — playing it as HDR10 renders visibly wrong colors — so it
    /// always resolves to Dolby Vision regardless of the setting.
    static func resolution(forProfile profile: Int, snapshot: Snapshot) -> Resolution {
        switch profile {
        case 5:
            return .dolbyVision
        case 7:
            guard snapshot.dolbyVisionEnabled else { return .dolbyVisionDisabled }
            return snapshot.preferProfile7HDR10Fallback ? .profile7HDR10Fallback : .dolbyVision
        default:
            return snapshot.dolbyVisionEnabled ? .dolbyVision : .dolbyVisionDisabled
        }
    }

    /// Whether the source's Dolby Vision claim still applies to the resolved
    /// output. The Profile 7 fallback keeps the claim (shipped behavior — the
    /// toggle predates this policy); only the Dolby Vision setting clears it.
    static func claimsDolbyVisionOutput(_ resolution: Resolution) -> Bool {
        resolution != .dolbyVisionDisabled
    }
}
