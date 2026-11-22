import Foundation

/// App Transport Security allows plain HTTP so a person can pick an HTTP
/// server. A request that went out over HTTPS must not follow a redirect onto
/// plain HTTP, though: URLSession would resend its headers and, for a 307 or
/// 308, its body (a password or refresh token) unencrypted.
enum InsecureRedirect {
    static func isDowngrade(from current: URLRequest?, to redirected: URLRequest) -> Bool {
        current?.url?.scheme?.lowercased() == "https"
            && redirected.url?.scheme?.lowercased() != "https"
    }

    /// The redirect to follow, or nil to stop and hand the caller the
    /// redirect response itself.
    static func allowed(_ redirected: URLRequest, for task: URLSessionTask) -> URLRequest? {
        isDowngrade(from: task.currentRequest, to: redirected) ? nil : redirected
    }
}

/// Delegate for sessions that send Silo credentials and need nothing else
/// from a delegate.
final class InsecureRedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = InsecureRedirectRefusingDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(InsecureRedirect.allowed(request, for: task))
    }
}
