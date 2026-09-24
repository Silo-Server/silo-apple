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
    static let sessionIdentifier = "org.siloserver.silo.downloads"

    /// Builds before the continuum → silo rename ran their transfers in a
    /// session with this identifier. The system keeps that session's tasks
    /// across an update, but nothing would ever collect their results.
    static let legacySessionIdentifier = "com.continuum.play.downloads"
    private static let legacySessionDrainedKey = "downloads.legacySessionDrained.v1"

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
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
    /// Returns nil, without sending anything, when the data resumes a
    /// request other than a v2 download file route (for example one saved
    /// before the file route moved); the caller restarts from the manifest.
    func resume(data: Data) -> Int? {
        let task = session.downloadTask(withResumeData: data)
        guard !Self.isRetired(task) else {
            Self.logger.notice("Discarding resume data for a retired download URL")
            task.cancel()
            return nil
        }
        task.resume()
        return task.taskIdentifier
    }

    /// Whether a task requests a URL that is not a v2 download file route.
    /// A task whose request is unknown is kept; a stale one still ends in a
    /// 410, which restarts its download.
    private static func isRetired(_ task: URLSessionTask) -> Bool {
        guard let url = task.originalRequest?.url ?? task.currentRequest?.url else { return false }
        return !APIv2Client.isDownloadFileURL(url)
    }

    func cancel(taskId: Int) {
        session.getAllTasks { tasks in
            tasks.first(where: { $0.taskIdentifier == taskId })?.cancel()
        }
    }

    /// Cancel every task in the session, including ones an earlier app
    /// version started that the system reattached on launch. Returns once
    /// the cancels are issued; their final events still arrive later.
    func cancelAllTasks() async {
        await withCheckedContinuation { cont in
            session.getAllTasks { tasks in
                for task in tasks { task.cancel() }
                cont.resume()
            }
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
    /// `retired` holds the live tasks that request anything other than a v2
    /// download file route; the caller cancels them and restarts their
    /// downloads.
    func liveTasks() async -> (current: Set<Int>, retired: Set<Int>) {
        await withCheckedContinuation { cont in
            session.getAllTasks { tasks in
                var current: Set<Int> = []
                var retired: Set<Int> = []
                for task in tasks {
                    if Self.isRetired(task) {
                        retired.insert(task.taskIdentifier)
                    } else {
                        current.insert(task.taskIdentifier)
                    }
                }
                cont.resume(returning: (current, retired))
            }
        }
    }

    /// Stops every transfer still running in the pre-rename session and
    /// returns the resume data of those that can continue, keyed by the
    /// download id their request names. Task identifiers aren't used: they
    /// repeat across sessions and scopes. Runs until one drain completes;
    /// later calls return an empty map without touching the old session.
    static func drainLegacySession(defaults: UserDefaults = .standard) async -> [String: Data] {
        guard !defaults.bool(forKey: legacySessionDrainedKey) else { return [:] }
        let config = URLSessionConfiguration.background(withIdentifier: legacySessionIdentifier)
        let session = URLSession(configuration: config, delegate: LegacySessionDrain(), delegateQueue: nil)
        var resumeData: [String: Data] = [:]
        for task in await session.allTasks {
            if let download = task as? URLSessionDownloadTask,
               let id = APIv2Client.downloadFileID(task.originalRequest?.url ?? task.currentRequest?.url),
               let data = await download.cancelByProducingResumeData() {
                resumeData[id] = data
            } else {
                task.cancel()
            }
        }
        session.invalidateAndCancel()
        // Marked only once the session is fully drained: a process killed
        // mid-drain retries on its next launch instead of leaving the old
        // transfers running unobserved. `DownloadManager` shares one drain
        // per process, so the session is never opened twice at once.
        defaults.set(true, forKey: legacySessionDrainedKey)
        if !resumeData.isEmpty {
            logger.notice("Moved \(resumeData.count, privacy: .public) transfers out of the pre-rename download session")
        }
        return resumeData
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
/// session, replicating the header set `HTTPClient` applies (the background
/// session can't share that actor's `URLSession`). The headers come from one
/// captured owner, so a request never mixes one owner's token with another's
/// profile.
enum DownloadAuthHeaders {
    static func authorizedRequest(url: URL, auth: CapturedOrdinaryRequestAuth, allowsCellular: Bool) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allowsCellularAccess = allowsCellular

        if let token = auth.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let profileId = auth.profileId {
            request.setValue(profileId, forHTTPHeaderField: "X-Profile-Id")
        }
        if let profileToken = auth.profileToken {
            request.setValue(profileToken, forHTTPHeaderField: "X-Profile-Token")
        }
        AppleDeviceIdentity.current.applyHeaders(to: &request)
        return request
    }
}

/// Delegate for the pre-rename session while it is drained. A transfer that
/// finished while the app wasn't running delivers its file here; that file
/// has no record to land in, so it is dropped and the download restarts.
private final class LegacySessionDrain: NSObject, URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
