import Foundation

@Observable
@MainActor
final class AudioPlaybackStore {
    let player = AudioPlayerViewModel()
    var isShowingFullPlayer = false
    private var lastRequest: AudioPlaybackRequest?
    private var playbackTask: Task<Void, Never>?

    func play(contentId: String, restart: Bool = false, startPosition: Double? = nil, libraryId: Int? = nil) {
        lastRequest = AudioPlaybackRequest(
            contentId: contentId,
            restart: restart,
            startPosition: startPosition,
            libraryId: libraryId
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
                libraryId: lastRequest.libraryId
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
}
