import Foundation

@Observable
@MainActor
final class AudioPlaybackStore {
    let player = AudioPlayerViewModel()
    var isShowingFullPlayer = false
    private var lastRequest: AudioPlaybackRequest?
    private var playbackTask: Task<Void, Never>?

    /// `preview` is what the caller already knows about the book (title,
    /// author, cover). The full player shows it immediately while the
    /// session starts instead of opening on a blank loading screen.
    func play(
        contentId: String,
        restart: Bool = false,
        startPosition: Double? = nil,
        libraryId: Int? = nil,
        preview: AudioPlaybackPreview? = nil
    ) {
        lastRequest = AudioPlaybackRequest(
            contentId: contentId,
            restart: restart,
            startPosition: startPosition,
            libraryId: libraryId,
            preview: preview
        )
        isShowingFullPlayer = true
        startLastRequest()
    }

    func retryLastRequest() {
        startLastRequest()
    }

    private func startLastRequest() {
        guard let lastRequest else { return }
        playbackTask?.cancel()
        playbackTask = Task {
            await player.start(
                contentId: lastRequest.contentId,
                restart: lastRequest.restart,
                startPosition: lastRequest.startPosition,
                libraryId: lastRequest.libraryId,
                preview: lastRequest.preview
            )
        }
    }

    func showFullPlayer() {
        guard player.hasActiveSession else { return }
        isShowingFullPlayer = true
    }

    func dismissFullPlayer() {
        isShowingFullPlayer = false
    }
}

private struct AudioPlaybackRequest {
    let contentId: String
    let restart: Bool
    let startPosition: Double?
    let libraryId: Int?
    let preview: AudioPlaybackPreview?
}

/// Book metadata a caller already has on screen, shown by the full player
/// while a new session loads.
struct AudioPlaybackPreview: Equatable {
    let contentId: String
    let title: String
    let subtitle: String?
    let posterUrl: String?
}
