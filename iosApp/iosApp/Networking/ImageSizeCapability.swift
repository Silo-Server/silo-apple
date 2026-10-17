import Foundation
import Synchronization

/// The server's image-size capability (`GET /api/v2/images/capabilities`),
/// which says how image-bearing requests may size their artwork: per slot in
/// device pixels (`slot_width_params`), or one size for the whole response on
/// older servers. Image URLs stay opaque: the server bakes the chosen variant
/// into the URLs it returns.
///
/// The probe runs once per session and is reset on sign-out and on server or
/// profile switches. A generation counter makes a probe still in flight across
/// a reset discard its result. A failed probe leaves the feature off.
///
/// The last answer is remembered per server, so a launch sends the right size
/// immediately instead of holding its first requests behind the probe.
///
/// Not main-actor: its consumer is the `SiloAPI` actor, which reads it while
/// building a request.
final class ImageSizeCapability: Sendable {
    static let shared = ImageSizeCapability()

    /// On a server without per-slot widths, tvOS asks for `large` artwork
    /// for its 4K panel; iOS and macOS keep the server's default sizes.
    static var platformPrefersLargeImages: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }

    /// Per-server memory of the last successful probe.
    struct Memory: Sendable {
        let activeServerID: @Sendable () -> String?
        let load: @Sendable (_ serverID: String) -> ImageSizeCapabilityResponse?
        let save: @Sendable (_ serverID: String, _ capability: ImageSizeCapabilityResponse) -> Void

        static let userDefaults = Memory(
            activeServerID: { ServerRegistry.activeServerIDSnapshot },
            load: { serverID in
                UserDefaults.standard.data(forKey: key(serverID)).flatMap {
                    try? JSONDecoder().decode(ImageSizeCapabilityResponse.self, from: $0)
                }
            },
            save: { serverID, capability in
                guard let data = try? JSONEncoder().encode(capability) else { return }
                UserDefaults.standard.set(data, forKey: key(serverID))
            }
        )

        /// v1 answers were saved by a model without `slot_width_params`, so
        /// they would keep a server that takes per-slot widths on one size.
        private static func key(_ serverID: String) -> String {
            "imageSizeCapability.v2.\(serverID)"
        }
    }

    private struct Probe {
        let id: Int
        let generation: Int
        let serverID: String?
        let task: Task<ImageSizeCapabilityResponse?, Never>
    }

    private struct State {
        var probedCapability: ImageSizeCapabilityResponse?
        /// Server ID → remembered capability, read from `memory` once per server.
        var remembered: (serverID: String, capability: ImageSizeCapabilityResponse?)?
        var hasAttemptedProbe = false
        var generation = 0
        var nextProbeID = 0
        var inFlightProbe: Probe?
    }

    private let fetchCapability: @Sendable () async throws -> ImageSizeCapabilityResponse
    private let prefersLargeImages: Bool
    private let display: @Sendable () -> ArtworkDisplay
    private let memory: Memory?
    private let state = Mutex(State())

    init(
        api: SiloAPI = .shared,
        platformPrefersLargeImages: Bool = ImageSizeCapability.platformPrefersLargeImages,
        memory: Memory? = .userDefaults
    ) {
        self.prefersLargeImages = platformPrefersLargeImages
        self.display = { ArtworkDisplay.current }
        self.memory = memory
        self.fetchCapability = { try await api.imageSizeCapability() }
    }

    init(
        platformPrefersLargeImages: Bool,
        display: @escaping @Sendable () -> ArtworkDisplay = { .assumed },
        memory: Memory? = nil,
        fetchCapability: @escaping @Sendable () async throws -> ImageSizeCapabilityResponse
    ) {
        self.prefersLargeImages = platformPrefersLargeImages
        self.display = display
        self.memory = memory
        self.fetchCapability = fetchCapability
    }

    /// This session's probe result, else the active server's remembered one.
    var capability: ImageSizeCapabilityResponse? {
        state.withLock { state in
            state.probedCapability ?? remembered(in: &state)
        }
    }

    /// Entries for a read drawn on `surface`, from what is known now.
    /// `slotWidthsOnly` reads get nothing from a server without per-slot
    /// widths, rather than the one-size fallback.
    func requestQuery(for surface: ArtworkSurface, slotWidthsOnly: Bool = false) -> [String: String] {
        let display = display()
        return ImageSizeSelection.queryEntries(
            capability: capability, slots: surface.slots(on: display),
            displayScale: display.scale, prefersLargeImages: prefersLargeImages && !slotWidthsOnly
        )
    }

    /// Entries for an image-bearing read drawn on `surface`. Waits for the
    /// probe when nothing is known for the active server yet; a failed probe
    /// is not retried here.
    func requestQueryForImageRequest(_ surface: ArtworkSurface, slotWidthsOnly: Bool = false) async -> [String: String] {
        // A read that asks for no artwork, on a platform without the one-size
        // fallback, sends nothing to any server, so it never waits for the
        // probe: watch detail when playback starts on iOS and macOS.
        let sendsOneSize = prefersLargeImages && !slotWidthsOnly
        if surface.slots(on: display()) == ArtworkSlotWidths(), !sendsOneSize {
            return [:]
        }
        if capability == nil {
            await refresh(retryFailed: false)
        }
        return requestQuery(for: surface, slotWidthsOnly: slotWidthsOnly)
    }

    /// Probe the server once per session. Image-bearing requests pass
    /// `retryFailed: false`; lifecycle refreshes may retry a failed probe.
    func refresh(retryFailed: Bool = true) async {
        let serverID = memory?.activeServerID()
        guard let probe = state.withLock({ state -> Probe? in
            if state.probedCapability != nil { return nil }
            if let inFlight = state.inFlightProbe, inFlight.generation == state.generation {
                return inFlight
            }
            if state.hasAttemptedProbe && !retryFailed { return nil }
            state.hasAttemptedProbe = true
            state.nextProbeID &+= 1
            let probe = Probe(
                id: state.nextProbeID,
                generation: state.generation,
                serverID: serverID,
                task: Task { [fetchCapability] in try? await fetchCapability() }
            )
            state.inFlightProbe = probe
            return probe
        }) else { return }

        let probed = await probe.task.value
        let accepted = state.withLock { state -> Bool in
            guard state.generation == probe.generation,
                  state.inFlightProbe?.id == probe.id else { return false }
            state.inFlightProbe = nil
            state.probedCapability = probed
            return true
        }
        if accepted, let probed, let serverID = probe.serverID {
            memory?.save(serverID, probed)
        }
    }

    /// Drop this session's probe so capabilities don't leak across accounts or
    /// servers. Bumps `generation` first so an in-flight refresh discards its
    /// result.
    func reset() {
        let task = state.withLock { state -> Task<ImageSizeCapabilityResponse?, Never>? in
            state.generation &+= 1
            state.probedCapability = nil
            state.remembered = nil
            state.hasAttemptedProbe = false
            let task = state.inFlightProbe?.task
            state.inFlightProbe = nil
            return task
        }
        task?.cancel()
    }

    private func remembered(in state: inout State) -> ImageSizeCapabilityResponse? {
        guard let memory, let serverID = memory.activeServerID() else { return nil }
        if let remembered = state.remembered, remembered.serverID == serverID {
            return remembered.capability
        }
        let capability = memory.load(serverID)
        state.remembered = (serverID, capability)
        return capability
    }
}
