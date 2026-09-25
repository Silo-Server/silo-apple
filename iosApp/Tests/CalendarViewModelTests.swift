import XCTest
@testable import Silo

@MainActor
final class CalendarViewModelTests: XCTestCase {
    func testRefreshKeepsTheWeekOnScreenWhileRevalidating() async throws {
        clearCalendarCache()
        defer { clearCalendarCache() }
        let stub = CalendarFetchStub()
        let model = CalendarViewModel(fetchWeek: { try await stub.fetch($0, $1, $2, $3) })
        stub.enqueue(.success(makeResponse(for: model, contentIds: ["a-1", "a-2"])))
        await model.load()
        XCTAssertEqual(contentIds(model.days), ["a-1", "a-2"])

        let started = expectation(description: "refresh fetch started")
        stub.enqueue(.suspend(started))
        let refresh = Task { await model.refresh() }
        await fulfillment(of: [started], timeout: 2)

        XCTAssertEqual(contentIds(model.days), ["a-1", "a-2"])
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.error)

        stub.resume(with: .success(makeResponse(for: model, contentIds: ["b-1"])))
        await refresh.value

        XCTAssertEqual(contentIds(model.days), ["b-1"])
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.error)
        let cached: CalendarResponse? = ResponseCache.shared.get(cacheKey(for: model))
        XCTAssertEqual(cached.map { contentIds($0.events) }, ["b-1"])
        XCTAssertEqual(stub.calls.count, 2)
        XCTAssertEqual(
            stub.calls.last,
            CalendarFetchStub.Call(
                start: model.week.startString,
                end: model.week.endString,
                filter: model.filter.rawValue
            )
        )
    }

    func testFailedRefreshKeepsTheWeekWithoutAnError() async throws {
        clearCalendarCache()
        defer { clearCalendarCache() }
        let stub = CalendarFetchStub()
        let model = CalendarViewModel(fetchWeek: { try await stub.fetch($0, $1, $2, $3) })
        stub.enqueue(.success(makeResponse(for: model, contentIds: ["a-1", "a-2"])))
        await model.load()

        stub.enqueue(.failure(URLError(.notConnectedToInternet)))
        await model.refresh()

        XCTAssertEqual(contentIds(model.days), ["a-1", "a-2"])
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isLoading)
    }

    func testFailedLoadWithNothingToShowStillReportsTheError() async throws {
        clearCalendarCache()
        defer { clearCalendarCache() }
        let stub = CalendarFetchStub()
        let model = CalendarViewModel(fetchWeek: { try await stub.fetch($0, $1, $2, $3) })

        stub.enqueue(.failure(URLError(.notConnectedToInternet)))
        await model.load()

        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.days.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    // MARK: - Helpers

    private func clearCalendarCache() {
        ResponseCache.shared.removeAll(withPrefix: "calendar:")
    }

    private func cacheKey(for model: CalendarViewModel) -> String {
        CacheKey.calendarWeek(model.week.startString, filter: model.filter.rawValue)
    }

    private func contentIds(_ days: [CalendarDay]) -> [String] {
        days.flatMap(\.items).map(\.contentId)
    }

    private func makeResponse(for model: CalendarViewModel, contentIds: [String]) -> CalendarResponse {
        CalendarResponse(events: [
            CalendarDay(
                date: model.week.startString,
                items: contentIds.map { contentId in
                    CalendarEvent(
                        contentId: contentId,
                        type: "movie",
                        title: "Title \(contentId)",
                        episodeTitle: nil,
                        seriesId: nil,
                        seasonNumber: nil,
                        episodeNumber: nil,
                        airDate: nil,
                        airTime: nil,
                        airAt: nil,
                        airTimezone: nil,
                        localAirDate: nil,
                        posterUrl: nil,
                        posterThumbhash: nil,
                        watched: nil,
                        badges: nil
                    )
                }
            ),
        ])
    }
}

/// Scripted stand-in for `SiloAPI.calendarEvents`. Each call pops the next
/// step; `.suspend` parks the call until `resume(with:)`.
@MainActor
private final class CalendarFetchStub {
    enum Step {
        case success(CalendarResponse)
        case failure(Error)
        case suspend(XCTestExpectation)
    }

    struct Call: Equatable {
        let start: String
        let end: String
        let filter: String
    }

    private var steps: [Step] = []
    private(set) var calls: [Call] = []
    private var parked: CheckedContinuation<CalendarResponse, Error>?

    func enqueue(_ step: Step) {
        steps.append(step)
    }

    func fetch(
        _ start: String, _ end: String, _ filter: String, _ timezone: String
    ) async throws -> CalendarResponse {
        calls.append(Call(start: start, end: end, filter: filter))
        guard !steps.isEmpty else {
            XCTFail("Unexpected calendar fetch for \(start)...\(end) \(filter)")
            throw URLError(.badServerResponse)
        }
        switch steps.removeFirst() {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .suspend(let started):
            return try await withCheckedThrowingContinuation { continuation in
                // Store first, then signal, so the test can never resume
                // before the continuation exists.
                parked = continuation
                started.fulfill()
            }
        }
    }

    func resume(with result: Result<CalendarResponse, Error>) {
        let continuation = parked
        parked = nil
        continuation?.resume(with: result)
    }
}
