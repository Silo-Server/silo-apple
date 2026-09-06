import Foundation
import OSLog

/// Events surfaced by the background download session, consumed by
/// `DownloadManager` on the MainActor via an `AsyncStream`.
enum DownloadSessionEvent: Sendable {
    case progress(taskId: Int, transferID: UUID?, bytesWritten: Int64, totalExpected: Int64)
    /// Media transfer succeeded (HTTP 2xx). `stagedURL` is a stable file in
    /// the staging directory — the volatile temp file has already been
    /// moved there synchronously inside the delegate callback.
    case finished(DownloadParkedArrival)
    /// Transfer ended without a usable file: a network error, a
    /// cancellation, or a non-2xx server response (e.g. 409 revoked).
    case failed(taskId: Int, transferID: UUID?, statusCode: Int?, resumeData: Data?, message: String)
    /// All background events for this launch have been delivered; the app
    /// may call the system-provided completion handler.
    case allEventsDelivered
}

/// Owns the app's single background `URLSession` used to transfer media
/// files. A background session continues across suspension/termination and
/// resumes via HTTP Range, so this is an `NSObject` delegate (background
/// sessions cannot use the async `URLSession` data API).
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let sessionIdentifier = "com.continuum.play.downloads"

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "Downloads"
    )

    private let continuation: AsyncStream<DownloadSessionEvent>.Continuation
    let events: AsyncStream<DownloadSessionEvent>

    /// Set when iOS relaunches the app to deliver background events; called
    /// once `allEventsDelivered` is processed.
    var backgroundCompletionHandler: (() -> Void)?

    let identifier: String
    private let parkingRoot: URL

    init(parkingRoot: URL? = nil, identifier: String = DownloadSessionDelegate.sessionIdentifier) {
        self.identifier = identifier
        self.parkingRoot = parkingRoot ?? DownloadFilePaths.rootDirectory()
        let (stream, continuation) = AsyncStream<DownloadSessionEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
        super.init()
        _ = session   // force lazy creation so the delegate is registered
    }

    private(set) lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // MARK: - Task control

    /// Start a fresh media download. Returns the task identifier to persist
    /// on the record for relaunch reconnection.
    func prepare(request: URLRequest, transferID: UUID) -> URLSessionDownloadTask {
        let task = session.downloadTask(with: request)
        task.taskDescription = transferID.uuidString
        return task
    }

    /// Resume a previously-interrupted download from its `resumeData`.
    func prepare(data: Data, transferID: UUID) -> URLSessionDownloadTask {
        let task = session.downloadTask(withResumeData: data)
        task.taskDescription = transferID.uuidString
        return task
    }

    func cancel(_ binding: DownloadTaskBinding) {
        session.getAllTasks { tasks in
            tasks.first(where: { $0.taskIdentifier == binding.taskID && $0.taskDescription == binding.transferID.uuidString })?.cancel()
        }
    }

    /// Suspend a transfer by cancelling it with resume data. Returns `nil`
    /// when the server/transfer doesn't support ranged resume or the task is
    /// no longer live — callers must treat that as "restart from zero".
    func pause(_ binding: DownloadTaskBinding) async -> Data? {
        await withCheckedContinuation { cont in
            session.getAllTasks { tasks in
                guard let task = tasks.first(where: { $0.taskIdentifier == binding.taskID && $0.taskDescription == binding.transferID.uuidString })
                    as? URLSessionDownloadTask else {
                    cont.resume(returning: nil)
                    return
                }
                task.cancel(byProducingResumeData: { data in
                    cont.resume(returning: data)
                })
            }
        }
    }

    /// Identifiers of tasks still live in the (possibly relaunched) session.
    func activeTransfers() async -> [Int: UUID] {
        await withCheckedContinuation { cont in
            session.getAllTasks { tasks in
                cont.resume(returning: Dictionary(uniqueKeysWithValues: tasks.compactMap { task in
                    task.taskDescription.flatMap(UUID.init(uuidString:)).map { (task.taskIdentifier, $0) }
                }))
            }
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        continuation.yield(.progress(
            taskId: downloadTask.taskIdentifier,
            transferID: downloadTask.taskDescription.flatMap(UUID.init(uuidString:)),
            bytesWritten: totalBytesWritten,
            totalExpected: totalBytesExpectedToWrite
        ))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskId = downloadTask.taskIdentifier
        let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0

        // A non-2xx "success" means the body is an error envelope, not media.
        guard (200..<300).contains(statusCode) else {
            Self.logger.error("Download task \(taskId) finished with HTTP \(statusCode); treating as failure")
            continuation.yield(.failed(
                taskId: taskId,
                transferID: downloadTask.taskDescription.flatMap(UUID.init(uuidString:)),
                statusCode: statusCode,
                resumeData: nil,
                message: "HTTP \(statusCode)"
            ))
            return
        }

        // The temp file is only valid during this callback — move it to a
        // stable staging location synchronously, then hand off the path.
        do {
            let arrival = try DownloadArrivalParking.park(source: location,
                root: parkingRoot.appendingPathComponent("staging", isDirectory: true),
                sessionID: identifier, taskID: taskId,
                transferID: downloadTask.taskDescription.flatMap(UUID.init(uuidString:)), status: statusCode)
            continuation.yield(.finished(arrival))
        } catch {
            Self.logger.error("Failed to stage finished download \(taskId): \(String(describing: error), privacy: .public)")
            continuation.yield(.failed(
                taskId: taskId,
                transferID: downloadTask.taskDescription.flatMap(UUID.init(uuidString:)),
                statusCode: statusCode,
                resumeData: nil,
                message: "stage_failed"
            ))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // Success path is handled in didFinishDownloadingTo. Only act on a
        // real transport error / cancellation here.
        guard let error else { return }
        let nsError = error as NSError
        let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode
        // Preserve resume bytes even when no actor is active or a restarted task
        // has no known binding. Adoption remains a separate checked actor command.
        if let resumeData {
            do {
                _ = try DownloadArrivalParking.park(data: resumeData,
                    root: parkingRoot.appendingPathComponent("resume-parking", isDirectory: true),
                    sessionID: identifier, taskID: task.taskIdentifier,
                    transferID: task.taskDescription.flatMap(UUID.init(uuidString:)), status: statusCode ?? 0)
            } catch {
                Self.logger.error("Failed to preserve interrupted transfer data: \(String(describing: error), privacy: .public)")
            }
        }
        // A user-initiated cancel still surfaces here; the manager checks
        // its own intent and ignores cancellations it requested.
        continuation.yield(.failed(
            taskId: task.taskIdentifier,
            transferID: task.taskDescription.flatMap(UUID.init(uuidString:)),
            statusCode: statusCode,
            resumeData: resumeData,
            message: error.localizedDescription
        ))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        continuation.yield(.allEventsDelivered)
    }
}

/// Builds an authenticated `URLRequest` for the background download
/// session, replicating the header set `HTTPClient.attachAuthHeaders`
/// applies (the background session can't share that actor's `URLSession`).
enum DownloadAuthHeaders {
    static func authorizedRequest(url: URL, allowsCellular: Bool, auth: CapturedOrdinaryRequestAuth) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allowsCellularAccess = allowsCellular
        if let token = auth.accessToken { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let profile = auth.profileId { request.setValue(profile, forHTTPHeaderField: "X-Profile-Id") }
        if let proof = auth.profileToken { request.setValue(proof, forHTTPHeaderField: "X-Profile-Token") }
        AppleDeviceIdentity.current.applyHeaders(to: &request)
        return request
    }
}
