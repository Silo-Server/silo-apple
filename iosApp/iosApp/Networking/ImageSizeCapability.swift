import Foundation

/// Cached holder for the server's image-size capability probe, used to
/// decide whether catalog/section/detail requests may ask for a larger
/// baked-in image variant.
///
/// Follows the ``AICapabilities`` precedent: a `.shared` singleton
/// fetched once per session and reset on sign-out and profile/server
/// switch, with a generation counter so a probe still in flight across
/// a reset discards its result instead of repopulating the next
/// account's capabilities. A `404`/network error leaves the slot `nil`,
/// which ``isAvailable`` reads as "feature off", so older servers
/// degrade silently.
///
/// Unlike `AICapabilities` this is **not** `@MainActor @Observable`: no
/// view observes it, and its one consumer is the `ContinuumAPI` actor,
/// which needs a synchronous read while building a request. State is
/// guarded by a lock instead — same shape as `ServerRegistry`'s
/// `ActiveServerIDSnapshot`.
///
/// Image URLs stay opaque: the server bakes the chosen variant into the
/// URLs it returns and the client never rewrites them. A larger variant
/// simply arrives as a different URL, which `CachedAsyncImage` /
/// `PosterImageCache` cache independently.
final class ImageSizeCapability: @unchecked Sendable {
    static let shared = ImageSizeCapability()

    /// The query parameter name and size token this client asks for.
    /// `large` is a deliberate stop short of `original`: TV posters and
    /// stills render at w780 without paying for full-size art on every
    /// card in a shelf.
    static let requestedSize = ImageSizeSelection.requestedSize

    /// Whether this platform wants larger images at all. tvOS renders
    /// full-screen shelves and detail art on a 4K panel; iOS and macOS
    /// keep the server's default sizes, so their requests are unchanged.
    static var platformPrefersLargeImages: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }

    /// The extra query entries to merge into an image-bearing request.
    ///
    /// Pure and parameterized so both branches are testable from the
    /// iOS-hosted test target, which cannot exercise `#if os(tvOS)`.
    static func queryEntries(
        capability: ImageSizeCapabilityResponse?,
        platformPrefersLargeImages: Bool
    ) -> [String: String] {
        ImageSizeSelection.queryEntries(
            capability: capability,
            prefersLargeImages: platformPrefersLargeImages
        )
    }

    private struct Probe {
        let id: Int
        let generation: Int
        let task: Task<ImageSizeCapabilityResponse?, Never>
    }

    private let fetchCapability: @Sendable () async throws -> ImageSizeCapabilityResponse
    private let prefersLargeImages: Bool
    private let lock = NSLock()
    private var storedCapability: ImageSizeCapabilityResponse?
    private var generation = 0
    private var nextProbeID = 0
    private var inFlightProbe: Probe?

    init(
        api: ContinuumAPI = .shared,
        platformPrefersLargeImages: Bool = ImageSizeCapability.platformPrefersLargeImages
    ) {
        self.prefersLargeImages = platformPrefersLargeImages
        self.fetchCapability = { try await api.imageSizeCapability() }
    }

    init(
        platformPrefersLargeImages: Bool,
        fetchCapability: @escaping @Sendable () async throws -> ImageSizeCapabilityResponse
    ) {
        self.prefersLargeImages = platformPrefersLargeImages
        self.fetchCapability = fetchCapability
    }

    // MARK: - Gating convenience

    /// The decoded probe, or `nil` before it lands / after `reset()`.
    var capability: ImageSizeCapabilityResponse? {
        lock.withLock { storedCapability }
    }

    /// Whether this client will actually send a size on this platform.
    var isAvailable: Bool { !requestQuery.isEmpty }

    /// Query entries for the current platform and probe state. `[:]`
    /// when the probe hasn't landed, the server doesn't support the
    /// feature, or this isn't tvOS.
    var requestQuery: [String: String] {
        Self.queryEntries(
            capability: capability,
            platformPrefersLargeImages: prefersLargeImages
        )
    }

    // MARK: - Lifecycle

    /// Probe the server once per session. Failure-tolerant and
    /// idempotent: a `404` from an older server, or any transport
    /// error, leaves the feature off and is retried on the next
    /// foreground refresh.
    ///
    /// Skipped entirely on platforms that wouldn't send the parameter,
    /// so iOS and macOS don't pay for a request they can't use.
    func refresh() async {
        guard prefersLargeImages else { return }
        guard let probe = lock.withLock({ () -> Probe? in
            if storedCapability != nil { return nil }
            if let inFlightProbe, inFlightProbe.generation == generation {
                return inFlightProbe
            }
            nextProbeID &+= 1
            let probe = Probe(
                id: nextProbeID,
                generation: generation,
                task: Task { [fetchCapability] in try? await fetchCapability() }
            )
            inFlightProbe = probe
            return probe
        }) else { return }

        let probed = await probe.task.value
        lock.withLock {
            // Discard if a reset happened while the probe was in flight, or a
            // newer probe superseded this one. A nil result remains retryable
            // on the next foreground; successful results are cached.
            guard generation == probe.generation,
                  inFlightProbe?.id == probe.id else { return }
            inFlightProbe = nil
            storedCapability = probed
        }
    }

    /// Drop the cached probe so capabilities don't leak across accounts
    /// or servers. Bumps `generation` first so any in-flight refresh
    /// discards its result instead of clobbering this reset.
    func reset() {
        let task = lock.withLock { () -> Task<ImageSizeCapabilityResponse?, Never>? in
            generation &+= 1
            storedCapability = nil
            let task = inFlightProbe?.task
            inFlightProbe = nil
            return task
        }
        task?.cancel()
    }
}
