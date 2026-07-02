import Foundation

/// In-place patching of search/discover results after a create or cancel,
/// so every visible card flips its ribbon immediately without a refetch
/// (the `RequestsEventBus` consumers all funnel through this).
extension RequestState {
    /// The compact card state implied by a full request record. Active
    /// requests block re-requesting; cancelled ones re-open the affordance
    /// (the server's duplicate guard only covers `outcome == active`).
    init(from record: MediaRequest) {
        switch record.outcome {
        case .active, .unknown:
            self.init(
                status: record.status,
                requestable: false,
                reason: nil,
                requestId: record.id
            )
        case .cancelled:
            self.init(status: nil, requestable: true, reason: nil, requestId: nil)
        case .declined, .failed:
            // Server allows re-requesting after decline/failure (failed rows
            // auto-clear on re-request), but keep the state visible so the
            // card explains itself; detail refetches authoritative state.
            self.init(
                status: record.status,
                requestable: true,
                reason: nil,
                requestId: record.id
            )
        }
    }
}

extension RequestMediaResult {
    /// Copy of this result with the request state implied by `record`,
    /// when the record refers to the same title. Availability is
    /// deliberately untouched — a mutation never changes what's in the
    /// library.
    func applying(_ record: MediaRequest) -> RequestMediaResult {
        guard record.mediaType == mediaType, record.tmdbId == tmdbId else { return self }
        return RequestMediaResult(
            mediaType: mediaType,
            tmdbId: tmdbId,
            title: title,
            year: year,
            overview: overview,
            posterPath: posterPath,
            backdropPath: backdropPath,
            releaseDate: releaseDate,
            voteAverage: voteAverage,
            availability: availability,
            libraryContentId: libraryContentId,
            request: RequestState(from: record)
        )
    }
}

extension Array where Element == RequestMediaResult {
    /// Patch every element that matches the mutated request.
    mutating func applyRequestUpdate(_ record: MediaRequest) {
        for index in indices {
            self[index] = self[index].applying(record)
        }
    }
}
