import Foundation

/// Cached holder for the server's image-size capability probe, used to
/// decide whether catalog/section/detail requests may ask for a larger
/// baked-in image variant.
///
/// Follows the ``AICapabilities`` precedent: a `.shared` singleton
/// fetched once per session and reset on sign-out and profile/server
/// switch, with a generation counter so a probe still in flight across
/// a reset discards its result instead of repopulating the next
/// account's capabilities. A `404`/network error is cached as unavailable,
/// which ``isAvailable`` reads as "feature off", so older servers
/// degrade silently without being probed again by every artwork request.
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

    private enum ProbeState {
        case unknown
        case available(ImageSizeCapabilityResponse)
        case unavailable
    }

    private let fetchCapability: @Sendable () async throws -> ImageSizeCapabilityResponse
    private let prefersLargeImages: Bool
    private let lock = NSLock()
    private var probeState = ProbeState.unknown
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

    /// The decoded probe, or `nil` before it lands, after `reset()`, or when
    /// the latest probe established that the capability is unavailable.
    var capability: ImageSizeCapabilityResponse? {
        lock.withLock {
            guard case let .available(capability) = probeState else { return nil }
            return capability
        }
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

    /// Probe the server once per session. Failure-tolerant and idempotent: a
    /// `404` from an older server, or any transport error, leaves the feature
    /// off until ``retryUnavailable()`` runs at the next foreground edge.
    ///
    /// All platforms probe because the same payload also advertises optional
    /// artwork roles such as textless mobile posters. Platforms that do not
    /// want a larger image size still leave ``requestQuery`` empty.
    func refresh() async {
        guard let probe = lock.withLock({ () -> Probe? in
            guard case .unknown = probeState else { return nil }
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
            // newer probe superseded this one. Both successful and unavailable
            // outcomes stay cached until an explicit lifecycle retry or reset.
            guard generation == probe.generation,
                  inFlightProbe?.id == probe.id else { return }
            inFlightProbe = nil
            if let probed {
                probeState = .available(probed)
            } else {
                probeState = .unavailable
            }
        }
    }

    /// Retry a previously unavailable probe at the foreground lifecycle edge.
    /// Ordinary artwork requests call ``refresh()`` and therefore reuse the
    /// cached unavailable result instead of repeatedly probing older servers.
    func retryUnavailable() async {
        lock.withLock {
            if case .unavailable = probeState {
                probeState = .unknown
            }
        }
        await refresh()
    }

    /// Server-advertised route template for a textless portrait poster when
    /// the requested catalogue type is explicitly supported. A nil value means
    /// the server predates the contract or the item should use normal artwork.
    static func textlessPosterEndpoint(
        capability: ImageSizeCapabilityResponse?,
        for contentType: String
    ) -> String? {
        guard let textlessPoster = capability?.textlessPoster,
              !textlessPoster.endpoint.isEmpty,
              textlessPoster.supportedTypes.contains(where: {
                  $0.caseInsensitiveCompare(contentType) == .orderedSame
              })
        else { return nil }
        return textlessPoster.endpoint
    }

    func textlessPosterEndpoint(for contentType: String) -> String? {
        Self.textlessPosterEndpoint(capability: capability, for: contentType)
    }

    /// Drop the cached probe so capabilities don't leak across accounts
    /// or servers. Bumps `generation` first so any in-flight refresh
    /// discards its result instead of clobbering this reset.
    func reset() {
        let task = lock.withLock { () -> Task<ImageSizeCapabilityResponse?, Never>? in
            generation &+= 1
            probeState = .unknown
            let task = inFlightProbe?.task
            inFlightProbe = nil
            return task
        }
        task?.cancel()
    }
}
