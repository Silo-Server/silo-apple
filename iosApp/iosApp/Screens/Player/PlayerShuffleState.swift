import Foundation

/// The shuffle a playback belongs to, as the player last read it.
///
/// The server owns the shuffle; this tracks which pick the up-next screen
/// offers. `playedContentId` is the item that last reached its first frame:
/// advancing names it, so a retry after a lost answer or a failed load never
/// skips an item that did not play.
struct PlayerShuffleState: Equatable {
    private(set) var shuffle: APIv2Shuffle
    private(set) var playedContentId: String?
    /// The server said nothing in the scope can play any more (`409`).
    private(set) var isExhausted = false

    init(shuffle: APIv2Shuffle) {
        self.shuffle = shuffle
    }

    var id: String { shuffle.id }
    var scopeLabel: String { shuffle.scopeLabel }

    /// The pick that plays after the item on screen, or nil for the finished
    /// state: nothing can play, or the scope's only playable item is the one
    /// that just played.
    var upNext: ShuffleItem? {
        guard !isExhausted else { return nil }
        // Advanced, but `current` has not played yet (its load failed): it is
        // still what plays next.
        if let playedContentId, shuffle.current.contentId != playedContentId {
            return shuffle.current
        }
        return shuffle.upcoming
    }

    /// Pick Another replaces the server's announced `next`, so it applies
    /// only while that is the item on offer.
    var canPickAnother: Bool {
        guard let upNext else { return false }
        return upNext.contentId == shuffle.next.contentId && upNext.contentId != shuffle.current.contentId
    }

    /// The item to name when advancing: what played, or before anything has,
    /// the shuffle's current item.
    var advanceFromContentId: String {
        playedContentId ?? shuffle.current.contentId
    }

    mutating func apply(_ updated: APIv2Shuffle) {
        guard updated.id == shuffle.id else { return }
        shuffle = updated
        isExhausted = false
    }

    mutating func markPlayed(_ contentId: String) {
        playedContentId = contentId
    }

    /// A failed re-check. Only a `409` changes anything: on other errors the
    /// last pick stays on offer, and advancing re-checks it on the server.
    mutating func applyRefreshFailure(_ error: Error) {
        if ShuffleError.classify(error) == .nothingToPlay {
            isExhausted = true
        }
    }
}

/// Multi-part items (cd1, cd2, …) are separate files of one catalog item. A
/// shuffle plays every part before it moves on.
enum PlayerMultipartPolicy {
    /// The first part of `selected`'s group, at the closest resolution, when
    /// `selected` is a later part. Nil when `selected` is not a later part.
    static func firstPart(for selected: FileVersion, in versions: [FileVersion]) -> FileVersion? {
        guard let index = selected.presentationPartIndex, index > 1 else { return nil }
        return part(1, like: selected, in: versions)
    }

    /// The part after `current` in its group, or nil when `current` is the
    /// last part or not a part at all.
    static func nextPart(after current: FileVersion, in versions: [FileVersion]) -> FileVersion? {
        guard let index = current.presentationPartIndex else { return nil }
        return part(index + 1, like: current, in: versions)
    }

    private static func part(_ index: Int, like reference: FileVersion, in versions: [FileVersion]) -> FileVersion? {
        guard let group = reference.presentationGroupKey, !group.isEmpty else { return nil }
        let candidates = versions.filter {
            $0.presentationGroupKey == group && $0.presentationPartIndex == index
        }
        return candidates.first(where: { $0.resolution == reference.resolution }) ?? candidates.first
    }
}
