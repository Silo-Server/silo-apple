import Foundation
import XCTest
@testable import Silo

/// Capping pipelines and transfers, starting each transfer exactly once,
/// retrying requests that never got an answer, and a transfer speed that
/// reflects what is moving now.
final class DownloadPipelineReliabilityTests: XCTestCase {
    private typealias Plan = DownloadManager.ReconnectPlan

    private func plan(
        _ status: LocalDownloadStatus,
        task: Int? = nil,
        taskBeforeRead: Int? = nil,
        live: Int? = nil,
        pausing: Bool = false,
        restartOwned: Bool = false
    ) -> Plan {
        DownloadManager.reconnectPlan(
            status: status,
            taskIdentifier: task,
            taskIdentifierBeforeRead: taskBeforeRead,
            liveTaskId: live,
            pausing: pausing,
            restartOwned: restartOwned
        )
    }

    // MARK: Queue

    func testOnlyRunningPipelinesHoldQueueSlots() {
        var owners = DownloadRestartOwners()
        _ = owners.claimPipeline("a")
        _ = owners.claimPipeline("b")
        // A retry waiting out its back-off doesn't keep the queue from moving.
        owners.retryScheduled("c", firesAt: Date())
        XCTAssertEqual(owners.pipelineCount, 2)
        XCTAssertEqual(DownloadManager.queueSlots(runningPipelines: owners.pipelineCount, transferring: 0, limit: 6).pipelines, 1)
        XCTAssertEqual(DownloadManager.queueSlots(runningPipelines: 5, transferring: 0, limit: 6).pipelines, 0)
    }

    func testTransfersStayWithinTheSimultaneousDownloadsLimit() {
        // Two transferring and two about to: the next waits for one to finish.
        XCTAssertEqual(DownloadManager.queueSlots(runningPipelines: 2, transferring: 2, limit: 4).transfers, 0)
        XCTAssertEqual(DownloadManager.queueSlots(runningPipelines: 0, transferring: 1, limit: 4).transfers, 3)
        // A whole series handed over at once is what this prevents.
        XCTAssertEqual(DownloadManager.queueSlots(runningPipelines: 0, transferring: 53, limit: 4).transfers, 0)
    }

    private func record(
        _ status: LocalDownloadStatus, task: Int? = nil, id: String = "d1", bytes: Int64 = 0, age: TimeInterval = 0
    ) -> DownloadRecord {
        DownloadRecord(
            id: id, contentId: "c1", episodeId: nil, batchId: nil, mediaFileId: "0", format: "original",
            serverStatus: "ready", localStatus: status, fileSize: 1_000, bytesDownloaded: bytes,
            mediaFilename: nil, manifestFilename: nil, posterFilename: nil, backdropFilename: nil,
            logoFilename: nil, subtitleFilenames: [:], title: "Title", subtitle: nil, type: "movie",
            seriesId: nil, seriesTitle: nil, posterThumbhash: nil, container: nil, stableIdentity: nil,
            registeredAt: Date(timeIntervalSinceReferenceDate: 1_000 - age), downloadedAt: nil, lastError: nil,
            retryCount: 0, taskIdentifier: task
        )
    }

    func testInProgressListLeadsWithWhatIsTransferring() {
        let sorted = DownloadManager.sortedByActivity([
            record(.queued, id: "queued-old", age: 50),
            record(.paused, id: "paused", age: 40),
            record(.queued, id: "queued-new", age: 1),
            record(.downloading, task: 2, id: "handed-off", age: 5),
            record(.preparing, id: "preparing", age: 30),
            record(.downloading, task: 1, id: "moving", bytes: 500, age: 10),
            record(.fetchingAssets, id: "fetching", age: 20),
        ])
        XCTAssertEqual(sorted.map(\.id),
            ["moving", "fetching", "handed-off", "preparing", "queued-old", "queued-new", "paused"])
    }

    func testRecordsLeftMidPipelineGoBackInTheQueueWhenTheStoreLoads() {
        XCTAssertTrue(DownloadManager.isOrphaned(record(.fetchingAssets)))
        // Was waiting to restart; the retry didn't survive the process.
        XCTAssertTrue(DownloadManager.isOrphaned(record(.downloading)))
        // Reconnect decides whether this task still runs.
        XCTAssertFalse(DownloadManager.isOrphaned(record(.downloading, task: 4)))
        XCTAssertFalse(DownloadManager.isOrphaned(record(.queued)))
        XCTAssertFalse(DownloadManager.isOrphaned(record(.paused)))
    }

    // MARK: Transfer failures

    func testClosingSiloFromTheAppSwitcherResumesWithoutUsingARetry() {
        XCTAssertEqual(DownloadManager.mediaFailureAction(statusCode: nil, retryCount: 4, message: "cancelled", cause: .forceQuit),
            .retry(keepResumeData: true, refreshToken: false))
    }

