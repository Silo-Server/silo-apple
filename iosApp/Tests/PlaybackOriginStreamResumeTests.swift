import Network
import XCTest
@testable import Silo

final class PlaybackOriginStreamResumeTests: XCTestCase {
    private final class ManualClock: PlaybackOriginStreamClock {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_000)
        private var pendingTicks = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return current
        }

        func sleepUntilNextWatchdogTick() async {
            await withCheckedContinuation { continuation in
                var resumeImmediately = false
                lock.lock()
                if pendingTicks > 0 {
                    pendingTicks -= 1
                    resumeImmediately = true
                } else {
                    waiters.append(continuation)
                }
                lock.unlock()
                if resumeImmediately {
                    continuation.resume()
                }
            }
        }

        func advance(by seconds: TimeInterval) {
            var waiter: CheckedContinuation<Void, Never>?
            lock.lock()
            current = current.addingTimeInterval(seconds)
            if !waiters.isEmpty {
                waiter = waiters.removeFirst()
            } else {
                pendingTicks += 1
            }
            lock.unlock()
            waiter?.resume()
        }
    }

    private final class Recorder {
        private let lock = NSLock()
        private var fillingAllowed = false
        private var stored = 0
        private var giveUps: [PlaybackOriginReconnectPolicy.EndCause] = []

        var mayFill: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return fillingAllowed
            }
            set {
                lock.lock()
                fillingAllowed = newValue
                lock.unlock()
            }
        }

        var storedBytes: Int {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        var causes: [PlaybackOriginReconnectPolicy.EndCause] {
            lock.lock()
            defer { lock.unlock() }
            return giveUps
        }

        func recordStore(_ data: Data) {
            lock.lock()
            stored += data.count
            lock.unlock()
        }

        func recordGiveUp(_ cause: PlaybackOriginReconnectPolicy.EndCause) {
            lock.lock()
            giveUps.append(cause)
            lock.unlock()
        }
    }

    private final class ProxyRecorder {
        private let lock = NSLock()
        private var interruptionReasons: [PlaybackSourceInterruptionReason] = []
        private var outageStates: [Bool] = []

        var interruptions: [PlaybackSourceInterruptionReason] {
            lock.lock()
            defer { lock.unlock() }
            return interruptionReasons
        }

        var outages: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return outageStates
        }

        func recordInterruption(_ reason: PlaybackSourceInterruptionReason) {
            lock.lock()
            interruptionReasons.append(reason)
            lock.unlock()
        }

        func recordOutage(_ active: Bool) {
            lock.lock()
            outageStates.append(active)
            lock.unlock()
        }
    }

    private final class PendingReader {
        private var session: URLSession?

        func start(url: URL, offset: Int64) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration)
            self.session = session
            var request = URLRequest(url: url)
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            session.dataTask(with: request).resume()
        }

        func cancel() {
            session?.invalidateAndCancel()
        }
    }

    private final class ExactReader {
        private let lock = NSLock()
        private var session: URLSession?
        private var received = Data()
        private var completedError: Error?
        private var completed = false

        var result: (completed: Bool, data: Data, error: Error?) {
            lock.lock()
            defer { lock.unlock() }
            return (completed, received, completedError)
        }

        func start(url: URL, offset: Int64) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration)
            self.session = session
            var request = URLRequest(url: url)
            request.setValue("bytes=\(offset)-\(offset)", forHTTPHeaderField: "Range")
            session.dataTask(with: request) { [weak self] data, _, error in
                guard let self else { return }
                lock.lock()
                received = data ?? Data()
                completedError = error
                completed = true
                lock.unlock()
            }.resume()
        }

        func cancel() {
            session?.invalidateAndCancel()
        }
    }

    private final class StartCompletion {
        private let lock = NSLock()
        private var completed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !completed else { return false }
            completed = true
            return true
        }
    }

    private final class EntityValidator {
        private let lock = NSLock()
        private var storedValue: String?

        var value: String? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storedValue
            }
            set {
                lock.lock()
                storedValue = newValue
                lock.unlock()
            }
        }
    }

    private final class ChunkRecorder {
        private let lock = NSLock()
        private var storedCount = 0
        private var failureCauses: [PlaybackOriginReconnectPolicy.EndCause] = []

        var stores: Int {
            lock.lock()
            defer { lock.unlock() }
            return storedCount
        }

        var causes: [PlaybackOriginReconnectPolicy.EndCause] {
            lock.lock()
            defer { lock.unlock() }
            return failureCauses
        }

        func recordStore() {
            lock.lock()
            storedCount += 1
            lock.unlock()
        }

        func recordFailure(_ cause: PlaybackOriginReconnectPolicy.EndCause) {
            lock.lock()
            failureCauses.append(cause)
            lock.unlock()
        }
    }

    private final class StubOrigin {
        enum ReopenBehavior {
            case partialSameEntity
            case partialChangedEntity
            case partialWeakChangedEntity
            case partialMissingETag
            case alwaysChangedEntity
            case invalidContentRange
            case fullChangedEntity
            case changedEntityChunkFirst
            case fullChangedEntityWithDelayedChunk
            case delayedInitialWindow
            case fullResponseAfterWeakETag
            case partialChangedAfterWeakETag
            case alwaysFullChangedEntity
        }

        struct Request: Equatable {
            let range: String?
            let ifRange: String?
        }

        private let totalBytes: Int64 = 64 * 1024 * 1024
        private let behavior: ReopenBehavior
        private let listener: NWListener
        private let queue = DispatchQueue(label: "origin-stream-resume-stub")
        private let lock = NSLock()
        private var connections: [ObjectIdentifier: NWConnection] = [:]
        private var requests: [Request] = []
        private(set) var port: UInt16 = 0

        init(behavior: ReopenBehavior) throws {
            self.behavior = behavior
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: parameters)
        }

        var url: URL {
            URL(string: "http://127.0.0.1:\(port)/entity.bin")!
        }

        func observedRequests() -> [Request] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }

        func start() async throws {
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            port = try await withCheckedThrowingContinuation { continuation in
                let completion = StartCompletion()
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if let port = self.listener.port, completion.claim() {
                            continuation.resume(returning: port.rawValue)
                        }
                    case .failed(let error):
                        if completion.claim() {
                            continuation.resume(throwing: error)
                        }
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
            }
        }

        func stop() {
            listener.cancel()
            lock.lock()
            let open = Array(connections.values)
            connections.removeAll()
            lock.unlock()
            open.forEach { $0.cancel() }
        }

        private func accept(_ connection: NWConnection) {
            lock.lock()
            connections[ObjectIdentifier(connection)] = connection
            lock.unlock()
            connection.start(queue: queue)
            receiveRequest(connection, buffered: Data())
        }

        private func receiveRequest(_ connection: NWConnection, buffered: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                [weak self] data, _, _, error in
                guard let self, error == nil else { return }
                var requestData = buffered
                if let data {
                    requestData.append(data)
                }
                guard let end = requestData.range(of: Data("\r\n\r\n".utf8)) else {
                    self.receiveRequest(connection, buffered: requestData)
                    return
                }
                let request = String(
                    data: requestData[..<end.lowerBound],
                    encoding: .utf8
                ) ?? ""
                self.respond(connection, request: request)
            }
        }

        private func respond(_ connection: NWConnection, request: String) {
            let range = header("range", in: request)
            let ifRange = header("if-range", in: request)
            lock.lock()
            requests.append(Request(range: range, ifRange: ifRange))
            let requestNumber = requests.count
            lock.unlock()

            let offset = range.flatMap { value in
                value.range(of: "bytes=").flatMap { marker in
                    Int64(value[marker.upperBound...].split(separator: "-")[0])
                } ?? 0
            } ?? 0
            if behavior == .delayedInitialWindow {
                let byteCount = 64 * 1024
                let isWindow = requestNumber == 1
                let end = isWindow
                    ? totalBytes - 1
                    : offset + Int64(byteCount) - 1
                let contentLength = isWindow
                    ? totalBytes - offset
                    : Int64(byteCount)
                let responseETag = requestNumber == 2
                    ? "\"entity-v1\""
                    : "\"entity-v2\""
                let responseHeader = [
                    "HTTP/1.1 206 Partial Content",
                    "Content-Range: bytes \(offset)-\(end)/\(totalBytes)",
                    "Content-Length: \(contentLength)",
                    "ETag: \(responseETag)",
                    "Content-Type: application/octet-stream",
                    "Connection: close",
                    "",
                    ""
                ].joined(separator: "\r\n")
                let sendResponse = {
                    connection.send(
                        content: Data(responseHeader.utf8),
                        completion: .contentProcessed { error in
                            guard error == nil else { return }
                            let body = Data(repeating: 0xBC, count: byteCount)
                            if isWindow {
                                // Keep the initial streaming response open so
                                // only the early chunk exercises the retry.
                                connection.send(content: body, completion: .idempotent)
                            } else {
                                connection.send(
                                    content: body,
                                    contentContext: .finalMessage,
                                    isComplete: true,
                                    completion: .idempotent
                                )
                            }
                        }
                    )
                }
                if isWindow {
                    queue.asyncAfter(
                        deadline: .now() + .milliseconds(250),
                        execute: sendResponse
                    )
                } else {
                    sendResponse()
                }
                return
            }
            if (behavior == .changedEntityChunkFirst
                || behavior == .fullChangedEntityWithDelayedChunk),
               requestNumber == 2 {
                let delayedByteCount = 64 * 1024
                let end = offset + Int64(delayedByteCount) - 1
                let delayMilliseconds = behavior == .changedEntityChunkFirst ? 0 : 500
                let header = [
                    "HTTP/1.1 206 Partial Content",
                    "Content-Range: bytes \(offset)-\(end)/\(totalBytes)",
                    "Content-Length: \(delayedByteCount)",
                    "ETag: \"entity-v2\"",
                    "Content-Type: application/octet-stream",
                    "Connection: close",
                    "",
                    ""
                ].joined(separator: "\r\n")
                connection.send(content: Data(header.utf8), completion: .contentProcessed {
                    [weak self] error in
                    guard let self, error == nil else { return }
                    self.queue.asyncAfter(
                        deadline: .now() + .milliseconds(delayMilliseconds)
                    ) {
                        connection.send(
                            content: Data(repeating: 0xCD, count: delayedByteCount),
                            contentContext: .finalMessage,
                            isComplete: true,
                            completion: .idempotent
                        )
                    }
                })
                return
            }
            let fullResponse: Bool
            switch behavior {
            case .fullChangedEntity, .fullResponseAfterWeakETag:
                fullResponse = requestNumber > 1
            case .alwaysFullChangedEntity:
                fullResponse = true
            case .changedEntityChunkFirst,
                 .fullChangedEntityWithDelayedChunk,
                 .delayedInitialWindow:
                fullResponse = requestNumber > 2
            case .partialSameEntity,
                 .partialChangedEntity,
                 .partialWeakChangedEntity,
                 .partialMissingETag,
                 .partialChangedAfterWeakETag,
                 .alwaysChangedEntity,
                 .invalidContentRange:
                fullResponse = false
            }
            if fullResponse {
                let responseETag = behavior == .fullChangedEntity
                    || behavior == .changedEntityChunkFirst
                    || behavior == .fullChangedEntityWithDelayedChunk
                    || behavior == .alwaysFullChangedEntity
                    ? "\"entity-v2\""
                    : "W/\"entity-v1\""
                let header = [
                    "HTTP/1.1 200 OK",
                    "Content-Length: \(totalBytes)",
                    "ETag: \(responseETag)",
                    "Content-Type: application/octet-stream",
                    "Connection: close",
                    "",
                    ""
                ].joined(separator: "\r\n")
                connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in
                    connection.send(
                        content: Data(repeating: 0xEE, count: 64 * 1024),
                        completion: .idempotent
                    )
                })
                return
            }

            let end = totalBytes - 1
            let responseETag: String?
            if behavior == .fullResponseAfterWeakETag {
                responseETag = "W/\"entity-v1\""
            } else if behavior == .partialChangedAfterWeakETag {
                responseETag = requestNumber == 1
                    ? "W/\"entity-v1\""
                    : "\"entity-v2\""
            } else if behavior == .alwaysChangedEntity {
                responseETag = "\"entity-v2\""
            } else if behavior == .partialChangedEntity, requestNumber > 1 {
                responseETag = "\"entity-v2\""
            } else if behavior == .partialWeakChangedEntity, requestNumber > 1 {
                responseETag = "W/\"entity-v2\""
            } else if behavior == .partialMissingETag, requestNumber > 1 {
                responseETag = nil
            } else {
                responseETag = "\"entity-v1\""
            }
            let contentRange = behavior == .invalidContentRange && requestNumber > 1
                ? "bytes invalid"
                : "bytes \(offset)-\(end)/\(totalBytes)"
            var headerLines = [
                "HTTP/1.1 206 Partial Content",
                "Content-Range: \(contentRange)",
                "Content-Length: \(totalBytes - offset)",
                "Content-Type: application/octet-stream",
                "Connection: close",
                "",
                ""
            ]
            if let responseETag {
                headerLines.insert("ETag: \(responseETag)", at: 3)
            }
            let header = headerLines.joined(separator: "\r\n")
            connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
                guard let self, error == nil else { return }
                self.sendBody(connection, remaining: self.totalBytes - offset)
            })
        }

        private func header(_ name: String, in request: String) -> String? {
            for line in request.split(separator: "\r\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                if key == name {
                    return line[line.index(after: colon)...]
                        .trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        }

        private func sendBody(_ connection: NWConnection, remaining: Int64) {
            guard remaining > 0 else {
                connection.send(
                    content: nil,
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .idempotent
                )
                return
            }
            let count = Int(min(remaining, 64 * 1024))
            connection.send(
                content: Data(repeating: 0xAB, count: count),
                completion: .contentProcessed { [weak self] error in
                    guard error == nil else { return }
                    self?.sendBody(connection, remaining: remaining - Int64(count))
                }
            )
        }
    }

    private func makeStream(
        origin: StubOrigin,
        recorder: Recorder,
        clock: ManualClock,
        resumeCapable: Bool,
        startOffset: Int64 = 0,
        initialEntityETag: String? = nil
    ) -> PlaybackOriginStream {
        PlaybackOriginStream(
            originURL: origin.url,
            originHeaders: [:],
            startOffset: startOffset,
            demandOrder: 1,
            callbacks: PlaybackOriginStream.Callbacks(
                didStore: { _, _ in },
                didReceiveResponse: { _, _, _ in },
                didDetectSessionMissing: { _ in },
                didFinish: { _ in },
                didGiveUp: { _, cause, _ in
                    recorder.recordGiveUp(cause)
                },
                mayContinueFilling: { _, _, _ in
                    recorder.mayFill
                },
                cachedAheadBytes: {
                    Int64(recorder.storedBytes)
                },
                nextMissingByte: { $0 },
                store: { _, data, _ in
                    recorder.recordStore(data)
                }
            ),
            resumeCapable: resumeCapable,
            initialEntityETag: initialEntityETag,
            clock: clock
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if predicate() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    func testParkDetachesAndDemandReopensExactRangeWithIfRange() async throws {
        let originalGrace = PlaybackOriginStreamPolicy.detachAfterSeconds
        PlaybackOriginStreamPolicy.detachAfterSeconds = 1
        defer { PlaybackOriginStreamPolicy.detachAfterSeconds = originalGrace }

        let origin = try StubOrigin(behavior: .partialSameEntity)
        try await origin.start()
        defer { origin.stop() }
        let clock = ManualClock()
        let recorder = Recorder()
        let stream = makeStream(
            origin: origin,
            recorder: recorder,
            clock: clock,
            resumeCapable: true
        )
        defer { stream.cancel() }

        stream.start()
        let parked = await waitUntil { stream.diagnosticsSnapshot().parked }
        XCTAssertTrue(parked)
        let parkedState = stream.diagnosticsSnapshot()
        XCTAssertGreaterThan(parkedState.writeCursor, 0)

        clock.advance(by: 2)
        let detached = await waitUntil { stream.diagnosticsSnapshot().detached }
        XCTAssertTrue(detached)
        let detachedState = stream.diagnosticsSnapshot()
        XCTAssertEqual(detachedState.writeCursor, parkedState.writeCursor)
        XCTAssertEqual(detachedState.unproductiveStreak, 0)
        XCTAssertTrue(recorder.causes.isEmpty)

        recorder.mayFill = true
        stream.noteDemand(offset: detachedState.writeCursor, order: 2)
        let reopened = await waitUntil { origin.observedRequests().count >= 2 }
        XCTAssertTrue(reopened)
        let requests = origin.observedRequests()
        XCTAssertEqual(requests[1].range, "bytes=\(detachedState.writeCursor)-")
        XCTAssertEqual(requests[1].ifRange, "\"entity-v1\"")
        XCTAssertTrue(recorder.causes.isEmpty)
    }

    func testDeliberateDetachDoesNotAdvanceFailureState() async throws {
        let originalGrace = PlaybackOriginStreamPolicy.detachAfterSeconds
        PlaybackOriginStreamPolicy.detachAfterSeconds = 1
        defer { PlaybackOriginStreamPolicy.detachAfterSeconds = originalGrace }

        let origin = try StubOrigin(behavior: .partialSameEntity)
        try await origin.start()
        defer { origin.stop() }
        let clock = ManualClock()
        let recorder = Recorder()
        let stream = makeStream(
            origin: origin,
            recorder: recorder,
            clock: clock,
            resumeCapable: true
        )
        defer { stream.cancel() }

        stream.start()
        let parked = await waitUntil { stream.diagnosticsSnapshot().parked }
        XCTAssertTrue(parked)
        clock.advance(by: 2)
        let detached = await waitUntil { stream.diagnosticsSnapshot().detached }
        XCTAssertTrue(detached)
        XCTAssertEqual(stream.diagnosticsSnapshot().unproductiveStreak, 0)
        XCTAssertTrue(recorder.causes.isEmpty)
        XCTAssertEqual(origin.observedRequests().count, 1)
    }

    func testResumeIncapableStreamRemainsParkedPastGrace() async throws {
        let originalGrace = PlaybackOriginStreamPolicy.detachAfterSeconds
        PlaybackOriginStreamPolicy.detachAfterSeconds = 1
        defer { PlaybackOriginStreamPolicy.detachAfterSeconds = originalGrace }

        let origin = try StubOrigin(behavior: .partialSameEntity)
        try await origin.start()
        defer { origin.stop() }
        let clock = ManualClock()
        let recorder = Recorder()
        let stream = makeStream(
            origin: origin,
            recorder: recorder,
            clock: clock,
            resumeCapable: false
        )
        defer { stream.cancel() }

        stream.start()
        let parked = await waitUntil { stream.diagnosticsSnapshot().parked }
        XCTAssertTrue(parked)
        clock.advance(by: 120)
        try? await Task.sleep(for: .milliseconds(50))
        let state = stream.diagnosticsSnapshot()
        XCTAssertTrue(state.parked)
        XCTAssertFalse(state.detached)
        XCTAssertEqual(state.unproductiveStreak, 0)
        XCTAssertEqual(origin.observedRequests().count, 1)
        XCTAssertTrue(recorder.causes.isEmpty)
    }

    func testIfRangeFullResponseGivesUpWithoutAppendingChangedEntity() async throws {
        let originalGrace = PlaybackOriginStreamPolicy.detachAfterSeconds
        PlaybackOriginStreamPolicy.detachAfterSeconds = 1
        defer { PlaybackOriginStreamPolicy.detachAfterSeconds = originalGrace }

        let origin = try StubOrigin(behavior: .fullChangedEntity)
        try await origin.start()
        defer { origin.stop() }
        let clock = ManualClock()
        let recorder = Recorder()
        let stream = makeStream(
            origin: origin,
            recorder: recorder,
            clock: clock,
            resumeCapable: true
        )
        defer { stream.cancel() }

        stream.start()
        let parked = await waitUntil { stream.diagnosticsSnapshot().parked }
        XCTAssertTrue(parked)
        clock.advance(by: 2)
        let detached = await waitUntil { stream.diagnosticsSnapshot().detached }
        XCTAssertTrue(detached)
        let cursor = stream.diagnosticsSnapshot().writeCursor
        let storedBeforeReopen = recorder.storedBytes

        recorder.mayFill = true
        stream.noteDemand(offset: cursor, order: 2)
        let gaveUp = await waitUntil { recorder.causes == [.entityChanged] }
        XCTAssertTrue(gaveUp)
        XCTAssertEqual(recorder.storedBytes, storedBeforeReopen)
        XCTAssertTrue(stream.isFinished)
        let requests = origin.observedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].range, "bytes=\(cursor)-")
        XCTAssertEqual(requests[1].ifRange, "\"entity-v1\"")
    }

    func testEntityChangeEscalatesThroughProxyWithoutOutageOrCacheAppend() async throws {
        let originalGrace = PlaybackOriginStreamPolicy.detachAfterSeconds
        PlaybackOriginStreamPolicy.detachAfterSeconds = 1
        defer { PlaybackOriginStreamPolicy.detachAfterSeconds = originalGrace }

        let origin = try StubOrigin(behavior: .fullChangedEntity)
        try await origin.start()
        defer { origin.stop() }
        let clock = ManualClock()
        let recorder = ProxyRecorder()
        let cache = PlaybackSourceCache(maxBytes: 256 * 1024, diskSpillEnabled: false)
        let pin = cache.pin(0...(64 * 1024 * 1024 - 1))
        defer { cache.unpin(pin) }
        let proxy = PlaybackSourceProxy(
            originURL: origin.url,
            originHeaders: [:],
            cache: cache,
            onPlaybackSourceInterrupted: { recorder.recordInterruption($0) },
            onOriginOutageChanged: { recorder.recordOutage($0) },
            resumeCapable: true,
            originStreamClock: clock
        )
        try await proxy.start()
        defer { proxy.stop() }
        proxy.startPrefetch(at: 0)

        let parked = await waitUntil { proxy.originStreamDiagnostics()?.parked == true }
        XCTAssertTrue(parked)
        clock.advance(by: 2)
        let detached = await waitUntil { proxy.originStreamDiagnostics()?.detached == true }
        XCTAssertTrue(detached)
        let cursor = try XCTUnwrap(proxy.originStreamDiagnostics()).writeCursor
        let transferredBeforeReopen = cache.stats().originBytesTransferred
        XCTAssertFalse(cache.contains(offset: cursor))

        let reader = PendingReader()
        reader.start(url: try XCTUnwrap(proxy.localURL), offset: cursor)
        defer { reader.cancel() }

        let interrupted = await waitUntil {
            recorder.interruptions == [.sourceEntityChanged]
        }
        XCTAssertTrue(interrupted)
        XCTAssertEqual(recorder.outages, [])
        XCTAssertEqual(cache.stats().originBytesTransferred, transferredBeforeReopen)
        XCTAssertFalse(cache.contains(offset: cursor))
        let requests = origin.observedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].range, "bytes=\(cursor)-")
        XCTAssertEqual(requests[1].ifRange, "\"entity-v1\"")
    }

    func testEntityChangeCancelsInFlightChunkBeforeItCanContaminateCache() async throws {
        let originalGrace = PlaybackOriginStreamPolicy.detachAfterSeconds
        PlaybackOriginStreamPolicy.detachAfterSeconds = 1
        defer { PlaybackOriginStreamPolicy.detachAfterSeconds = originalGrace }

        let origin = try StubOrigin(behavior: .fullChangedEntityWithDelayedChunk)
        try await origin.start()
        defer { origin.stop() }
        let clock = ManualClock()
        let recorder = ProxyRecorder()
        let cache = PlaybackSourceCache(maxBytes: 256 * 1024, diskSpillEnabled: false)
        let pin = cache.pin(0...(64 * 1024 * 1024 - 1))
        defer { cache.unpin(pin) }
        let proxy = PlaybackSourceProxy(
            originURL: origin.url,
            originHeaders: [:],
            cache: cache,
            onPlaybackSourceInterrupted: { recorder.recordInterruption($0) },
            resumeCapable: true,
            originStreamClock: clock
        )
        try await proxy.start()
        defer { proxy.stop() }
        proxy.startPrefetch(at: 0)

        let parked = await waitUntil { proxy.originStreamDiagnostics()?.parked == true }
        XCTAssertTrue(parked)
        clock.advance(by: 2)
        let detached = await waitUntil { proxy.originStreamDiagnostics()?.detached == true }
        XCTAssertTrue(detached)
        let cursor = try XCTUnwrap(proxy.originStreamDiagnostics()).writeCursor
        let farOffset = cursor + PlaybackOriginRoutingPolicy.rideThroughBytes + 1
        let transferredBeforeChunk = cache.stats().originBytesTransferred

        let chunkReader = PendingReader()
        chunkReader.start(url: try XCTUnwrap(proxy.localURL), offset: farOffset)
        defer { chunkReader.cancel() }
        let chunkStarted = await waitUntil { origin.observedRequests().count >= 2 }
        XCTAssertTrue(chunkStarted)
        XCTAssertEqual(origin.observedRequests()[1].range?.hasPrefix("bytes=\(farOffset)-"), true)

        let resumeReader = PendingReader()
        resumeReader.start(url: try XCTUnwrap(proxy.localURL), offset: cursor)
        defer { resumeReader.cancel() }
        let interrupted = await waitUntil {
            recorder.interruptions == [.sourceEntityChanged]
        }
        XCTAssertTrue(interrupted)

        try? await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(cache.contains(offset: farOffset))
        XCTAssertEqual(cache.stats().originBytesTransferred, transferredBeforeChunk)
        XCTAssertEqual(origin.observedRequests().count, 3)
    }

    func testChangedEntityChunkInvalidatesResourceBeforeCachingBytes() async throws {
        let origin = try StubOrigin(behavior: .changedEntityChunkFirst)
        try await origin.start()
        defer { origin.stop() }
        let recorder = ProxyRecorder()
        let cache = PlaybackSourceCache(maxBytes: 256 * 1024, diskSpillEnabled: false)
        let pin = cache.pin(0...(64 * 1024 * 1024 - 1))
        defer { cache.unpin(pin) }
        let proxy = PlaybackSourceProxy(
            originURL: origin.url,
            originHeaders: [:],
            cache: cache,
            onPlaybackSourceInterrupted: { recorder.recordInterruption($0) },
            resumeCapable: true
        )
        try await proxy.start()
        defer { proxy.stop() }
        proxy.startPrefetch(at: 0)

        let parked = await waitUntil { proxy.originStreamDiagnostics()?.parked == true }
        XCTAssertTrue(parked)
        let cursor = try XCTUnwrap(proxy.originStreamDiagnostics()).writeCursor
        let farOffset = cursor + PlaybackOriginRoutingPolicy.rideThroughBytes + 1
        let transferredBeforeChunk = cache.stats().originBytesTransferred

        let chunkReader = PendingReader()
        chunkReader.start(url: try XCTUnwrap(proxy.localURL), offset: farOffset)
        defer { chunkReader.cancel() }
        let interrupted = await waitUntil {
            recorder.interruptions == [.sourceEntityChanged]
        }
        XCTAssertTrue(interrupted)

        XCTAssertFalse(cache.contains(offset: farOffset))
        XCTAssertEqual(cache.stats().originBytesTransferred, transferredBeforeChunk)
        let requests = origin.observedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].ifRange, "\"entity-v1\"")
    }

    func testEarlyChunkWaitsForWindowEntityBeforeCaching() async throws {
        let origin = try StubOrigin(behavior: .delayedInitialWindow)
        try await origin.start()
        defer { origin.stop() }
        let recorder = ProxyRecorder()
        let cache = PlaybackSourceCache(maxBytes: 256 * 1024, diskSpillEnabled: false)
        let pin = cache.pin(0...(64 * 1024 * 1024 - 1))
        defer { cache.unpin(pin) }
        let proxy = PlaybackSourceProxy(
            originURL: origin.url,
            originHeaders: [:],
            cache: cache,
            onPlaybackSourceInterrupted: { recorder.recordInterruption($0) },
            resumeCapable: true
        )
        try await proxy.start()
        defer { proxy.stop() }
        proxy.startPrefetch(at: 0)
        let windowStarted = await waitUntil { origin.observedRequests().count == 1 }
        XCTAssertTrue(windowStarted)

        let farOffset = PlaybackOriginRoutingPolicy.rideThroughBytes * 2
        let reader = PendingReader()
        reader.start(url: try XCTUnwrap(proxy.localURL), offset: farOffset)
        defer { reader.cancel() }

        let firstChunkFinished = await waitUntil {
            origin.observedRequests().count >= 2
        }
        XCTAssertTrue(firstChunkFinished)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(cache.contains(offset: farOffset))

        let retriedWithWindowEntity = await waitUntil {
            origin.observedRequests().contains {
                $0.range?.hasPrefix("bytes=\(farOffset)-") == true
                    && $0.ifRange == "\"entity-v2\""
            }
        }
        XCTAssertTrue(retriedWithWindowEntity)
        let chunkRequests = origin.observedRequests().filter {
            $0.range?.hasPrefix("bytes=\(farOffset)-") == true
        }
        XCTAssertEqual(chunkRequests.count, 2)
        XCTAssertNil(chunkRequests[0].ifRange)
        XCTAssertEqual(chunkRequests[1].ifRange, "\"entity-v2\"")
        let cached = await waitUntil { cache.contains(offset: farOffset) }
        XCTAssertTrue(cached)
        XCTAssertTrue(recorder.interruptions.isEmpty)
    }

    func testValidatedChunkCompletesWaitingProxyRead() async throws {
        let origin = try StubOrigin(behavior: .partialSameEntity)
        try await origin.start()
        defer { origin.stop() }
        let recorder = ProxyRecorder()
        let cache = PlaybackSourceCache(maxBytes: 256 * 1024, diskSpillEnabled: false)
        let pin = cache.pin(0...(64 * 1024 * 1024 - 1))
        defer { cache.unpin(pin) }
        let proxy = PlaybackSourceProxy(
            originURL: origin.url,
            originHeaders: [:],
            cache: cache,
            onPlaybackSourceInterrupted: { recorder.recordInterruption($0) },
            resumeCapable: true
        )
        try await proxy.start()
        defer { proxy.stop() }
        proxy.startPrefetch(at: 0)

        let parked = await waitUntil { proxy.originStreamDiagnostics()?.parked == true }
        XCTAssertTrue(parked)
        let cursor = try XCTUnwrap(proxy.originStreamDiagnostics()).writeCursor
        let farOffset = cursor + PlaybackOriginRoutingPolicy.rideThroughBytes + 1
        let reader = ExactReader()
        reader.start(url: try XCTUnwrap(proxy.localURL), offset: farOffset)
        defer { reader.cancel() }

        let completed = await waitUntil {
            reader.result.completed
        }
        XCTAssertTrue(completed)
        XCTAssertNil(reader.result.error)
        XCTAssertEqual(reader.result.data.count, 1)
        XCTAssertTrue(cache.contains(offset: farOffset))
        XCTAssertTrue(recorder.interruptions.isEmpty)
        let chunkRequests = origin.observedRequests().filter {
            $0.range?.hasPrefix("bytes=\(farOffset)-") == true
        }
        XCTAssertEqual(chunkRequests.count, 1)
        XCTAssertEqual(chunkRequests[0].ifRange, "\"entity-v1\"")
    }

    func testChunkFetcherUsesValidatorLearnedAfterConstruction() async throws {
        let origin = try StubOrigin(behavior: .partialSameEntity)
        try await origin.start()
        defer { origin.stop() }
        let validator = EntityValidator()
        let fetcher = PlaybackOriginChunkFetcher(
            originURL: origin.url,
            originHeaders: [:],
            entityETagProvider: { validator.value },
            callbacks: PlaybackOriginChunkFetcher.Callbacks(
                store: { _, _, _, _ in nil },
                didStore: { _ in },
                didReceiveResponse: { _ in },
                didDetectSessionMissing: {},
                didFail: { _, _, _ in },
                beginRequest: {},
                endRequest: {}
            )
        )
        defer { fetcher.cancel() }

        let totalBytes: Int64 = 64 * 1024 * 1024
        let unvalidatedOffset = totalBytes - 2
        let validatedOffset = totalBytes - 1
        fetcher.ensureFetch(
            covering: unvalidatedOffset,
            totalLength: unvalidatedOffset + 1
        )
        validator.value = "\"entity-v1\""
        fetcher.ensureFetch(
            covering: validatedOffset,
            totalLength: validatedOffset + 1
        )

        let received = await waitUntil { origin.observedRequests().count == 2 }
        XCTAssertTrue(received)
        let requests = origin.observedRequests()
        let unvalidatedRequest = requests.first {
            $0.range == "bytes=\(unvalidatedOffset)-\(unvalidatedOffset)"
        }
        let validatedRequest = requests.first {
            $0.range == "bytes=\(validatedOffset)-\(validatedOffset)"
        }
        XCTAssertNil(unvalidatedRequest?.ifRange)
        XCTAssertEqual(validatedRequest?.ifRange, "\"entity-v1\"")
    }

    func testResumeCapableChunkFetcherRejectsResponsesWithoutEstablishedValidator() async throws {
        let origin = try StubOrigin(behavior: .partialSameEntity)
        try await origin.start()
        defer { origin.stop() }
        let recorder = ChunkRecorder()
        let fetcher = PlaybackOriginChunkFetcher(
            originURL: origin.url,
            originHeaders: [:],
            requiresEntityValidation: true,
            callbacks: PlaybackOriginChunkFetcher.Callbacks(
                store: { _, _, _, _ in
                    recorder.recordStore()
                    return nil
                },
                didStore: { _ in },
                didReceiveResponse: { _ in },
                didDetectSessionMissing: {},
                didFail: { _, cause, _ in
                    recorder.recordFailure(cause)
                },
                beginRequest: {},
                endRequest: {}
            )
        )
        defer { fetcher.cancel() }

        let offset: Int64 = 8 * 1024 * 1024
        fetcher.ensureFetch(
            covering: offset,
            totalLength: offset + 1
        )

        let rejected = await waitUntil {
            recorder.causes == [.rangeIgnored]
        }
        XCTAssertTrue(rejected)
        XCTAssertEqual(recorder.stores, 0)
        XCTAssertEqual(origin.observedRequests().count, 2)
        XCTAssertTrue(origin.observedRequests().allSatisfy { $0.ifRange == nil })
    }

    func testWeakETagIsNotSentAsIfRangeOrMisclassifiedAsEntityChange() async throws {
        let originalGrace = PlaybackOriginStreamPolicy.detachAfterSeconds
        PlaybackOriginStreamPolicy.detachAfterSeconds = 1
        defer { PlaybackOriginStreamPolicy.detachAfterSeconds = originalGrace }

        let origin = try StubOrigin(behavior: .fullResponseAfterWeakETag)
        try await origin.start()
        defer { origin.stop() }
        let clock = ManualClock()
        let recorder = Recorder()
        let stream = makeStream(
            origin: origin,
            recorder: recorder,
            clock: clock,
            resumeCapable: true
        )
        defer { stream.cancel() }

        stream.start()
        let parked = await waitUntil { stream.diagnosticsSnapshot().parked }
        XCTAssertTrue(parked)
        clock.advance(by: 2)
        let detached = await waitUntil { stream.diagnosticsSnapshot().detached }
        XCTAssertTrue(detached)
        let cursor = stream.diagnosticsSnapshot().writeCursor

        recorder.mayFill = true
        stream.noteDemand(offset: cursor, order: 2)
        let gaveUp = await waitUntil { recorder.causes == [.rangeIgnored] }
        XCTAssertTrue(gaveUp)
        let requests = origin.observedRequests()
        XCTAssertEqual(requests.count, 3, "rangeIgnored keeps its existing one-retry cap")
        XCTAssertEqual(requests[1].range, "bytes=\(cursor)-")
        for request in requests.dropFirst() {
            XCTAssertNil(request.ifRange)
        }
        XCTAssertEqual(recorder.causes, [.rangeIgnored])
    }

    func testDetachResumeRejectsPartialResponseWhenInitialETagWasWeak() async throws {
        let originalGrace = PlaybackOriginStreamPolicy.detachAfterSeconds
        PlaybackOriginStreamPolicy.detachAfterSeconds = 1
        defer { PlaybackOriginStreamPolicy.detachAfterSeconds = originalGrace }

        let origin = try StubOrigin(behavior: .partialChangedAfterWeakETag)
        try await origin.start()
        defer { origin.stop() }
        let clock = ManualClock()
        let recorder = Recorder()
        let stream = makeStream(
            origin: origin,
            recorder: recorder,
            clock: clock,
            resumeCapable: true
        )
        defer { stream.cancel() }

        stream.start()
        let parked = await waitUntil { stream.diagnosticsSnapshot().parked }
        XCTAssertTrue(parked)
        clock.advance(by: 2)
        let detached = await waitUntil { stream.diagnosticsSnapshot().detached }
        XCTAssertTrue(detached)
        let cursor = stream.diagnosticsSnapshot().writeCursor
        let storedBeforeReopen = recorder.storedBytes

        recorder.mayFill = true
        stream.noteDemand(offset: cursor, order: 2)

        let gaveUp = await waitUntil { recorder.causes == [.rangeIgnored] }
        XCTAssertTrue(gaveUp)
        XCTAssertEqual(recorder.storedBytes, storedBeforeReopen)
        XCTAssertEqual(origin.observedRequests().count, 3)
        XCTAssertTrue(origin.observedRequests().allSatisfy { $0.ifRange == nil })
    }

    func testDetachResumeRejectsChangedETagOnPartialResponse() async throws {
        let originalGrace = PlaybackOriginStreamPolicy.detachAfterSeconds
        PlaybackOriginStreamPolicy.detachAfterSeconds = 1
        defer { PlaybackOriginStreamPolicy.detachAfterSeconds = originalGrace }

        let origin = try StubOrigin(behavior: .partialChangedEntity)
        try await origin.start()
        defer { origin.stop() }
        let clock = ManualClock()
        let recorder = Recorder()
        let stream = makeStream(
            origin: origin,
            recorder: recorder,
            clock: clock,
            resumeCapable: true
        )
        defer { stream.cancel() }

        stream.start()
        let parked = await waitUntil { stream.diagnosticsSnapshot().parked }
        XCTAssertTrue(parked)
        clock.advance(by: 2)
        let detached = await waitUntil { stream.diagnosticsSnapshot().detached }
        XCTAssertTrue(detached)
        let cursor = stream.diagnosticsSnapshot().writeCursor
        let storedBeforeReopen = recorder.storedBytes

        recorder.mayFill = true
        stream.noteDemand(offset: cursor, order: 2)

        let gaveUp = await waitUntil { recorder.causes == [.entityChanged] }
        XCTAssertTrue(gaveUp)
        XCTAssertEqual(recorder.storedBytes, storedBeforeReopen)
        XCTAssertEqual(origin.observedRequests().count, 2)
    }

    func testReplacementWindowStartsBoundToEstablishedEntity() async throws {
        let origin = try StubOrigin(behavior: .alwaysChangedEntity)
        try await origin.start()
        defer { origin.stop() }
        let clock = ManualClock()
        let recorder = Recorder()
        let startOffset: Int64 = 2 * 1024 * 1024
        let stream = makeStream(
            origin: origin,
            recorder: recorder,
            clock: clock,
            resumeCapable: true,
            startOffset: startOffset,
            initialEntityETag: "\"entity-v1\""
        )
        defer { stream.cancel() }

        stream.start()

        let rejected = await waitUntil {
            recorder.causes == [.entityChanged]
        }
        XCTAssertTrue(rejected)
        XCTAssertEqual(recorder.storedBytes, 0)
        let requests = origin.observedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].range, "bytes=\(startOffset)-")
        XCTAssertEqual(requests[0].ifRange, "\"entity-v1\"")
    }

    func testReplacementWindowAtByteZeroRejectsChangedFullResponse() async throws {
        let origin = try StubOrigin(behavior: .alwaysFullChangedEntity)
        try await origin.start()
        defer { origin.stop() }
        let clock = ManualClock()
        let recorder = Recorder()
        let stream = makeStream(
            origin: origin,
            recorder: recorder,
            clock: clock,
            resumeCapable: true,
            initialEntityETag: "\"entity-v1\""
        )
        defer { stream.cancel() }

        stream.start()

        let rejected = await waitUntil {
            recorder.causes == [.entityChanged]
        }
        XCTAssertTrue(rejected)
        XCTAssertEqual(recorder.storedBytes, 0)
        let requests = origin.observedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].range, "bytes=0-")
        XCTAssertNil(requests[0].ifRange)
    }

    func testDetachResumeRejectsWeakConflictingETagOnPartialResponse() async throws {
        let originalGrace = PlaybackOriginStreamPolicy.detachAfterSeconds
        PlaybackOriginStreamPolicy.detachAfterSeconds = 1
        defer { PlaybackOriginStreamPolicy.detachAfterSeconds = originalGrace }

        let origin = try StubOrigin(behavior: .partialWeakChangedEntity)
        try await origin.start()
        defer { origin.stop() }
        let clock = ManualClock()
        let recorder = Recorder()
        let stream = makeStream(
            origin: origin,
            recorder: recorder,
            clock: clock,
            resumeCapable: true
        )
        defer { stream.cancel() }

        stream.start()
        let parked = await waitUntil { stream.diagnosticsSnapshot().parked }
        XCTAssertTrue(parked)
        clock.advance(by: 2)
        let detached = await waitUntil { stream.diagnosticsSnapshot().detached }
        XCTAssertTrue(detached)
        let cursor = stream.diagnosticsSnapshot().writeCursor
        let storedBeforeReopen = recorder.storedBytes

        recorder.mayFill = true
        stream.noteDemand(offset: cursor, order: 2)

        let gaveUp = await waitUntil { recorder.causes == [.rangeIgnored] }
        XCTAssertTrue(gaveUp)
        XCTAssertEqual(recorder.storedBytes, storedBeforeReopen)
        XCTAssertEqual(origin.observedRequests().count, 3)
    }

    func testDetachResumeTreatsMissingETagAsUnverifiable() async throws {
        let originalGrace = PlaybackOriginStreamPolicy.detachAfterSeconds
        PlaybackOriginStreamPolicy.detachAfterSeconds = 1
        defer { PlaybackOriginStreamPolicy.detachAfterSeconds = originalGrace }

        let origin = try StubOrigin(behavior: .partialMissingETag)
        try await origin.start()
        defer { origin.stop() }
        let clock = ManualClock()
        let recorder = Recorder()
        let stream = makeStream(
            origin: origin,
            recorder: recorder,
            clock: clock,
            resumeCapable: true
        )
        defer { stream.cancel() }

        stream.start()
        let parked = await waitUntil { stream.diagnosticsSnapshot().parked }
        XCTAssertTrue(parked)
        clock.advance(by: 2)
        let detached = await waitUntil { stream.diagnosticsSnapshot().detached }
        XCTAssertTrue(detached)
        let cursor = stream.diagnosticsSnapshot().writeCursor
        let storedBeforeReopen = recorder.storedBytes

        recorder.mayFill = true
        stream.noteDemand(offset: cursor, order: 2)

        let gaveUp = await waitUntil { recorder.causes == [.rangeIgnored] }
        XCTAssertTrue(gaveUp)
        XCTAssertEqual(recorder.storedBytes, storedBeforeReopen)
        XCTAssertEqual(origin.observedRequests().count, 3)
    }

    func testDetachResumeRejectsInvalidContentRange() async throws {
        let originalGrace = PlaybackOriginStreamPolicy.detachAfterSeconds
        PlaybackOriginStreamPolicy.detachAfterSeconds = 1
        defer { PlaybackOriginStreamPolicy.detachAfterSeconds = originalGrace }

        let origin = try StubOrigin(behavior: .invalidContentRange)
        try await origin.start()
        defer { origin.stop() }
        let clock = ManualClock()
        let recorder = Recorder()
        let stream = makeStream(
            origin: origin,
            recorder: recorder,
            clock: clock,
            resumeCapable: true
        )
        defer { stream.cancel() }

        stream.start()
        let parked = await waitUntil { stream.diagnosticsSnapshot().parked }
        XCTAssertTrue(parked)
        clock.advance(by: 2)
        let detached = await waitUntil { stream.diagnosticsSnapshot().detached }
        XCTAssertTrue(detached)
        let cursor = stream.diagnosticsSnapshot().writeCursor
        let storedBeforeReopen = recorder.storedBytes

        recorder.mayFill = true
        stream.noteDemand(offset: cursor, order: 2)

        let gaveUp = await waitUntil { recorder.causes == [.rangeIgnored] }
        XCTAssertTrue(gaveUp)
        XCTAssertEqual(recorder.storedBytes, storedBeforeReopen)
        XCTAssertEqual(origin.observedRequests().count, 3)
    }
}
