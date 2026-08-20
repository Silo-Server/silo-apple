import Foundation

enum OutputRouteFreshLoadRetryPolicy {
    static let maximumRetries = 3

    static func shouldRetry(completedRetries: Int) -> Bool {
        completedRetries < maximumRetries
    }
}

/// Centralizes runtime fallback policy so engine failures and PlayerCore stream
/// rejections are not interpreted ad hoc by the view model. This first slice
/// preserves today's behavior exactly while making the decision surface typed.
struct PlaybackRecoveryPlanner {
    struct Context {
        let reason: PlayerCore.StreamRejection
        let currentDelivery: PlaybackDeliveryStrategy
        let streamRequest: StreamRequest
        let startTime: Double
        let activePlan: PlaybackExecutionPlan?
        let hasProtocolV3Recovery: Bool
        let hevcLoopbackVideoRange: String?
    }

    struct LoopbackRequest {
        let streamRequest: StreamRequest
        let videoMode: LoopbackSessionSpec.VideoMode
        let videoRange: String
        let sourceStartTimeSeconds: Double
    }

    enum Decision {
        case terminal(message: String, diagnosticLine: String, disposeActiveCore: Bool)
        case replan(message: String, diagnosticLine: String, disposeActiveCore: Bool)
        case fallback(plan: PlaybackExecutionPlan, diagnosticLine: String)
    }

    func decide(
        context: Context,
        makeLoopbackSession: (LoopbackRequest) -> LoopbackSessionSpec?
    ) -> Decision {
        if case .h264SoftwareDecodeOutOfBounds = context.reason {
            let message = "This video's H.264 High 10 stream exceeds this device's local decoder limits."
            if context.hasProtocolV3Recovery {
                return .replan(
                    message: message,
                    diagnosticLine: "[CMP-ROUTE] H.264 High 10 runtime bounds rejection requested server replan",
                    disposeActiveCore: true
                )
            }
            return .terminal(
                message: message,
                diagnosticLine: "[CMP-ROUTE] H.264 High 10 runtime bounds rejection had no server recovery route",
                disposeActiveCore: true
            )
        }

        guard context.currentDelivery == .direct else {
            let message = "Adaptive stream rejected by PlayerCore while Apple HLS AVPlayer routing is gated off."
            return .terminal(
                message: message,
                diagnosticLine: "[CMP-ROUTE] adaptive rejection stayed on coreMedia; reason=\(String(describing: context.reason))",
                disposeActiveCore: false
            )
        }

        if case .videoToolboxBadDataH264 = context.reason {
            return .terminal(
                message: "H.264 VideoToolbox rejected the compressed samples.",
                diagnosticLine: "[CMP-ROUTE] h264 bad-data rejection stayed on compatibility route",
                disposeActiveCore: true
            )
        }

        let plan = fallbackPlan(
            for: context,
            makeLoopbackSession: makeLoopbackSession
        )
        return .fallback(
            plan: plan,
            diagnosticLine: "[CMP-AVP] rejected stream reason=\(String(describing: context.reason)) -> AVPlayer presentation route"
        )
    }

    private func fallbackPlan(
        for context: Context,
        makeLoopbackSession: (LoopbackRequest) -> LoopbackSessionSpec?
    ) -> PlaybackExecutionPlan {
        let playbackSessionId = context.activePlan?.playbackSessionId
        let requirements = context.activePlan?.requirements ?? .baseline
        let decisionTrace = context.activePlan?.decisionTrace ?? []
        let sourceMetadata = context.activePlan?.sourceMetadata ?? .unknown

        switch context.reason {
        case .h264SoftwareDecodeOutOfBounds:
            preconditionFailure("H.264 software bounds rejection is handled before fallback planning")
        case .dolbyVisionProfile5:
            return PlaybackExecutionPlan.dolbyVisionLoopback(
                streamRequest: context.streamRequest,
                startTime: context.startTime,
                rejectionReason: String(describing: context.reason),
                loopbackSession: makeLoopbackSession(LoopbackRequest(
                    streamRequest: context.streamRequest,
                    videoMode: .passthroughProfile5,
                    videoRange: "PQ",
                    sourceStartTimeSeconds: context.startTime
                )),
                routeRequirements: requirements,
                decisionTrace: decisionTrace,
                playbackSessionId: playbackSessionId,
                sourceMetadata: sourceMetadata
            )
        case .videoToolboxUnsupportedHEVCPQ:
            return hevcLoopbackPlan(
                for: context,
                videoRange: "PQ",
                playbackSessionId: playbackSessionId,
                requirements: requirements,
                decisionTrace: decisionTrace,
                sourceMetadata: sourceMetadata,
                makeLoopbackSession: makeLoopbackSession
            )
        case .videoToolboxUnsupportedHEVCHDR:
            return hevcLoopbackPlan(
                for: context,
                videoRange: "HLG",
                playbackSessionId: playbackSessionId,
                requirements: requirements,
                decisionTrace: decisionTrace,
                sourceMetadata: sourceMetadata,
                makeLoopbackSession: makeLoopbackSession
            )
        case .videoToolboxBadDataHEVC:
            return hevcLoopbackPlan(
                for: context,
                videoRange: context.hevcLoopbackVideoRange ?? "PQ",
                playbackSessionId: playbackSessionId,
                requirements: requirements,
                decisionTrace: decisionTrace,
                sourceMetadata: sourceMetadata,
                makeLoopbackSession: makeLoopbackSession
            )
        case .videoToolboxBadDataH264:
            preconditionFailure("H.264 bad-data is terminal and should be handled before fallback planning")
        }
    }

    private func hevcLoopbackPlan(
        for context: Context,
        videoRange: String,
        playbackSessionId: String?,
        requirements: PlaybackRouteRequirements,
        decisionTrace: [String],
        sourceMetadata: PlaybackSourceMetadata,
        makeLoopbackSession: (LoopbackRequest) -> LoopbackSessionSpec?
    ) -> PlaybackExecutionPlan {
        PlaybackExecutionPlan.hevcHDRLoopback(
            streamRequest: context.streamRequest,
            startTime: context.startTime,
            rejectionReason: String(describing: context.reason),
            loopbackSession: makeLoopbackSession(LoopbackRequest(
                streamRequest: context.streamRequest,
                videoMode: .passthroughHEVC,
                videoRange: videoRange,
                sourceStartTimeSeconds: context.startTime
            )),
            routeRequirements: requirements,
            decisionTrace: decisionTrace,
            playbackSessionId: playbackSessionId,
            sourceMetadata: sourceMetadata
        )
    }
}
