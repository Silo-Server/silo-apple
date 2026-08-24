import Foundation

/// `GET /api/v1/images/capability`.
///
/// Servers that predate image-size selection return `404`, which the
/// probe treats as "feature unavailable" — see ``ImageSizeCapability``.
struct ImageSizeCapabilityResponse: Codable, Equatable {
    /// Wire-format version. Only `1` is understood; anything else is
    /// treated as unsupported rather than guessed at.
    let schemaVersion: Int
    /// The query parameter the server wants the size on. Always
    /// `image_size` for schema 1, but read from the payload rather than
    /// hardcoded so a future rename is a server-side decision.
    let param: String
    /// Size tokens the server accepts, e.g. `["small", "medium",
    /// "large", "original"]`. Sending a value that isn't in here is a
    /// `400`, so the client only sends tokens it saw advertised.
    let sizes: [String]
    /// Pixel widths per image role (`poster`, `still`, `logo`,
    /// `backdrop`) per size token. Informational — the client picks a
    /// token, not a width — but decoded so it stays available for
    /// diagnostics and future per-surface selection.
    let widths: [String: [String: Int]]
    /// Longest-edge cap the `original` variant is bounded by.
    let originalMaxWidthPx: Int
}

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
    static let requestedSize = "large"

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
        guard platformPrefersLargeImages,
              let capability,
              capability.schemaVersion == 1,
              !capability.param.isEmpty,
              capability.sizes.contains(requestedSize)
        else { return [:] }
        return [capability.param: requestedSize]
    }

    private let api: ContinuumAPI
    private let lock = NSLock()
    private var storedCapability: ImageSizeCapabilityResponse?
    private var generation = 0

    init(api: ContinuumAPI = .shared) {
        self.api = api
    }

    // MARK: - Gating convenience

    /// The decoded probe, or `nil` before it lands / after `reset()`.
    var capability: ImageSizeCapabilityResponse? {
        lock.lock()
        defer { lock.unlock() }
        return storedCapability
    }

    /// Whether this client will actually send a size on this platform.
    var isAvailable: Bool { !requestQuery.isEmpty }

    /// Query entries for the current platform and probe state. `[:]`
    /// when the probe hasn't landed, the server doesn't support the
    /// feature, or this isn't tvOS.
    var requestQuery: [String: String] {
        Self.queryEntries(
            capability: capability,
            platformPrefersLargeImages: Self.platformPrefersLargeImages
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
        guard Self.platformPrefersLargeImages else { return }
        let gen = currentGeneration()
        guard let probed = try? await api.imageSizeCapability() else { return }
        lock.lock()
        defer { lock.unlock() }
        // Discard if a reset (sign-out / profile or server switch)
        // happened while the probe was in flight.
        guard gen == generation else { return }
        storedCapability = probed
    }

    /// Drop the cached probe so capabilities don't leak across accounts
    /// or servers. Bumps `generation` first so any in-flight refresh
    /// discards its result instead of clobbering this reset.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        storedCapability = nil
    }

    // MARK: - Internals

    private func currentGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }
}
