import Foundation
import OSLog

/// Events surfaced by the background download session, consumed by
/// `DownloadManager` on the MainActor via an `AsyncStream`.
enum DownloadSessionEvent: Sendable {
    case progress(taskId: Int, bytesWritten: Int64, totalExpected: Int64)
    /// Media transfer succeeded (HTTP 2xx). `stagedURL` is a stable file in
    /// the staging directory — the volatile temp file has already been
    /// moved there synchronously inside the delegate callback.
    case finished(taskId: Int, stagedURL: URL, statusCode: Int)
    /// Transfer ended without a usable file: a network error, a
    /// cancellation, or a non-2xx server response (e.g. 409 revoked).
    case failed(taskId: Int, statusCode: Int?, resumeData: Data?, message: String)
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
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "Downloads"
    )

    private let continuation: AsyncStream<DownloadSessionEvent>.Continuation
    let events: AsyncStream<DownloadSessionEvent>

    /// Set when iOS relaunches the app to deliver background events; called
    /// once `allEventsDelivered` is processed.
    var backgroundCompletionHandler: (() -> Void)?

    override init() {
        let (stream, continuation) = AsyncStream<DownloadSessionEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
        super.init()
        _ = session   // force lazy creation so the delegate is registered
    }

    private(set) lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // MARK: - Task control

    /// Start a fresh media download. Returns the task identifier to persist
    /// on the record for relaunch reconnection.
    func start(request: URLRequest) -> Int {
        let task = session.downloadTask(with: request)
        task.resume()
        return task.taskIdentifier
    }

    /// Resume a previously-interrupted download from its `resumeData`.
    func resume(data: Data) -> Int {
        let task = session.downloadTask(withResumeData: data)
        task.resume()
        return task.taskIdentifier
    }

    func cancel(taskId: Int) {
        session.getAllTasks { tasks in
            tasks.first(where: { $0.taskIdentifier == taskId })?.cancel()
        }
    }

    /// Suspend a transfer by cancelling it with resume data. Returns `nil`
    /// when the server/transfer doesn't support ranged resume or the task is
    /// no longer live — callers must treat that as "restart from zero".
    func pause(taskId: Int) async -> Data? {
        await withCheckedContinuation { cont in
            session.getAllTasks { tasks in
                guard let task = tasks.first(where: { $0.taskIdentifier == taskId })
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
    func activeTaskIdentifiers() async -> Set<Int> {
        await withCheckedContinuation { cont in
            session.getAllTasks { tasks in
                cont.resume(returning: Set(tasks.map { $0.taskIdentifier }))
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
                statusCode: statusCode,
                resumeData: nil,
                message: "HTTP \(statusCode)"
            ))
            return
        }

        // The temp file is only valid during this callback — move it to a
        // stable staging location synchronously, then hand off the path.
        let staged = DownloadFilePaths.stagingFileURL(taskIdentifier: taskId)
        try? FileManager.default.removeItem(at: staged)
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            continuation.yield(.finished(taskId: taskId, stagedURL: staged, statusCode: statusCode))
        } catch {
            Self.logger.error("Failed to stage finished download \(taskId): \(String(describing: error), privacy: .public)")
            continuation.yield(.failed(
                taskId: taskId,
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
        // A user-initiated cancel still surfaces here; the manager checks
        // its own intent and ignores cancellations it requested.
        continuation.yield(.failed(
            taskId: task.taskIdentifier,
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
    static func authorizedRequest(url: URL, allowsCellular: Bool) async -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allowsCellularAccess = allowsCellular

        if let token = await TokenStore.shared.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let profileId = await TokenStore.shared.getProfileId() {
            request.setValue(profileId, forHTTPHeaderField: "X-Profile-Id")
        }
        if let profileToken = await TokenStore.shared.getProfileToken() {
            request.setValue(profileToken, forHTTPHeaderField: "X-Profile-Token")
        }
        AppleDeviceIdentity.current.applyHeaders(to: &request)
        return request
    }
}
