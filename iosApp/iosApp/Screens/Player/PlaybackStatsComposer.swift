import Foundation

/// The one place a user-visible `PlaybackStats` is assembled. Inputs arrive
/// from three unrelated producers (the AVPlayer backend, the source proxy,
/// the catalog); this type is the only code allowed to reconcile them, so a
/// row's meaning is defined exactly once.
///
/// `compose` is total and side-effect free: same inputs → same output, no
/// clock reads, no globals. It is deliberately not `@MainActor` so tests can
/// call it without an actor hop, even though in production every call happens
/// on the main thread from `PlayerViewModel`'s stats callback.
enum PlaybackStatsComposer {
    struct Inputs {
        /// Raw engine snapshot. Carries only what AVFoundation and the
        /// loopback writer/store know: never a proxy or catalog figure.
        var backend: PlaybackStats
        /// `nil` on `.avPlayerHLS` (no proxy exists there) and on the
        /// unproxied direct fallbacks (offline `file://`, proxy failed to
        /// start) — where the backend's own access-log figures stand.
        var proxy: PlaybackSourceProxyStats? = nil
        /// `nil` before a plan resolves.
        var engine: PlaybackEngineKind? = nil
        /// Catalog bitrate in bits per second (kbps * 1000 at the call site).
        var nominalFileBitrateBps: Double? = nil
        /// True origin host, used to replace the 127.0.0.1 label the backend
        /// reports behind the proxy/loopback.
        var originHost: String? = nil
    }

    static func compose(_ inputs: Inputs) -> PlaybackStats {
        var stats = inputs.backend

        // Source label: behind the proxy/loopback the backend only knows the
        // loopback host, so swap in the real origin when the plan has one.
        // (`"local"` is the backend's own token for the loopback route, not a
        // hostname, so it rides alongside the shared host predicate.)
        if let source = stats.source,
           AVPlayerBackend.isLoopbackHost(source) || source == "local",
           let originHost = inputs.originHost {
            stats.source = originHost
        }

        // Proxy-owned figures. The backend never sees these; the cache does.
        if let proxy = inputs.proxy {
            stats.sourceCacheBytes = proxy.cachedBytes
            stats.sourceCacheBudgetBytes = proxy.cacheBudgetBytes
            stats.sourceCacheHighWaterBytes = proxy.highWaterBytes
            stats.sourceCacheLowWaterBytes = proxy.lowWaterBytes
            stats.sourceCacheForwardBytes = proxy.forwardCachedBytes
            stats.sourceCacheAheadSeconds = proxy.estimatedForwardCacheAheadSeconds
            stats.sourceActiveOriginRequestCount = proxy.activeOriginRequestCount
            stats.sourceDiskSpillBytes = proxy.diskSpillBytes
            stats.sourceDiskBytesWritten = proxy.diskBytesWritten
            stats.sourceResumeCapable = proxy.resumeCapable
            stats.sourceResumeServerAdvertised = proxy.serverAdvertisesDirectStreamResume
            stats.sourceBytesServedFromCache = proxy.bytesServedFromCache
            stats.sourceOriginWaitCount = proxy.originWaitCount

            // Bytes downloaded: when a proxy exists it is the only honest
            // counter (the backend's access log measures the loopback
            // socket). Suppressed at zero so the row does not render
            // "Zero KB" before the first origin byte arrives. Without a
            // proxy the backend's access-log value stands untouched — the
            // unproxied direct fallback is exactly where those figures are
            // genuine.
            stats.networkBytesTransferred =
                proxy.originBytesTransferred > 0 ? proxy.originBytesTransferred : nil

            // Cache reuse. Both halves are byte counts over the same stream,
            // so the quotient is a true reuse factor and may legitimately
            // exceed 1 after a backward seek.
            if proxy.originBytesTransferred > 0 {
                stats.sourceCacheReuseRatio =
                    Double(proxy.bytesServedFromCache) / Double(proxy.originBytesTransferred)
            }
        }

        // Catalog figure, composer-owned. The backend never sets it.
        stats.nominalFileBitrateBps = inputs.nominalFileBitrateBps

        // Download rate: exactly one definition per route. Proxy routes use
        // the proxy's measured origin rate; when the proxy is absent (or on
        // `.avPlayerHLS`) AVPlayer talks to the origin itself and its
        // access-log observed bitrate is the honest meter.
        switch inputs.engine {
        case .siloPlayerLoopback, .avPlayerNativeDirect:
            stats.downloadRateBps = inputs.proxy?.currentOriginBitrateBps ?? stats.observedBitrateBps
        case .avPlayerHLS:
            stats.downloadRateBps = stats.observedBitrateBps
        case nil:
            stats.downloadRateBps = nil
        }

        // Stream speed (`> 1` = transport keeping ahead). On direct routes
        // the denominator is the file's nominal rate. On `.avPlayerHLS` the
        // served variant's bitrate is NOT the catalog file's — the route
        // exists for bitrate-reduction transcodes — so the stream's own
        // indicated bitrate is the only denominator that measures headroom.
        switch inputs.engine {
        case .avPlayerHLS:
            if let observed = stats.observedBitrateBps,
               let indicated = stats.indicatedBitrateBps,
               indicated > 0, observed.isFinite {
                stats.streamSpeed = observed / indicated
            }
        case .siloPlayerLoopback, .avPlayerNativeDirect:
            if let rate = stats.downloadRateBps,
               let nominal = stats.nominalFileBitrateBps,
               nominal > 0, rate.isFinite {
                stats.streamSpeed = rate / nominal
            }
        case nil:
            break
        }

        return stats
    }
}

/// Seconds of media beyond the playhead that will play with **zero network**.
/// Distinct from AVPlayer's decode buffer: on the loopback route the segments
/// already written to the local store are playable even if the origin dies,
/// while AVPlayer's own buffer is deliberately held small — a few segments
/// (`AVPlayerBackend.loopbackSteadyStateForwardBufferTarget`).
enum PlaybackRunwayPolicy {
    /// `generatedVisibleAheadSeconds` is the *visible* playlist tail — what
    /// AVPlayer is allowed to fetch right now — and is non-nil only on the
    /// loopback route, so its nilness encodes the route. The written-but-not-
    /// yet-published figure is not fetchable yet and would overstate the
    /// runway.
    static func runwaySeconds(
        playableAheadSeconds: Double,
        generatedVisibleAheadSeconds: Double?
    ) -> Double {
        max(0, max(playableAheadSeconds, generatedVisibleAheadSeconds ?? 0))
    }
}

/// Payload of `AVPlayerBackend.onBufferedAheadChange`.
struct PlaybackBufferedAhead: Equatable {
    /// Raw AVPlayer decode buffer. Diagnostics and watchdogs only.
    var playableAheadSeconds: Double
    /// User-facing figure: media that plays with zero network.
    var runwaySeconds: Double
}
