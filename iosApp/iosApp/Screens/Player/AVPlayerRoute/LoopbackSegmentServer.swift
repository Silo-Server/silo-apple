//
//  LoopbackSegmentServer.swift
//  Continuum (iOS + tvOS) — Dolby Vision Profile 5 AVPlayer route
//
//  Tiny HTTP server bound to 127.0.0.1:<random port>. Serves the HLS playlist
//  and fMP4 segments that `LoopbackSegmentWriter` writes to a session-scoped temp
//  directory, so AVPlayer can consume them via a URL it accepts natively.
//
//  Uses `Network.framework`'s `NWListener` so we pull in zero dependencies.
//  Rendered on a dedicated `.userInitiated` dispatch queue — the HLS manifest
//  is hit once per segment boundary, segment requests are a few KB each, so
//  latency pressure is near-zero.
//
//  Supports GET and HEAD with `Accept-Ranges: bytes` and RFC 7233 byte-range
//  parsing on GET. AVPlayer's HLS engine usually fetches segments whole, but
//  HEAD and Range are the right defaults for any client that probes the
//  loopback (and removes a class of "AVPlayer hung trying to range-fetch
//  init.mp4" bug reports). 404 on miss, 416 on un-satisfiable range,
//  405 on other methods.
//
//  ATS (App Transport Security) requires `NSAllowsLocalNetworking=true` in
//  Info.plist. Without it, AVPlayer fails loading the playlist with
//  NSURLErrorAppTransportSecurityRequiresSecureConnection.

import Foundation
import Network
import OSLog

