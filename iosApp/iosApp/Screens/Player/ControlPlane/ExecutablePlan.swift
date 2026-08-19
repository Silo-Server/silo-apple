import Foundation

/// What the engine session actually executes, valid by construction.
///
/// `PlaybackExecutionPlan` stays the *planning* artefact (route decision,
/// decision trace, claims, requirements — everything `logExecutionPlan`
/// reports). `ExecutablePlan` is the subset the load verb needs, resolved once
/// at the planning boundary so the engine session cannot be handed a loopback
/// route without a session spec: `PlayerViewModel.loadBackend`'s
/// `PlaybackEngineLoadError.missingLoopbackSession` throw becomes impossible
/// downstream of this initializer.
enum ExecutablePlan: Equatable {
    /// `AVPlayerBackend.loadDirectFile(url:headers:startTime:)`.
    case nativeDirect(NativeDirectPlan)
    /// `AVPlayerBackend.loadRemoteHLS(url:headers:startTime:)`.
    case serverHLS(ServerHLSPlan)
    /// `AVPlayerBackend.load(sessionSpec:startTime:)`.
    case localHLS(LocalHLSPlan)

    var engine: PlaybackEngineKind {
        switch self {
        case .nativeDirect: return .avPlayerNativeDirect
        case .serverHLS: return .avPlayerHLS
        case .localHLS: return .siloPlayerLoopback
        }
    }

    /// `PlaybackExecutionPlan.delivery`, carried because the control plane has
    /// a rule that reads it: `shouldAdoptBackendDuration` (PVM:3117-3128)
    /// never adopts AVPlayer's duration under a `.transcode` delivery, since a
    /// growing transcode playlist reports a manifest length that is shorter
    /// than the real one. The view model kept it in `currentDeliveryStrategy`,
    /// set at adopt from `plan.delivery` (PVM:2674); here it rides the plan so
    /// the two can never disagree.
    var delivery: PlaybackDeliveryStrategy {
        switch self {
        case .nativeDirect(let plan): return plan.delivery
        case .serverHLS(let plan): return plan.delivery
        case .localHLS(let plan): return plan.delivery
        }
    }

    /// Where the engine is told to start, i.e. today's
    /// `plan.startMode.seconds` argument to every load verb.
    var startSeconds: Double {
        switch self {
        case .nativeDirect(let plan): return plan.startSeconds
        case .serverHLS(let plan): return plan.startSeconds
        case .localHLS(let plan): return plan.startSeconds
        }
    }

    /// Resolves a planner/adapter plan into the executable subset.
    ///
    /// `request` is the stream request the load path resolved for this attempt
    /// — `plan.streamRequest` normally, or the source-proxy-rewritten request
    /// when the proxy replaced the origin. It mirrors `loadBackend`'s
    /// `let request = plan.streamRequest` so the URL/header pair stays a single
    /// decision made by the caller.
    ///
    /// - Throws: `PlaybackEngineLoadError.missingLoopbackSession`, and only
    ///   that — the loopback route without a `loopbackSession` is the one
    ///   plan shape that has no executable form (`PVM.loadBackend`).
    init(_ plan: PlaybackExecutionPlan, request: StreamRequest) throws {
        let startSeconds = plan.startMode.seconds
        switch plan.engine {
        case .avPlayerNativeDirect:
            self = .nativeDirect(
                NativeDirectPlan(
                    url: request.url,
                    headers: request.headers,
                    startSeconds: startSeconds,
                    delivery: plan.delivery
                )
            )
        case .avPlayerHLS:
            self = .serverHLS(
                ServerHLSPlan(
                    manifestURL: request.url,
                    headers: request.headers,
                    startMode: plan.startMode,
                    delivery: plan.delivery
                )
            )
        case .siloPlayerLoopback:
            guard let loopbackSession = plan.loopbackSession else {
                throw PlaybackEngineLoadError.missingLoopbackSession
            }
            self = .localHLS(
                LocalHLSPlan(
                    sessionSpec: loopbackSession,
                    startSeconds: startSeconds,
                    delivery: plan.delivery
                )
            )
        }
    }
}

/// A direct remote asset that already matches the native Apple allowlist.
struct NativeDirectPlan: Equatable {
    let url: URL
    let headers: [String: String]
    let startSeconds: Double
    var delivery: PlaybackDeliveryStrategy = .direct
}

/// A server-produced HLS manifest.
struct ServerHLSPlan: Equatable {
    let manifestURL: URL
    let headers: [String: String]
    /// Kept as the typed mode rather than a second `startSeconds` field so the
    /// two can never disagree: remux manifests are anchored server-side and
    /// always start at 0, transcode manifests seek to an absolute position.
    let startMode: PlaybackStartMode
    var delivery: PlaybackDeliveryStrategy = .direct

    var startSeconds: Double { startMode.seconds }
}

/// The in-process loopback route: a locally remuxed fMP4 served over the
/// loopback HLS server.
struct LocalHLSPlan: Equatable {
    /// Non-optional here — that is the whole point of the type.
    let sessionSpec: LoopbackSessionSpec
    let startSeconds: Double
    var delivery: PlaybackDeliveryStrategy = .direct

    /// `LoopbackSessionSpec` has no `Equatable` conformance (declaring one
    /// retroactively would change overload resolution for existing call
    /// sites), so the comparison is spelled out over its nine stored
    /// properties. `LoopbackSessionSpecCopyHelperTests`
    /// `testAssertionsCoverEveryStoredProperty` fails if a tenth is ever
    /// added, which is the signal to extend this too.
    static func == (lhs: LocalHLSPlan, rhs: LocalHLSPlan) -> Bool {
        lhs.startSeconds == rhs.startSeconds
            && lhs.delivery == rhs.delivery
            && lhs.sessionSpec.sourceURL == rhs.sessionSpec.sourceURL
            && lhs.sessionSpec.headers == rhs.sessionSpec.headers
            && lhs.sessionSpec.sourceStartTimeSeconds == rhs.sessionSpec.sourceStartTimeSeconds
            && lhs.sessionSpec.sourceBitrateBps == rhs.sessionSpec.sourceBitrateBps
            && lhs.sessionSpec.videoMode == rhs.sessionSpec.videoMode
            && lhs.sessionSpec.sourceVideoFrameRate == rhs.sessionSpec.sourceVideoFrameRate
            && lhs.sessionSpec.selectedAudio == rhs.sessionSpec.selectedAudio
            && lhs.sessionSpec.availableAudioTracks == rhs.sessionSpec.availableAudioTracks
            && lhs.sessionSpec.manifestMetadata == rhs.sessionSpec.manifestMetadata
    }
}
