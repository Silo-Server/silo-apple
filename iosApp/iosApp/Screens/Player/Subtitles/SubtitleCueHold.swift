import Foundation

/// Keeps the subtitles on screen while a track that is already showing is
/// fetched again after the server changed its timing, so the new cues
/// replace the old ones without a gap. Aether clears a track's cues when it
/// starts decoding it; while this holds, the renderers ignore that empty
/// publication and keep drawing the previous cues until the new ones arrive.
///
/// Renderers read it at the moment a publication arrives, which is why it is
/// a reference and not a view property: the clearing happens in the same
/// main-actor turn that begins the hold, before any view is updated.
@MainActor
final class SubtitleCueHold {
    /// A hold whose reload never reports ends on its own.
    static let limit: Duration = .seconds(10)

    private(set) var isHolding = false
    private var sawLoad = false
    private var timeout: Task<Void, Never>?

    /// Starts holding before the track is registered again. When the engine
    /// is loading already, the reload continues that load rather than
    /// starting one.
    func begin(alreadyLoading: Bool = false) {
        isHolding = true
        sawLoad = alreadyLoading
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.limit)
            guard !Task.isCancelled else { return }
            self?.release()
        }
    }

    /// The engine started or finished loading the primary track's cues. A
    /// load that finishes after one started puts the new cues on screen.
    func loadingChanged(_ loading: Bool) {
        guard isHolding else { return }
        if loading {
            sawLoad = true
        } else if sawLoad {
            release()
        }
    }

    /// Ends the hold: the new cues are on screen, the viewer chose another
    /// track, or playback moved on.
    func release() {
        isHolding = false
        sawLoad = false
        timeout?.cancel()
        timeout = nil
    }
}
