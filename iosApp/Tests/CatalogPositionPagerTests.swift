import XCTest
@testable import Silo

@MainActor
final class CatalogPositionPagerTests: XCTestCase {
    /// A list of `total` titles, read by position. Records each read and can
    /// hold reads open or fail them.
    @MainActor
    private final class Server {
        let total: Int
        var starts: [Int] = []
        var holdsReads = false
        var failing = false
        private var held: [CheckedContinuation<Void, Never>] = []

        init(total: Int) {
            self.total = total
        }

        func pager(retryDelay: Duration = .seconds(2)) -> CatalogPositionPager {
            CatalogPositionPager(total: total, retryDelay: retryDelay) { [self] start, limit in
                starts.append(start)
                if holdsReads {
                    await withCheckedContinuation { held.append($0) }
                }
                try Task.checkCancellation()
                if failing { throw URLError(.timedOut) }
                return Self.titles(start..<min(start + limit, total))
            }
        }

        func releaseReads() {
            holdsReads = false
            held.forEach { $0.resume() }
            held = []
        }

        static func titles(_ positions: Range<Int>) -> [BrowseItem] {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return positions.map { position in
                let json = #"{"content_id":"movie:t\#(position)","type":"movie","title":"Title \#(position)"}"#
                return try! decoder.decode(BrowseItem.self, from: Data(json.utf8))
            }
        }
    }

    private func eventually(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func testTitlesOnScreenAndThePagesAheadAreReadOnce() async {
        let server = Server(total: 1000)
        let pager = server.pager()
        var changes = 0
        pager.onChange = { changes += 1 }

        pager.show(0..<15)
        pager.show(0..<15)
        pager.show(3..<18)
        await eventually { pager.isLoaded(0..<300) }

        XCTAssertEqual(server.starts.sorted(), [0, 100, 200], "each page is read once, ahead of the scroll")
        XCTAssertEqual(pager.item(at: 17)?.contentId, "movie:t17")
        XCTAssertEqual(pager.item(at: 199)?.contentId, "movie:t199")
        XCTAssertNil(pager.item(at: 300))
        XCTAssertEqual(changes, 3)
    }

    func testTitlesAboveAJumpAreReadBeforeTheGridScrollsUpToThem() async {
        let server = Server(total: 3000)
        let pager = server.pager()

        await pager.awaitLanding(at: 1520, patience: .seconds(2))
        XCTAssertEqual(pager.item(at: 1520)?.contentId, "movie:t1520", "the jump lands on titles, not placeholders")
        XCTAssertNil(pager.item(at: 1499))

        // The grid lands with the letter's row at its top.
        pager.show(1518..<1533)
        await eventually { pager.isLoaded(1400..<1500) }
        XCTAssertEqual(pager.item(at: 1499)?.contentId, "movie:t1499", "the titles above are read while the grid rests")

        // Scrolling up keeps a page ahead of the top row.
        pager.show(1470..<1485)
        await eventually { pager.isLoaded(1300..<1400) }
        XCTAssertEqual(pager.item(at: 1399)?.contentId, "movie:t1399")
        XCTAssertEqual(Set(server.starts).count, server.starts.count, "no page is read twice")
    }

    func testAScrollThatOutrunsItsReadsGivesUpThePagesItPassed() async {
        let server = Server(total: 10_000)
        server.holdsReads = true
        let pager = server.pager()

        pager.show(0..<15)
        pager.show(2000..<2015)
        pager.show(4000..<4015)
        await eventually { server.starts.contains(4000) }
        server.releaseReads()
        await eventually { pager.isLoaded(4000..<4015) }

        XCTAssertEqual(pager.item(at: 4000)?.contentId, "movie:t4000")
        XCTAssertNil(pager.item(at: 0), "a read the grid moved on from publishes nothing")
        XCTAssertNil(pager.item(at: 2000))
    }

    func testAFailedReadIsTriedAgain() async {
        let server = Server(total: 500)
        server.failing = true
        let pager = server.pager(retryDelay: .milliseconds(20))

        pager.show(0..<15)
        await eventually { server.starts.contains(0) }
        XCTAssertNil(pager.item(at: 0))

        server.failing = false
        await eventually { pager.isLoaded(0..<15) }
        XCTAssertEqual(pager.item(at: 0)?.contentId, "movie:t0")
    }

    func testTitlesAlreadyLoadedFromTheTopAreNotReadAgain() async {
        let server = Server(total: 250)
        let pager = server.pager()
        // A whole page and part of the next: only the whole one counts.
        pager.seed(Server.titles(0..<160))
        XCTAssertEqual(pager.item(at: 99)?.contentId, "movie:t99")
        XCTAssertNil(pager.item(at: 100))

        pager.show(0..<15)
        await eventually { pager.isLoaded(0..<200) }
        XCTAssertEqual(server.starts, [100])
    }

    func testFreshTitlesFromTheTopReplaceOlderPages() async {
        let server = Server(total: 250)
        let pager = server.pager()
        pager.show(0..<15)
        await eventually { pager.isLoaded(0..<200) }
        XCTAssertEqual(pager.item(at: 0)?.title, "Title 0")

        // A reload from the top renamed the first title.
        var fresh = Server.titles(0..<100)
        fresh[0] = Server.titles(500..<501)[0]
        pager.replaceFromTop(fresh)
        XCTAssertEqual(pager.item(at: 0)?.contentId, "movie:t500")

        // Fresh titles covering only part of a page send it to be read again.
        let readsBefore = server.starts.filter { $0 == 100 }.count
        pager.replaceFromTop(Server.titles(0..<160))
        await eventually { server.starts.filter { $0 == 100 }.count > readsBefore }
        XCTAssertGreaterThan(server.starts.filter { $0 == 100 }.count, readsBefore)
    }

    func testAReadUnderWayDoesNotUndoFreshTitlesFromTheTop() async {
        let server = Server(total: 250)
        server.holdsReads = true
        let pager = server.pager()
        pager.show(0..<15)
        await eventually { server.starts.contains(0) }

        var fresh = Server.titles(0..<100)
        fresh[0] = Server.titles(500..<501)[0]
        pager.replaceFromTop(fresh)
        server.releaseReads()
        await eventually { pager.isLoaded(100..<200) }

        XCTAssertEqual(pager.item(at: 0)?.contentId, "movie:t500")
    }

    func testACancelledPagerStopsReading() async {
        let server = Server(total: 1000)
        server.holdsReads = true
        let pager = server.pager()
        var changes = 0
        pager.onChange = { changes += 1 }

        pager.show(0..<15)
        await eventually { !server.starts.isEmpty }
        pager.cancel()
        server.releaseReads()
        pager.show(500..<515)
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertNil(pager.item(at: 0))
        XCTAssertEqual(changes, 0)
        XCTAssertFalse(server.starts.contains(500))
    }
}
