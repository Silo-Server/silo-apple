import Foundation

/// Keeps the subtitles on screen while a track that is already showing is
/// fetched again after the server changed its timing, so the new cues
/// replace the old ones without a gap. Aether clears a track's cues when it
/// starts decoding it; while this holds, the renderers ignore that empty
/// publication and keep drawing the previous cues until the new ones arrive.
///
/// The primary and secondary streams are held separately, each until its own
/// load finishes, so reloading one never freezes the other. A primary hold
/// covers only the engine track the reload selects; any other track's
/// publications pass through.
///
/// Renderers read it at the moment a publication arrives, which is why it is
/// a reference and not a view property: the clearing happens in the same
/// main-actor turn that begins the hold, before any view is updated.
@MainActor
final class SubtitleCueHold {
    enum Stream: CaseIterable {
        case primary, secondary
    }

    /// A hold whose reload never reports ends on its own.
    static let limit: Duration = .seconds(10)

    private struct Hold {
        /// The engine track the reload selects; the engine publishes no
        /// secondary index, so a secondary hold has none.
        var trackID: Int?
        var sawLoad: Bool
        var timeout: Task<Void, Never>
    }

    private var holds: [Stream: Hold] = [:]

    func isHolding(_ stream: Stream) -> Bool { holds[stream] != nil }

    /// Whether an empty publication for `stream` should be ignored. A primary
    /// publication counts only while the engine shows the held track.
    func holds(_ stream: Stream, trackID: Int?) -> Bool {
        guard let hold = holds[stream] else { return false }
        return stream == .secondary || hold.trackID == trackID
    }

    /// Starts holding before the reloaded track is selected. When the engine
    /// is loading that stream already, the reload continues that load rather
    /// than starting one.
    func begin(_ stream: Stream, trackID: Int? = nil, alreadyLoading: Bool = false) {
        holds[stream]?.timeout.cancel()
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.limit)
            guard !Task.isCancelled else { return }
            self?.release(stream)
        }
        holds[stream] = Hold(trackID: trackID, sawLoad: alreadyLoading, timeout: timeout)
    }

    /// The engine started or finished loading a stream's cues. A load that
    /// finishes after one started puts the new cues on screen.
    func loadingChanged(_ loading: Bool, for stream: Stream) {
        guard let hold = holds[stream] else { return }
        if loading {
            holds[stream]?.sawLoad = true
        } else if hold.sawLoad {
            release(stream)
        }
    }

    /// Ends a stream's hold: the new cues are on screen, or the viewer chose
    /// another track for it.
    func release(_ stream: Stream) {
        holds.removeValue(forKey: stream)?.timeout.cancel()
    }

    /// Ends every hold, for when playback moves on.
    func releaseAll() {
        Stream.allCases.forEach(release)
    }
}
