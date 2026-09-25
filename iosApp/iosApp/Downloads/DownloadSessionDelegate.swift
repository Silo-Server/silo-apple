import Foundation
import OSLog

/// The task an event came from: its session-local identifier, the owner tag
/// it was started with, and the request the manager attributes an untagged
/// task by (see `DownloadTaskTag.attributing`).
struct DownloadTaskRef: Sendable, Equatable {
    let taskId: Int
    let tag: DownloadTaskTag?
    let requestURL: URL?
    let requestProfileId: String?

    init(taskId: Int, tag: DownloadTaskTag?, requestURL: URL?, requestProfileId: String?) {
        self.taskId = taskId
        self.tag = tag
        self.requestURL = requestURL
        self.requestProfileId = requestProfileId
    }

    /// A task created from resume data rebuilds its original request,
    /// headers included, so this reads the same for either kind of task.
    init(_ task: URLSessionTask) {
        let request = task.originalRequest ?? task.currentRequest
        self.init(
            taskId: task.taskIdentifier,
            tag: DownloadTaskTag(taskDescription: task.taskDescription),
            requestURL: request?.url,
            requestProfileId: request?.value(forHTTPHeaderField: "X-Profile-Id")
        )
    }
}

/// Events surfaced by the background download session, consumed by
/// `DownloadManager` on the MainActor via an `AsyncStream`.
enum DownloadSessionEvent: Sendable {
    case progress(DownloadTaskRef, bytesWritten: Int64, totalExpected: Int64)
    /// Media transfer succeeded (HTTP 2xx). The volatile temp file has
    /// already been moved to `fileURL` synchronously inside the delegate
    /// callback: the owner's `DownloadFilePaths.finishedTransferURL(for:)`
    /// for a tagged task, the staging directory for an untagged one.
    case finished(DownloadTaskRef, fileURL: URL)
    /// Transfer ended without a usable file: a network error, a
    /// cancellation, or a non-2xx server response (e.g. 409 revoked).
    case failed(DownloadTaskRef, statusCode: Int?, resumeData: Data?, message: String)
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

    /// Start a fresh media download owned by `tag`. Returns the task
    /// identifier the record keeps to cancel or pause it.
    func start(request: URLRequest, tag: DownloadTaskTag) -> Int {
        let task = session.downloadTask(with: request)
        task.taskDescription = tag.taskDescription
        task.resume()
        return task.taskIdentifier
    }

