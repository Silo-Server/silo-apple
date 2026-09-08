import Foundation
import AetherEngine

/// Ephemeral delivery scope for the exact auxiliary URLs in one adopted plan.
/// Credentials and downloaded bytes never enter the durable playback journal.
final class ProxyAuxiliaryScope: @unchecked Sendable {
    let sessionID: String
    let planID: String
    let headers: [String: String]
    let origin: URL
    private let auth: CapturedOrdinaryRequestAuth
    private let tokens: TokenStore
    private let expiresAt: Date?
    private let issued: Set<String>
    private let root: URL
    private let sessionConfiguration: @Sendable () -> URLSessionConfiguration
    private let isActive: @Sendable () async -> Bool
    private let lock = NSLock()
    private var valid = true
    private var files: [String: URL] = [:]
    private var sessions: [UUID: URLSession] = [:]
    private var watcher: Task<Void, Never>?

    init(plan: PlaybackV3Plan, sessionID: String, sourceURL: URL,
         auth: CapturedOrdinaryRequestAuth, tokens: TokenStore = .shared,
         temporaryRoot: URL = FileManager.default.temporaryDirectory,
         sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral },
         isActive: @escaping @Sendable () async -> Bool) throws {
        guard let token = auth.accessToken, !token.isEmpty, let profile = auth.profileId, !profile.isEmpty,
              plan.sessionId == nil || plan.sessionId == sessionID else { throw HTTPError.requestIdentityChanged }
        self.sessionID = sessionID
        origin = sourceURL
        planID = plan.planId
        self.auth = auth
        self.tokens = tokens
        self.isActive = isActive
        self.sessionConfiguration = sessionConfiguration
        headers = ["Authorization": "Bearer \(token)", "X-Profile-Id": profile]
        if let raw = plan.expiresAt {
            let fractional = ISO8601DateFormatter(); fractional.formatOptions.insert(.withFractionalSeconds)
            guard let parsed = fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else {
                throw PlaybackSequencedError.invalidResponse
            }
            expiresAt = parsed
        } else { expiresAt = nil }
        root = temporaryRoot.appendingPathComponent("SiloProxyAuxiliary").appendingPathComponent(UUID().uuidString)
        var urls = Set<String>()
        for item in plan.subtitle.inventory {
            var pins: [String: String]?
            for raw in [item.url, item.fontBundleUrl].compactMap({ $0 }) where StreamRequest.isProxyAuxiliaryURL(raw) {
                guard let current = StreamRequest.proxyAuxiliaryPins(rawURL: raw, sessionID: sessionID,
                    origin: sourceURL, fileID: plan.requestedMediaFileId, track: item.combinedIndex),
                      pins == nil || pins == current else { throw PlaybackSequencedError.invalidResponse }
                pins = current
                urls.insert(raw)
            }
        }
        if let artifact = plan.subtitle.artifact, StreamRequest.isProxyAuxiliaryURL(artifact.url) {
            guard let selected = plan.selectedSubtitleInventoryItem,
                  let pins = StreamRequest.proxyAuxiliaryPins(rawURL: artifact.url, sessionID: sessionID,
                    origin: sourceURL, fileID: plan.requestedMediaFileId, track: selected.combinedIndex) else {
                throw PlaybackSequencedError.invalidResponse
            }
            for raw in [selected.url, selected.fontBundleUrl].compactMap({ $0 }) where StreamRequest.isProxyAuxiliaryURL(raw) {
                guard StreamRequest.proxyAuxiliaryPins(rawURL: raw, sessionID: sessionID, origin: sourceURL,
                    fileID: plan.requestedMediaFileId, track: selected.combinedIndex) == pins else {
                    throw PlaybackSequencedError.invalidResponse
                }
            }
            urls.insert(artifact.url)
        }
        issued = urls
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                    guard let scope = self else { return }
                    try await scope.requireCurrent()
                } catch { return }
            }
        }
    }

    deinit { invalidate() }

    func invalidate() {
        let activeSessions = lock.withLock { () -> [URLSession] in
            valid = false
            files.removeAll()
            let active = Array(sessions.values)
            sessions.removeAll()
            return active
        }
        watcher?.cancel()
        activeSessions.forEach { $0.invalidateAndCancel() }
        try? FileManager.default.removeItem(at: root)
    }

    func requireCurrent() async throws {
        guard lock.withLock({ valid }), expiresAt.map({ $0 > Date() }) ?? true,
              await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: auth) == auth,
              await isActive(), lock.withLock({ valid }) else {
            invalidate()
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
    }

    func localURL(for raw: String) -> URL? { lock.withLock { valid ? files[raw] : nil } }

    /// Downloads exact response bytes once to an owned file. Aether receives
    /// that local URL with empty headers, so its redirect policy is irrelevant.
    func materialize(_ raw: String) async throws -> URL {
        try await requireCurrent()
        guard issued.contains(raw), let url = URL(string: raw) else { throw PlaybackSequencedError.invalidResponse }
        if let existing = localURL(for: raw) { return existing }
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = headers
        request.timeoutInterval = min(20, max(0.1, expiresAt?.timeIntervalSinceNow ?? 20))
        let session = URLSession(configuration: sessionConfiguration())
        let id = UUID()
        try lock.withLock {
            guard valid else { throw HTTPError.requestIdentityChanged }
            sessions[id] = session
        }
        defer {
            _ = lock.withLock { sessions.removeValue(forKey: id) }
            session.invalidateAndCancel()
        }
        let isFont = url.path.hasSuffix("/fonts")
        let delegate = ProxyAuxiliaryDownloadDelegate(limit: isFont ? 48 * 1_024 * 1_024 : 256 * 1_024 * 1_024)
        let (temporary, response) = try await session.download(for: request, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await requireCurrent()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.absoluteString == raw,
              Self.acceptsMIME(response.mimeType, font: isFont, extension: url.pathExtension),
              let bytes = try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber,
              bytes.int64Value <= delegate.limit else { throw URLError(.badServerResponse) }
        return try lock.withLock {
            guard valid else { throw HTTPError.requestIdentityChanged }
            if let existing = files[raw] { return existing }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let target = root.appendingPathComponent(UUID().uuidString).appendingPathExtension(isFont ? "json" : url.pathExtension)
            try FileManager.default.moveItem(at: temporary, to: target)
            files[raw] = target
            return target
        }
    }

    /// Used by dynamic and secondary Aether registrations as well as their
    /// optional font bundle. Existing non-proxy resources remain unchanged.
    func materializeTrack(_ track: ExternalSubtitleTrack, fontRequest: URLRequest?) async throws
        -> (track: ExternalSubtitleTrack, fontRequest: URLRequest?) {
        var delivered = track
        if StreamRequest.isProxyAuxiliaryURL(track.url.absoluteString) || StreamRequest.hasSameOrigin(track.url, origin) {
            delivered.url = try await materialize(track.url.absoluteString)
            delivered.httpHeaders = [:]
        }
        var font = fontRequest
        if let url = fontRequest?.url,
           StreamRequest.isProxyAuxiliaryURL(url.absoluteString) || StreamRequest.hasSameOrigin(url, origin) {
            font = URLRequest(url: try await materialize(url.absoluteString))
        }
        try await requireCurrent()
        return (delivered, font)
    }

    private static func acceptsMIME(_ mime: String?, font: Bool, extension ext: String) -> Bool {
        guard let mime = mime?.lowercased() else { return false }
        if font { return mime == "application/json" }
        switch ext.lowercased() {
        case "ass", "ssa": return ["text/x-ssa", "text/x-ass", "text/plain", "application/octet-stream"].contains(mime)
        case "vtt": return ["text/vtt", "text/plain", "application/octet-stream"].contains(mime)
        case "srt": return ["application/x-subrip", "text/plain", "application/octet-stream"].contains(mime)
        case "sup": return mime == "application/octet-stream"
        default: return false
        }
    }
}

final class ProxyAuxiliaryDownloadDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate {
    let limit: Int64
    init(limit: Int64) { self.limit = limit }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
