#if canImport(AetherEngine)
import AetherEngine
#endif
import CryptoKit
import Foundation
import Security
import Synchronization

/// The keys the local route trusts, by host and port. A connection to a
/// registered address succeeds only when the server presents the pinned key;
/// no other certificate, publicly valid or not, is ever accepted there.
/// Every other address keeps the system's handling untouched.
enum LocalRouteTrust {
    private static let pins = Mutex<[String: String]>([:])

    /// Trust `pin` for the host and port of `origin` (`https://host:port`).
    static func trust(_ origin: String, pin: String) {
        guard let key = key(forOrigin: origin) else { return }
        pins.withLock { $0[key] = pin }
    }

    /// Forget every pinned address, when the active server or its key changes.
    /// The playback engine goes back to the system's handling everywhere.
    static func removeAll() {
        pins.withLock { $0.removeAll() }
        #if canImport(AetherEngine)
        EngineTLS.serverTrustEvaluator = nil
        #endif
    }

    /// Nil when `space` is not a pinned address (leave it to the system);
    /// otherwise whether the presented key matches the pin.
    static func evaluate(_ space: URLProtectionSpace) -> Bool? {
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let pin = pins.withLock({ $0[key(host: space.host, port: space.port)] }) else { return nil }
        guard let trust = space.serverTrust, let presented = spkiPin(of: trust) else { return false }
        return presented == pin
    }

    /// Answers a server-trust challenge for the app's own sessions.
    static func handle(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch evaluate(challenge.protectionSpace) {
        case nil:
            completionHandler(.performDefaultHandling, nil)
        case true?:
            guard let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        case false?:
            LocalRouteController.reportKeyMismatch(
                host: challenge.protectionSpace.host, port: challenge.protectionSpace.port)
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// Base64 SHA-256 of the leaf certificate's SubjectPublicKeyInfo, the form
    /// `local_route.spki_sha256` carries. Only P-256 keys, the kind the server
    /// derives, have one here; any other key never matches.
    static func spkiPin(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              let key = SecCertificateCopyKey(leaf) else { return nil }
        return spkiPin(of: key)
    }

    static func spkiPin(of key: SecKey) -> String? {
        guard let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
              attributes[kSecAttrKeyType] as? String == kSecAttrKeyTypeECSECPrimeRandom as String,
              let point = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let publicKey = try? P256.Signing.PublicKey(x963Representation: point) else { return nil }
        return Data(SHA256.hash(data: publicKey.derRepresentation)).base64EncodedString()
    }

    private static func key(forOrigin origin: String) -> String? {
        guard let url = URL(string: origin), let host = url.host else { return nil }
        return key(host: host, port: url.port ?? 443)
    }

    private static func key(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }
}

/// Session delegate that applies `LocalRouteTrust` to the app's own sessions:
/// the API client and the artwork loader. It also refuses HTTPS-to-HTTP
/// redirects (`InsecureRedirect`).
final class LocalRouteTrustDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = LocalRouteTrustDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(InsecureRedirect.allowed(request, for: task))
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        LocalRouteTrust.handle(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        LocalRouteTrust.handle(challenge, completionHandler: completionHandler)
    }
}

#if canImport(AetherEngine)
extension LocalRouteTrust {
    /// Lets the playback engine's own sessions reach the local route: Aether
    /// asks once per challenge whether to accept a certificate that failed
    /// system trust. Only a pinned address presenting its pinned key is
    /// accepted; everything else keeps the system's answer. Installed only
    /// once a route is in use: with any evaluator set, Aether checks system
    /// trust before each HTTPS stream it loads without per-request
    /// authorization.
    static func installEngineEvaluator() {
        EngineTLS.serverTrustEvaluator = { space in
            switch evaluate(space) {
            case true?:
                return true
            case false?:
                LocalRouteController.reportKeyMismatch(host: space.host, port: space.port)
                return false
            case nil:
                return false
            }
        }
    }
}
#endif