    /// Resume a previously-interrupted download from its `resumeData`.
    /// Returns nil, without sending anything, when the data resumes a
    /// request other than a v2 download file route (for example one saved
    /// before the file route moved); the caller restarts from the manifest.
    func resume(data: Data, tag: DownloadTaskTag) -> Int? {
        let task = session.downloadTask(withResumeData: data)
        guard !Self.isRetired(task) else {
            Self.logger.notice("Discarding resume data for a retired download URL")
            task.cancel()
            return nil
        }
        task.taskDescription = tag.taskDescription
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

    /// Whether a task may be controlled by a caller that expects `expected`
    /// to own it. Identifiers repeat across session instances, so a task
    /// whose tag names another owner is never touched. An untagged task
    /// (from an earlier build) matches by identifier alone, and a nil
    /// `expected` skips the check.
    private static func isOwned(_ task: URLSessionTask, by expected: DownloadTaskTag?) -> Bool {
        guard let expected, let tag = DownloadTaskTag(taskDescription: task.taskDescription) else { return true }
        return tag == expected
    }

    func cancel(taskId: Int, expecting expected: DownloadTaskTag?) {
        session.getAllTasks { tasks in
            guard let task = tasks.first(where: { $0.taskIdentifier == taskId }),
                  Self.isOwned(task, by: expected) else { return }
            task.cancel()
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
    /// no longer live — callers must treat that as "restart from zero". A
    /// task owned by someone other than `expected` is left running.
    func pause(taskId: Int, expecting expected: DownloadTaskTag?) async -> Data? {
        await withCheckedContinuation { cont in
            session.getAllTasks { tasks in
                guard let task = tasks.first(where: { $0.taskIdentifier == taskId })
                    as? URLSessionDownloadTask, Self.isOwned(task, by: expected) else {
                    cont.resume(returning: nil)
                    return
                }
                task.cancel(byProducingResumeData: { data in
                    cont.resume(returning: data)
                })
            }
        }
    }

    /// Tasks still live in the (possibly relaunched) session, of every
    /// scope. `retired` holds the live tasks that request anything other
    /// than a v2 download file route; the caller cancels them and restarts
    /// their downloads.
    func liveTasks() async -> (current: [DownloadTaskRef], retired: [DownloadTaskRef]) {
        await withCheckedContinuation { cont in
            session.getAllTasks { tasks in
                var current: [DownloadTaskRef] = []
                var retired: [DownloadTaskRef] = []
                for task in tasks {
                    if Self.isRetired(task) {
                        retired.append(DownloadTaskRef(task))
                    } else {
                        current.append(DownloadTaskRef(task))
                    }
                }
                cont.resume(returning: (current, retired))
            }
        }
    }

    /// Stops every transfer still running in the pre-rename session and
    /// returns the resume data of those that can continue, keyed by
    /// `legacyTransferKey` of the file they request. Task identifiers aren't
    /// used: they repeat across sessions and scopes. Runs until one drain completes;
    /// later calls return an empty map without touching the old session.
    static func drainLegacySession(defaults: UserDefaults = .standard) async -> [String: Data] {
        guard !defaults.bool(forKey: legacySessionDrainedKey) else { return [:] }
        let config = URLSessionConfiguration.background(withIdentifier: legacySessionIdentifier)
        let session = URLSession(configuration: config, delegate: LegacySessionDrain(), delegateQueue: nil)
        var resumeData: [String: Data] = [:]
        for task in await session.allTasks {
            if let download = task as? URLSessionDownloadTask,
               let key = legacyTransferKey(task.originalRequest?.url ?? task.currentRequest?.url),
               let data = await download.cancelByProducingResumeData() {
                resumeData[key] = data
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

    /// Identifies a download file request by server and download id, so a
    /// drained transfer can only be matched to the record on the server it
    /// came from. Nil for anything but a v2 download file URL.
    static func legacyTransferKey(_ url: URL?) -> String? {
        guard APIv2Client.isDownloadFileURL(url), let url,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased() else { return nil }
        let port = parts.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)\(parts.percentEncodedPath)"
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
            DownloadTaskRef(downloadTask),
            bytesWritten: totalBytesWritten,
            totalExpected: totalBytesExpectedToWrite
        ))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let ref = DownloadTaskRef(downloadTask)
        let taskId = ref.taskId
        let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0

        // A non-2xx "success" means the body is an error envelope, not media.
        guard (200..<300).contains(statusCode) else {
            Self.logger.error("Download task \(taskId) finished with HTTP \(statusCode); treating as failure")
            continuation.yield(.failed(
                ref,
                statusCode: statusCode,
                resumeData: nil,
                message: "HTTP \(statusCode)"
            ))
            return
        }

        // The temp file is only valid during this callback — move it
        // synchronously, then hand off the path. A tagged task's file goes
        // straight into its owner's download directory, so it survives
        // whichever scope is loaded and the process itself.
        let destination = ref.tag.map(DownloadFilePaths.finishedTransferURL(for:))
            ?? DownloadFilePaths.stagingFileURL(taskIdentifier: taskId)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            continuation.yield(.finished(ref, fileURL: destination))
        } catch {
            Self.logger.error("Failed to stage finished download \(taskId): \(String(describing: error), privacy: .public)")
            continuation.yield(.failed(
                ref,
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
            DownloadTaskRef(task),
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
