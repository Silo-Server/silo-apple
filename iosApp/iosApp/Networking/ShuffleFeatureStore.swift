import Foundation

/// Cached shuffle capability, gating every Shuffle entry point.
///
/// Follows `RequestsFeatureStore`: probed once per session, reset on profile
/// and server switch, and a failed probe keeps the previous answer. Shuffle
/// is offered only when the server reports it available and lists the scope
/// kind.
///
/// macOS is excluded: its player has no up-next screen, so a shuffle could
/// neither show its next pick nor offer Pick Another or Stop shuffling.
@MainActor
@Observable
final class ShuffleFeatureStore {
    static let shared = ShuffleFeatureStore()

    static var isPlatformSupported: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }

    private(set) var capability: APIv2ShuffleCapability?

    /// Bumped on every `reset()` so a probe that finishes after a sign-out or
    /// profile switch discards its result.
    private var generation = 0

    private let api: SiloAPI

    init(api: SiloAPI = .shared) {
        self.api = api
    }

    func supports(_ kind: ShuffleScopeKind) -> Bool {
        Self.isPlatformSupported && capability?.supports(kind) == true
    }

    func refresh() async {
        guard Self.isPlatformSupported else { return }
        let gen = generation
        let probed = try? await api.shuffleCapability()
        guard gen == generation else { return }
        // A transient failure keeps an entry point that is already visible.
        if let probed { capability = probed }
    }

    func reset() {
        generation &+= 1
        capability = nil
    }
}