final class LoopbackSegmentServer {
    private static let startupRequestLogLimit = 80
    private static let responseChunkBytes = 256 * 1024
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "LoopbackSegmentServer"
    )

    let rootDirectory: URL?
    private let segmentStore: LoopbackSegmentStore?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.continuum.dv.hlsserver", qos: .userInitiated)
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let lock = NSLock()
    private var requestLogCount = 0
    /// Method/path/status/bytes/range tuples already emitted to the access
    /// log. Suppresses AVPlayer's identical retry probes — the first request
    /// for each unique signature is logged, repeats are silent.
    private var loggedRequestSignatures: Set<String> = []
    /// Total HTTP requests parsed this session (playlist, init, segments —
    /// including misses: a consumer requesting anything is still alive).
    /// Monotonic. The `AVPlayerBackend` startup watchdog compares snapshots
    /// to distinguish a slow-but-fetching AVPlayer from one whose loader
    /// pipeline died and stopped requesting entirely.
    private var totalRequestCount: UInt64 = 0

    var servedRequestCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return totalRequestCount
    }

    /// Port the OS assigned us. Only valid once `start()` has returned
    /// successfully (the listener is bound and in `.ready` state).
    private(set) var port: UInt16 = 0

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        self.segmentStore = nil
    }

    init(segmentStore: LoopbackSegmentStore) {
        self.rootDirectory = nil
        self.segmentStore = segmentStore
    }

    /// Starts the listener on a random high port and suspends until the
    /// listener either becomes `.ready` (returning the assigned port) or
    /// fails (throwing). Replaces a previous semaphore-based wait that could
    /// block the main actor for up to 2 s on cold-start. The 2 s bind budget
    /// is preserved as an internal timeout.
    func start() async throws {
        let listener: NWListener
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback),
                port: .any
            )
            listener = try NWListener(using: params)
        } catch {
            throw LoopbackSegmentServerError.listenerInitFailed(error)
        }
        self.listener = listener

        do {
            let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
                // Coordinate the three resume paths (stateUpdateHandler.ready,
                // stateUpdateHandler.failed, bind-timeout). `resumeOnce` makes
                // sure exactly one of them owns the continuation. Marked
                // `@Sendable` because the network and timer queues each invoke
                // it from their own contexts.
                let resumedBox = ResumeBox()
                let resumeOnce: @Sendable (Result<UInt16, Error>) -> Void = { result in
                    guard resumedBox.markResumed() else { return }
                    continuation.resume(with: result)
                }

                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let p = listener.port {
                            self.port = p.rawValue
                            resumeOnce(.success(p.rawValue))
                        }
                    case .failed(let err):
                        resumeOnce(.failure(LoopbackSegmentServerError.listenerFailed(err)))
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: queue)

                // Local listeners come up in milliseconds; anything longer is
                // a fatal config error (sandbox / entitlement). Treat the
                // timeout as distinct from a genuine bind failure so the
                // caller sees a specific error.
                queue.asyncAfter(deadline: .now() + 2) {
                    resumeOnce(.failure(LoopbackSegmentServerError.bindTimeout))
                }
            }
            let serving = self.rootDirectory?.path ?? "memory-store-\(self.segmentStore?.generation ?? 0)"
            Self.logger.info("LoopbackSegmentServer listening on 127.0.0.1:\(port) serving \(serving, privacy: .public)")
        } catch {
            listener.cancel()
            self.listener = nil
            throw error
        }
    }

    /// Single-shot, thread-safe resume gate for `start()`'s continuation.
    /// `markResumed` returns `true` only the first time it is called.
    private final class ResumeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        func markResumed() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        let open = connections
        connections.removeAll()
        lock.unlock()
        for (_, c) in open {
            c.cancel()
        }
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        lock.lock()
        connections[id] = connection
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.drop(id: id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func drop(id: ObjectIdentifier) {
        lock.lock()
        connections.removeValue(forKey: id)
        lock.unlock()
    }

    /// Accumulate bytes until we've seen the end of the HTTP request headers
    /// (CRLFCRLF). We don't support request bodies — GETs only.
    private func receive(on connection: NWConnection, accumulated: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            var buffer = accumulated
            if let data, !data.isEmpty {
                buffer.append(data)
            }

            if let range = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                let headerBytes = buffer[..<range.lowerBound]
                let raw = String(data: headerBytes, encoding: .utf8) ?? ""
                self.handleRequest(raw, on: connection)
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            // Guard against runaway input.
            if buffer.count > 32 * 1024 {
                self.respondError(413, "Payload Too Large", on: connection)
                return
            }
            self.receive(on: connection, accumulated: buffer)
        }
    }

    private func handleRequest(_ raw: String, on connection: NWConnection) {
        let lines = raw.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let first = lines.first else {
            respondError(400, "Bad Request", on: connection)
            return
        }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else {
            respondError(400, "Bad Request", on: connection)
            return
        }
        let method = String(parts[0])
        let rawPath = String(parts[1])
        let path = rawPath.split(separator: "?").first.map(String.init) ?? rawPath
        lock.lock()
        totalRequestCount &+= 1
        lock.unlock()

        var rangeHeader: String?
        for line in lines.dropFirst() {
            // Header lines are `Name: Value` (case-insensitive name).
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            if name == "range" {
                let valueStart = line.index(after: colon)
                rangeHeader = line[valueStart...].trimmingCharacters(in: .whitespaces)
                break
            }
        }

        switch method {
        case "GET":
            respondWithFile(at: path, method: .get, range: rangeHeader, on: connection)
        case "HEAD":
            respondWithFile(at: path, method: .head, range: nil, on: connection)
        default:
            respondError(405, "Method Not Allowed", on: connection)
        }
    }

    private enum HTTPMethod {
        case get
        case head
    }

    private func respondWithFile(
        at requestPath: String,
        method: HTTPMethod,
        range rangeHeader: String?,
        on connection: NWConnection
    ) {
        let started = CFAbsoluteTimeGetCurrent()
        // Directory-traversal guard: require the normalized path to remain
        // inside rootDirectory. Anything with ".." or leading "/" outside
        // the root gets rejected.
        let trimmed = requestPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.contains("..") {
            logRequest(method: method, path: requestPath, status: 403, bytes: 0, range: rangeHeader, started: started)
            respondError(403, "Forbidden", on: connection)
            return
        }
        if let segmentStore {
            respondWithStoreResource(
                path: trimmed,
                method: method,
                range: rangeHeader,
                started: started,
                on: connection,
                store: segmentStore
            )
            return
        }
        guard let rootDirectory else {
            logRequest(method: method, path: requestPath, status: 404, bytes: 0, range: rangeHeader, started: started)
            respondError(404, "Not Found", on: connection)
            return
        }
        let target = rootDirectory.appendingPathComponent(trimmed)
        guard target.path.hasPrefix(rootDirectory.path) else {
            logRequest(method: method, path: requestPath, status: 403, bytes: 0, range: rangeHeader, started: started)
            respondError(403, "Forbidden", on: connection)
            return
        }
        guard let data = try? Data(contentsOf: target) else {
            logRequest(method: method, path: requestPath, status: 404, bytes: 0, range: rangeHeader, started: started)
            respondError(404, "Not Found", on: connection)
            return
        }
        let mime = mimeType(for: target.pathExtension.lowercased())
        respondWithData(
            data,
            mime: mime,
            requestPath: requestPath,
            method: method,
            range: rangeHeader,
            started: started,
            on: connection
        )
    }

    /// VOD serving mode (loopback-primary plan, 1e): resolves a segment the
    /// store doesn't hold — the backend requests a coalesced producer restart
    /// and waits, bounded, for the bytes. Runs off the server's queue so a
    /// slow resolution never stalls playlist/init requests.
    var vodSegmentMissResolver: ((Int) -> LoopbackSegmentStore.ResourceResult)?

    private func respondWithStoreResource(
        path: String,
        method: HTTPMethod,
        range rangeHeader: String?,
        started: CFAbsoluteTime,
        on connection: NWConnection,
        store: LoopbackSegmentStore
    ) {
        if let index = LoopbackSegmentStore.segmentIndex(fromName: path) {
            store.declareVODTarget(index)
        }
        switch store.resource(path: path) {
        case .missing, .gone:
            if let resolver = vodSegmentMissResolver,
               let index = LoopbackSegmentStore.segmentIndex(fromName: path) {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self else { return }
                    switch resolver(index) {
                    case .found(let resource):
                        self.respondWithResource(
                            resource,
                            requestPath: path,
                            method: method,
                            range: rangeHeader,
                            started: started,
                            on: connection
                        )
                    case .missing, .gone:
                        self.logRequest(method: method, path: path, status: 404, bytes: 0, range: rangeHeader, started: started)
                        self.respondError(404, "Not Found", on: connection)
                    }
                }
                return
            }
            logRequest(method: method, path: path, status: 404, bytes: 0, range: rangeHeader, started: started)
            respondError(404, "Not Found", on: connection)
        case .found(let resource):
            respondWithResource(
                resource,
                requestPath: path,
                method: method,
                range: rangeHeader,
                started: started,
                on: connection
            )
        }
    }

    private func respondWithResource(
        _ resource: LoopbackSegmentStore.Resource,
        requestPath: String,
        method: HTTPMethod,
        range rangeHeader: String?,
        started: CFAbsoluteTime,
        on connection: NWConnection
    ) {
        switch resource {
        case .memory(let data, let mime):
            respondWithData(
                data,
                mime: mime,
                requestPath: requestPath,
                method: method,
                range: rangeHeader,
                started: started,
                on: connection
            )
        case .disk(let url, let byteCount, let mime):
            respondWithDiskResource(
                url: url,
                totalLength: byteCount,
                mime: mime,
                requestPath: requestPath,
                method: method,
                range: rangeHeader,
                started: started,
                on: connection
            )
        }
    }

    private func respondWithData(
        _ data: Data,
        mime: String,
        requestPath: String,
        method: HTTPMethod,
        range rangeHeader: String?,
        started: CFAbsoluteTime,
        on connection: NWConnection
    ) {
        let totalLength = data.count

        if method == .head {
            var header = "HTTP/1.1 200 OK\r\n"
            header += "Content-Type: \(mime)\r\n"
            header += "Content-Length: \(totalLength)\r\n"
            header += "Accept-Ranges: bytes\r\n"
            header += "Cache-Control: no-store\r\n"
            header += "Connection: close\r\n\r\n"
            logRequest(method: method, path: requestPath, status: 200, bytes: totalLength, range: nil, started: started)
            send(Data(header.utf8), on: connection, andClose: true)
            return
        }

        if let rangeHeader, let parsed = Self.parseByteRange(rangeHeader, totalLength: totalLength) {
            switch parsed {
            case .satisfiable(let lower, let upper):
                let slice = data.subdata(in: lower..<(upper + 1))
                var header = "HTTP/1.1 206 Partial Content\r\n"
                header += "Content-Type: \(mime)\r\n"
                header += "Content-Length: \(slice.count)\r\n"
                header += "Accept-Ranges: bytes\r\n"
                header += "Content-Range: bytes \(lower)-\(upper)/\(totalLength)\r\n"
                header += "Cache-Control: no-store\r\n"
                header += "Connection: close\r\n\r\n"
                logRequest(method: method, path: requestPath, status: 206, bytes: slice.count, range: rangeHeader, started: started)
                sendHeaderAndBody(header, body: slice, on: connection)
                return
            case .notSatisfiable:
                var header = "HTTP/1.1 416 Range Not Satisfiable\r\n"
                header += "Content-Length: 0\r\n"
                header += "Content-Range: bytes */\(totalLength)\r\n"
                header += "Connection: close\r\n\r\n"
                logRequest(method: method, path: requestPath, status: 416, bytes: 0, range: rangeHeader, started: started)
                send(Data(header.utf8), on: connection, andClose: true)
                return
            }
        }

        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: \(mime)\r\n"
        header += "Content-Length: \(totalLength)\r\n"
        header += "Accept-Ranges: bytes\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"
        logRequest(method: method, path: requestPath, status: 200, bytes: totalLength, range: rangeHeader, started: started)
        sendHeaderAndBody(header, body: data, on: connection)
    }

    private func respondWithDiskResource(
        url: URL,
        totalLength: Int,
        mime: String,
        requestPath: String,
        method: HTTPMethod,
        range rangeHeader: String?,
        started: CFAbsoluteTime,
        on connection: NWConnection
    ) {
        guard totalLength > 0 else {
            logRequest(method: method, path: requestPath, status: 404, bytes: 0, range: rangeHeader, started: started)
            respondError(404, "Not Found", on: connection)
            return
        }

        if method == .head {
            var header = "HTTP/1.1 200 OK\r\n"
            header += "Content-Type: \(mime)\r\n"
            header += "Content-Length: \(totalLength)\r\n"
            header += "Accept-Ranges: bytes\r\n"
            header += "Cache-Control: no-store\r\n"
            header += "Connection: close\r\n\r\n"
            logRequest(method: method, path: requestPath, status: 200, bytes: totalLength, range: nil, started: started)
            send(Data(header.utf8), on: connection, andClose: true)
            return
        }

        let lower: Int
        let upper: Int
        let status: Int
        if let rangeHeader, let parsed = Self.parseByteRange(rangeHeader, totalLength: totalLength) {
            switch parsed {
            case .satisfiable(let parsedLower, let parsedUpper):
                lower = parsedLower
                upper = parsedUpper
                status = 206
            case .notSatisfiable:
                var header = "HTTP/1.1 416 Range Not Satisfiable\r\n"
                header += "Content-Length: 0\r\n"
                header += "Content-Range: bytes */\(totalLength)\r\n"
                header += "Connection: close\r\n\r\n"
                logRequest(method: method, path: requestPath, status: 416, bytes: 0, range: rangeHeader, started: started)
                send(Data(header.utf8), on: connection, andClose: true)
                return
            }
        } else {
            lower = 0
            upper = totalLength - 1
            status = 200
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            logRequest(method: method, path: requestPath, status: 404, bytes: 0, range: rangeHeader, started: started)
            respondError(404, "Not Found", on: connection)
            return
        }
        do {
            try handle.seek(toOffset: UInt64(lower))
        } catch {
            handle.closeFile()
            logRequest(method: method, path: requestPath, status: 404, bytes: 0, range: rangeHeader, started: started)
            respondError(404, "Not Found", on: connection)
            return
        }

        let bodyBytes = upper - lower + 1
        var header = "HTTP/1.1 \(status) \(status == 206 ? "Partial Content" : "OK")\r\n"
        header += "Content-Type: \(mime)\r\n"
        header += "Content-Length: \(bodyBytes)\r\n"
        header += "Accept-Ranges: bytes\r\n"
        if status == 206 {
            header += "Content-Range: bytes \(lower)-\(upper)/\(totalLength)\r\n"
        }
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"
        logRequest(method: method, path: requestPath, status: status, bytes: bodyBytes, range: rangeHeader, started: started)
        send(Data(header.utf8), on: connection, andClose: false) { [weak self] in
            self?.sendFileChunks(handle: handle, remaining: bodyBytes, on: connection)
        }
    }

    private func logRequest(
        method: HTTPMethod,
        path: String,
        status: Int,
        bytes: Int,
        range: String?,
        started: CFAbsoluteTime
    ) {
        // Rate-limit per (method, path) so AVPlayer's repeated head-of-
        // playlist probes (4× /playlist.m3u8 in the first ~50 ms) don't each
        // emit a line. Subsequent requests for the same path are tracked but
        // not logged unless the status, byte count, or range changes — the
        // unique events that matter for diagnosis. The startup-wide cap remains
        // as a safety net for pathological per-path success traffic, but HLS
        // errors bypass it so late segment misses are never hidden.
        let methodName: String = switch method {
        case .get: "GET"
        case .head: "HEAD"
        }
        let signature = "\(methodName) \(path) \(status) \(bytes) \(range ?? "-")"
        let signatureAlreadyLogged = loggedRequestSignatures.contains(signature)
        guard LocalHLSRequestLogPolicy.shouldLog(
            status: status,
            requestLogCount: requestLogCount,
            startupRequestLogLimit: Self.startupRequestLogLimit,
            signatureAlreadyLogged: signatureAlreadyLogged
        ) else { return }
        loggedRequestSignatures.insert(signature)
        requestLogCount += 1
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
        let rangeLabel = range ?? "-"
        cmpLog("[CMP-HLS] \(methodName) \(path) status=\(status) bytes=\(bytes) range=\(rangeLabel) elapsedMs=\(String(format: "%.1f", elapsedMs))")
    }

    enum ByteRange: Equatable {
        case satisfiable(lower: Int, upper: Int)
        case notSatisfiable
    }

    /// Parse a single RFC 7233 byte-range spec — `bytes=N-M`, `bytes=N-`, or
    /// `bytes=-N`. Returns nil for header shapes we don't recognize at all
    /// (caller falls through to a 200), and `.notSatisfiable` for shapes
    /// we recognize but cannot serve so the caller can answer with 416.
    /// Multipart byte-ranges (`bytes=0-9,20-29`) fall in the latter
    /// category — AVPlayer never sends them, and silently returning the
    /// full file would mask a misbehaving client.
    static func parseByteRange(_ header: String, totalLength: Int) -> ByteRange? {
        let lower = header.lowercased()
        guard lower.hasPrefix("bytes=") else { return nil }
        let spec = lower.dropFirst("bytes=".count)
        // No multipart support — explicit failure, not silent fall-through.
        if spec.contains(",") { return .notSatisfiable }
        guard let dashIndex = spec.firstIndex(of: "-") else { return nil }
        let firstPart = spec[..<dashIndex]
        let secondPart = spec[spec.index(after: dashIndex)...]
        let firstStr = firstPart.trimmingCharacters(in: .whitespaces)
        let secondStr = secondPart.trimmingCharacters(in: .whitespaces)
        let firstByte = Int(firstStr)
        let lastByte = Int(secondStr)
        guard totalLength > 0 else { return .notSatisfiable }
        let lowerBound: Int
        let upperBound: Int
        switch (firstByte, lastByte) {
        case let (l?, r?):
            lowerBound = l
            upperBound = min(r, totalLength - 1)
        case let (l?, nil):
            lowerBound = l
            upperBound = totalLength - 1
        case let (nil, suffix?):
            // `-N` means "last N bytes".
            let take = min(suffix, totalLength)
            lowerBound = totalLength - take
            upperBound = totalLength - 1
        default:
            return nil
        }
        guard lowerBound >= 0,
              upperBound >= lowerBound,
              lowerBound < totalLength else {
            return .notSatisfiable
        }
        return .satisfiable(lower: lowerBound, upper: upperBound)
    }

    private func respondError(_ code: Int, _ phrase: String, on connection: NWConnection) {
        let body = "\(code) \(phrase)\n"
        var header = "HTTP/1.1 \(code) \(phrase)\r\n"
        header += "Content-Type: text/plain; charset=utf-8\r\n"
        header += "Content-Length: \(body.utf8.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body.data(using: .utf8) ?? Data())
        send(data, on: connection, andClose: true)
    }

    private func sendHeaderAndBody(_ header: String, body: Data, on connection: NWConnection) {
        send(Data(header.utf8), on: connection, andClose: false) { [weak self] in
            self?.send(body, on: connection, andClose: true)
        }
    }

    private func sendFileChunks(handle: FileHandle, remaining: Int, on connection: NWConnection) {
        guard remaining > 0 else {
            handle.closeFile()
            connection.cancel()
            return
        }
        let nextLength = min(remaining, Self.responseChunkBytes)
        let chunk = handle.readData(ofLength: nextLength)
        guard !chunk.isEmpty else {
            handle.closeFile()
            connection.cancel()
            return
        }
        let nextRemaining = remaining - chunk.count
        let isLast = nextRemaining <= 0
        send(chunk, on: connection, andClose: isLast) { [weak self] in
            if isLast {
                handle.closeFile()
            } else {
                self?.sendFileChunks(handle: handle, remaining: nextRemaining, on: connection)
            }
        }
    }

    private func send(_ data: Data, on connection: NWConnection, andClose close: Bool, completion: (() -> Void)? = nil) {
        connection.send(content: data, completion: .contentProcessed { _ in
            completion?()
            if close { connection.cancel() }
        })
    }

    private func mimeType(for ext: String) -> String {
        switch ext {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "m4s", "mp4": return "video/mp4"
        case "ts": return "video/mp2t"
        default: return "application/octet-stream"
        }
    }

}

enum LoopbackSegmentServerError: Error {
    case listenerInitFailed(Error?)
    case listenerFailed(NWError)
    case bindTimeout
}
