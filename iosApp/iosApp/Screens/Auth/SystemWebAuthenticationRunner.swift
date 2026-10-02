#if !os(tvOS)
import AuthenticationServices
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// What the runner needs from `ASWebAuthenticationSession`; tests stand in
/// a fake.
@MainActor
protocol WebAuthenticationSessionHandle: AnyObject {
    func start() -> Bool
    func cancel()
}

extension ASWebAuthenticationSession: WebAuthenticationSessionHandle {}

/// `ASWebAuthenticationSession`, non-ephemeral so an existing sign-in at the
/// provider in the system browser is reused (and passkeys work). Never a web
/// view. One flow at a time.
@MainActor
final class SystemWebAuthenticationRunner: NSObject, WebAuthenticationRunning, ASWebAuthenticationPresentationContextProviding {
    static let shared = SystemWebAuthenticationRunner()

    /// Makes the session for a start URL and callback scheme; the closure
    /// receives the redirect or the error.
    typealias MakeSession = @MainActor (URL, String, SystemWebAuthenticationRunner,
                                        @escaping @Sendable (URL?, Error?) -> Void) -> WebAuthenticationSessionHandle

    private let makeSession: MakeSession
    private var session: WebAuthenticationSessionHandle?
    private var continuation: CheckedContinuation<URL, Error>?
    /// The `app_state` of the flow in progress, read from its start URL. An
    /// app redirect that arrives through URL routing must carry it as
    /// `state` to end the flow.
    private var pendingState: String?
    /// Numbers each `authenticate` call. A cancellation or session answer
    /// from an earlier flow names its own attempt and never ends a newer one.
    private var attempt: UInt = 0

    init(makeSession: @escaping MakeSession = SystemWebAuthenticationRunner.systemSession) {
        self.makeSession = makeSession
    }

    static func systemSession(url: URL, callbackScheme: String, provider: SystemWebAuthenticationRunner,
                                      completion: @escaping @Sendable (URL?, Error?) -> Void) -> WebAuthenticationSessionHandle {
        let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme), completionHandler: completion)
        session.presentationContextProvider = provider
        session.prefersEphemeralWebBrowserSession = false
        return session
    }

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        cancelCurrent()
        attempt &+= 1
        let attempt = attempt
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: ExternalSignInError.canceled)
                    return
                }
                self.continuation = continuation
                self.pendingState = Self.queryValue("app_state", in: url)
                let session = makeSession(url, callbackScheme, self) { [weak self] callbackURL, error in
                    Task { @MainActor in
                        if let callbackURL {
                            self?.finish(.success(callbackURL), attempt: attempt)
                        } else if let authError = error as? ASWebAuthenticationSessionError,
                                  authError.code == .canceledLogin {
                            self?.finish(.failure(ExternalSignInError.canceled), attempt: attempt)
                        } else {
                            self?.finish(.failure(ExternalSignInError.browserUnavailable), attempt: attempt)
                        }
                    }
                }
                self.session = session
                if !session.start() {
                    finish(.failure(ExternalSignInError.browserUnavailable))
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(ExternalSignInError.canceled), attempt: attempt) }
        }
    }

    /// Hands an app redirect that arrived through the system's URL routing
    /// (a registered scheme, as on macOS with a browser that does not return
    /// it to the session) to the flow in progress. Only a redirect whose
    /// `state` is the flow's own `app_state` ends it; any other URL with the
    /// scheme is ignored and the sign-in stays open. Returns whether a flow
    /// took it; the flow still checks its state, server and iss.
    @discardableResult
    func receiveExternalCallback(_ url: URL) -> Bool {
        guard continuation != nil, NativeSignIn.isCallback(url),
              let pendingState, !pendingState.isEmpty,
              Self.queryValue("state", in: url) == pendingState else { return false }
        finish(.success(url))
        return true
    }

    /// The first value of the query item `name`, as the callback parser
    /// reads it.
    private static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    private func cancelCurrent() {
        finish(.failure(ExternalSignInError.canceled))
    }

    /// Ends the flow only while `attempt` is still the one in progress.
    private func finish(_ result: Result<URL, Error>, attempt: UInt) {
        guard attempt == self.attempt else { return }
        finish(result)
    }

    private func finish(_ result: Result<URL, Error>) {
        let pending = continuation
        continuation = nil
        pendingState = nil
        let finished = session
        session = nil
        guard let pending else { return }
        finished?.cancel()
        pending.resume(with: result)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { Self.anchor() }
    }

    private static func anchor() -> ASPresentationAnchor {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        if let window = windows.first(where: \.isKeyWindow) ?? windows.first {
            return window
        }
        if let scene = scenes.first { return UIWindow(windowScene: scene) }
        return ASPresentationAnchor()
        #else
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #endif
    }
}

extension ExternalSignInService {
    /// The app's service: the shared v2 client and token store, the system
    /// browser, and the saved server's verified identity.
    static let live = ExternalSignInService(
        api: SiloAPI.shared.apiV2Client,
        tokenStore: .shared,
        runner: SystemWebAuthenticationRunner.shared,
        verifiedServerId: { await AuthService.shared.verifiedIdentityOfActiveServer() },
        installSession: { tokens, expectedAccount in
            try await AuthService.shared.installSession(
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken,
                accountID: tokens.user.id,
                expectedAccount: expectedAccount
            )
        }
    )
}
#endif
