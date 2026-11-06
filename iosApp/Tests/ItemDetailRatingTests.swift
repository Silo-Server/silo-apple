import XCTest
@testable import Silo

@MainActor
final class ItemDetailRatingTests: XCTestCase {
    private let contentId = "movie-rating-regression"

    func testFailedChangeFallsBackToTheLastConfirmedRatingNotTheLoadedOne() async throws {
        let model = ItemDetailViewModel()
        model.detail = try detail(rating: 2)

        await model.setRating(4, send: { _, _ in .applied })
        XCTAssertEqual(model.userRating, 4)

        await model.setRating(5, send: { _, _ in .failed(nil) })
        XCTAssertEqual(model.userRating, 4, "the server still has 4, not the 2 the page loaded with")
        XCTAssertEqual(model.personalStateNotice, .failed(nil))
    }

    func testChoicesDuringAWriteAreSentInOrderWithOnlyTheNewestQueued() async throws {
        let model = ItemDetailViewModel()
        model.detail = try detail(rating: nil)
        let sent = SentRatings()
        let firstStarted = expectation(description: "first write started")
        let releaseFirst = Gate()
        let send: (String, Int?) async -> PersonalStateOutcome = { _, stars in
            let count = await sent.append(stars)
            if count == 1 {
                firstStarted.fulfill()
                await releaseFirst.wait()
            }
            return .applied
        }

        let first = Task { await model.setRating(3, send: send) }
        await fulfillment(of: [firstStarted], timeout: 2)
        // Both return at once: the running write sends the newest next.
        await model.setRating(1, send: send)
        await model.setRating(5, send: send)
        XCTAssertEqual(model.userRating, 5)

        await releaseFirst.open()
        await first.value
        let values = await sent.values
        XCTAssertEqual(values, [3, 5], "1 was superseded before it was sent; 5 went last")
        XCTAssertEqual(model.userRating, 5)
    }

    private func detail(rating: Int?) throws -> ItemDetail {
        var fields: [String: Any] = ["contentId": contentId, "type": "movie", "title": "Synthetic movie"]
        fields["userRating"] = rating
        return try JSONDecoder().decode(ItemDetail.self, from: JSONSerialization.data(withJSONObject: fields))
    }
}

private actor SentRatings {
    private(set) var values: [Int?] = []

    func append(_ stars: Int?) -> Int {
        values.append(stars)
        return values.count
    }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
