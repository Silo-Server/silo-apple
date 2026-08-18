import Foundation
import Network

/// One HTTP/1.1 range origin on `127.0.0.1` serving `totalBytes` of zeros,
/// shared by every `PlaybackSourceProxy` test that needs a real socket to
/// read from. Honors `Range: bytes=N-` and `bytes=N-M` with a
/// 206 + `Content-Range`, one request per connection (`Connection: close`
/// semantics are fine for the origin stream, which opens a fresh task per
/// (re)target anyway).
///
/// Everything beyond that plain behavior is opt-in, and each knob exists for
/// one call site:
///
/// - `responseDelay` holds every response header back by that interval, so a
///   test can measure the proxy under origin RTT.
/// - `stallAfterByte` delivers bytes up to that absolute offset and then holds
///   the connection open with no further data — the shape of an origin whose
///   session died mid-body without a socket error.
/// - `goDown()` / `goUp()` kill the listener and every open connection (new
///   requests get connection-refused, in-flight bodies die mid-transfer) and
///   restart on the same port.
/// - `bodyChunkBytes` sizes the send chunk; the throughput harness needs a
///   larger one to outrun the path it is measuring.
///
/// Body delivery recurses on an absolute `cursor`/`end` pair rather than a
/// remaining count, because `stallAfterByte` is expressed in absolute file
/// offsets and has to be comparable against the cursor.
final class RangeOriginStub {
    let totalBytes: Int64
    private let responseDelay: TimeInterval
    private let stallAfterByte: Int64?
    private let bodyChunk: Data

    private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "range-origin-stub")
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var requestedOffsets: [Int64] = []
    private var requestedRanges: [String] = []

    init(
        totalBytes: Int64,
        responseDelay: TimeInterval = 0,
        stallAfterByte: Int64? = nil,
        bodyChunkBytes: Int = 64 * 1024
    ) {
        self.totalBytes = totalBytes
        self.responseDelay = responseDelay
        self.stallAfterByte = stallAfterByte
        self.bodyChunk = Data(count: bodyChunkBytes)
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/file.bin")! }

    /// Range request offsets observed, in arrival order.
    func observedOffsets() -> [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return requestedOffsets
    }

    /// Raw byte-range specs observed (for example `0-4194303` or `8388608-`).
    func observedRanges() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requestedRanges
    }

    /// Binds an ephemeral port on the first call and the same port on every
    /// later one, so `goUp()` brings the origin back where readers expect it.
    func start() async throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let endpointPort: NWEndpoint.Port = port == 0 ? .any : NWEndpoint.Port(rawValue: port)!
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: endpointPort)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        port = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed, let ready = listener.port {
                        resumed = true
                        continuation.resume(returning: ready.rawValue)
                    }
                case .failed(let error):
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.start(queue: self.queue)
        }
    }

    /// Kill the listener and every open connection: new requests get
    /// connection-refused, in-flight bodies die mid-transfer.
    func goDown() {
        listener?.cancel()
        listener = nil
        lock.lock()
        let open = connections.values
        connections.removeAll()
        lock.unlock()
        open.forEach { $0.cancel() }
    }

    /// Restart on the same port.
    func goUp() async throws {
        try await start()
    }

    func stop() { goDown() }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections[ObjectIdentifier(connection)] = connection
        lock.unlock()
        connection.start(queue: queue)
        receiveRequest(connection, buffered: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            var head = buffered
            if let data { head.append(data) }
            guard let headEnd = head.range(of: Data("\r\n\r\n".utf8)) else {
                if head.count < 64 * 1024 {
                    self.receiveRequest(connection, buffered: head)
                }
                return
            }
            let request = String(data: head[..<headEnd.lowerBound], encoding: .utf8) ?? ""
            self.respond(connection, request: request)
        }
    }

    private func respond(_ connection: NWConnection, request: String) {
        var offset: Int64 = 0
        var end: Int64 = totalBytes - 1
        var requestedRange = "0-"
        for line in request.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("range:"), let eq = line.range(of: "bytes=") {
                let spec = line[eq.upperBound...]
                requestedRange = String(spec)
                let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
                offset = parts.first.flatMap { Int64($0) } ?? 0
                if parts.count > 1, let bounded = Int64(parts[1]) {
                    end = min(bounded, totalBytes - 1)
                }
            }
        }
        lock.lock()
        requestedOffsets.append(offset)
        requestedRanges.append(requestedRange)
        lock.unlock()
        let remaining = end - offset + 1
        let header = "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(offset)-\(end)/\(totalBytes)\r\nContent-Length: \(remaining)\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n"
        let sendResponse = { [weak self] in
            connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] _ in
                self?.sendBody(connection, cursor: offset, end: end)
            })
        }
        if responseDelay > 0 {
            queue.asyncAfter(deadline: .now() + responseDelay, execute: sendResponse)
        } else {
            sendResponse()
        }
    }

    private func sendBody(_ connection: NWConnection, cursor: Int64, end: Int64) {
        let remaining = end - cursor + 1
        guard remaining > 0 else {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
            return
        }
        if let stallAfterByte, cursor >= stallAfterByte {
            // Hold the connection open with no further data: a dead session
            // mid-body, not a socket error.
            return
        }
        var chunkLength = min(remaining, Int64(bodyChunk.count))
        if let stallAfterByte, cursor < stallAfterByte {
            chunkLength = min(chunkLength, stallAfterByte - cursor)
        }
        let chunk = chunkLength == Int64(bodyChunk.count) ? bodyChunk : Data(count: Int(chunkLength))
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard error == nil else { return }
            self?.sendBody(connection, cursor: cursor + chunkLength, end: end)
        })
    }
}