    func testFullStorageFailsWithoutRetrying() {
        XCTAssertEqual(DownloadManager.mediaFailureAction(statusCode: nil, retryCount: 0, message: "write", cause: .storageFull),
            .fail("storage_full"))
        XCTAssertTrue(DownloadSessionDelegate.isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)))
        XCTAssertTrue(DownloadSessionDelegate.isOutOfSpace(URLError(.cannotWriteToFile,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])))
        // A write failure alone could be anything; it gets the usual retries.
        XCTAssertFalse(DownloadSessionDelegate.isOutOfSpace(URLError(.cannotWriteToFile)))
        XCTAssertTrue(DownloadSessionDelegate.isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])))
        XCTAssertFalse(DownloadSessionDelegate.isOutOfSpace(URLError(.networkConnectionLost)))
    }

    // MARK: Restart ownership

    func testSupersededPipelineCanNeitherStartNorReleaseTheRecord() {
        var owners = DownloadRestartOwners()
        let first = owners.claimPipeline("d1")
        let second = owners.claimPipeline("d1")
        XCTAssertFalse(owners.ownsPipeline("d1", first))
        // The first pipeline finishing must not free the record from the second.
        owners.releasePipeline("d1", first)
        XCTAssertTrue(owners.ownsPipeline("d1", second))
        XCTAssertTrue(owners.ownsRestart("d1"))
        owners.releasePipeline("d1", second)
        XCTAssertFalse(owners.ownsRestart("d1"))
    }

    func testAbandonedPipelineLosesTheRecord() {
        var owners = DownloadRestartOwners()
        let token = owners.claimPipeline("d1")
        owners.abandonPipeline("d1")
        XCTAssertFalse(owners.ownsPipeline("d1", token))
        XCTAssertFalse(owners.ownsRestart("d1"))
    }

    func testScheduledRetryOwnsTheRestartUntilItEnds() {
        var owners = DownloadRestartOwners()
        owners.retryScheduled("d1", firesAt: Date())
        XCTAssertTrue(owners.ownsRestart("d1"))
        XCTAssertFalse(owners.hasPipeline("d1"))
        owners.retryEnded("d1")
        XCTAssertFalse(owners.ownsRestart("d1"))
    }

    func testBackgroundWakeWaitsForPipelinesAndRetriesDueBeforeItsDeadline() {
        let now = Date()
        var owners = DownloadRestartOwners()
        XCTAssertFalse(owners.handoffPending(by: now.addingTimeInterval(20)))
        owners.retryScheduled("d1", firesAt: now.addingTimeInterval(40))
        XCTAssertFalse(owners.handoffPending(by: now.addingTimeInterval(20)))
        owners.retryScheduled("d2", firesAt: now.addingTimeInterval(10))
        XCTAssertTrue(owners.handoffPending(by: now.addingTimeInterval(20)))
        owners.retryEnded("d2")
        _ = owners.claimPipeline("d3")
        XCTAssertTrue(owners.handoffPending(by: now))
    }

    // MARK: Reconnect

    func testPipelineStillRunningInThisProcessIsNotStartedAgain() {
        XCTAssertEqual(plan(.fetchingAssets, restartOwned: true), Plan(taskIdentifier: nil, requeue: false))
        // After a relaunch nothing owns it, so it starts again.
        XCTAssertEqual(plan(.fetchingAssets), Plan(taskIdentifier: nil, requeue: true))
    }

    func testTransferStartedDuringTheLiveTaskReadIsKept() {
        // The read can't see a task created after it began.
        XCTAssertEqual(plan(.downloading, task: 7, taskBeforeRead: nil), Plan(taskIdentifier: 7, requeue: false))
        XCTAssertEqual(plan(.downloading, task: 7, taskBeforeRead: 3, live: 3), Plan(taskIdentifier: 7, requeue: false))
    }

    func testLostTransferIsDroppedAndStartedAgain() {
        XCTAssertEqual(plan(.downloading, task: 3, taskBeforeRead: 3), Plan(taskIdentifier: nil, requeue: true))
        XCTAssertEqual(plan(.downloading, task: 3, taskBeforeRead: 3, live: 3), Plan(taskIdentifier: 3, requeue: false))
        // The live task this scope owns for the record replaces a stale id.
        XCTAssertEqual(plan(.downloading, task: 3, taskBeforeRead: 3, live: 5), Plan(taskIdentifier: 5, requeue: false))
    }

    func testRetryWaitingOutItsBackOffKeepsTheRecord() {
        XCTAssertEqual(plan(.downloading, restartOwned: true), Plan(taskIdentifier: nil, requeue: false))
        XCTAssertEqual(plan(.downloading), Plan(taskIdentifier: nil, requeue: true))
    }

    func testPauseRoundTripKeepsItsTask() {
        XCTAssertEqual(plan(.paused, task: 3, taskBeforeRead: 3, pausing: true),
            Plan(taskIdentifier: 3, requeue: false))
        XCTAssertEqual(plan(.paused, task: 3, taskBeforeRead: 3), Plan(taskIdentifier: nil, requeue: false))
        // A paused record whose task still runs keeps it, so resuming cancels
        // that task before starting another.
        XCTAssertEqual(plan(.paused, task: 3, taskBeforeRead: 3, live: 3), Plan(taskIdentifier: 3, requeue: false))
    }

    // MARK: Pipeline failures

    func testRequestWithoutAnAnswerIsRetried() {
        XCTAssertTrue(DownloadManager.isTransientPipelineFailure(HTTPError.network(underlying: URLError(.networkConnectionLost))))
        XCTAssertTrue(DownloadManager.isTransientPipelineFailure(HTTPError.network(underlying: URLError(.timedOut))))
        XCTAssertTrue(DownloadManager.isTransientPipelineFailure(URLError(.notConnectedToInternet)))
        XCTAssertFalse(DownloadManager.isTransientPipelineFailure(HTTPError.network(underlying: URLError(.cancelled))))
        XCTAssertFalse(DownloadManager.isTransientPipelineFailure(APIv2Error.httpStatus(500)))
        XCTAssertFalse(DownloadManager.isTransientPipelineFailure(HTTPError.requestIdentityChanged))
    }

    // MARK: Transfer rate

    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    private func sample(_ bytes: Int64, at seconds: TimeInterval) -> DownloadManager.TransferRateSample {
        DownloadManager.TransferRateSample(bytes: bytes, at: start.addingTimeInterval(seconds))
    }

    func testRateComesFromBytesMovedSinceTheLastSample() throws {
        let first = DownloadManager.nextTransferRate(sample: sample(0, at: 0), rate: nil,
            bytes: 10_000_000, now: start.addingTimeInterval(1))
        XCTAssertEqual(try XCTUnwrap(first.rate), 10_000_000, accuracy: 1)
        XCTAssertEqual(first.sample, sample(10_000_000, at: 1))
    }

    func testRateStartsOverAfterAGap() {
        // 60 MB over a 30 s suspension would read as 2 MB/s whatever the
        // transfer is doing now.
        let next = DownloadManager.nextTransferRate(sample: sample(0, at: 0), rate: 20_000_000,
            bytes: 60_000_000, now: start.addingTimeInterval(30))
        XCTAssertNil(next.rate)
        XCTAssertEqual(next.sample, sample(60_000_000, at: 30))
    }

    func testRateResetsWhenAResumeReportsFewerBytes() {
        let next = DownloadManager.nextTransferRate(sample: sample(50_000_000, at: 0), rate: 8_000_000,
            bytes: 1_000_000, now: start.addingTimeInterval(1))
        XCTAssertNil(next.rate)
    }

    func testCallbacksCloserThanTheSampleIntervalKeepTheWindow() {
        let next = DownloadManager.nextTransferRate(sample: sample(0, at: 0), rate: 5_000_000,
            bytes: 1_000_000, now: start.addingTimeInterval(0.1))
        XCTAssertEqual(next.sample, sample(0, at: 0))
        XCTAssertEqual(next.rate, 5_000_000)
    }

    func testRetriesResetOnlyOnceATransferPassesItsFailedPeak() {
        let mib: Int64 = 1 << 20
        // An attempt failed at 100 MiB; the next one moves 2 MiB per sample.
        var state = (retryCount: 4, furthest: 100 * mib)
        var written = 100 * mib
        for _ in 0..<4 {
            written += 2 * mib
            state = DownloadManager.recoveryProgress(retryCount: state.retryCount, furthest: state.furthest, written: written)
        }
        XCTAssertEqual(state.retryCount, 4, "8 MiB past the peak isn't recovery yet")
        XCTAssertEqual(state.furthest, 100 * mib)
        written += 2 * mib
        state = DownloadManager.recoveryProgress(retryCount: state.retryCount, furthest: state.furthest, written: written)
        XCTAssertEqual(state.retryCount, 0)
        XCTAssertEqual(state.furthest, written)
    }

    func testRestartFromZeroKeepsItsRetriesUntilItPassesThePeak() {
        let mib: Int64 = 1 << 20
        let state = DownloadManager.recoveryProgress(retryCount: 2, furthest: 500 * mib, written: 400 * mib)
        XCTAssertEqual(state.retryCount, 2)
        XCTAssertEqual(state.furthest, 500 * mib)
    }
}
