#if os(iOS) || os(tvOS)
import Foundation
import Nuke
import OSLog

/// Privacy-safe evidence for image failures that bypass `HTTPClient`.
///
/// Nuke downloads artwork directly, so those requests never pass through the
/// app's normal network diagnostics. This delegate records only the failure
/// class, HTTP status, and a closed artwork kind/rung. It must never record the
/// URL, host, object key, title, or query because S3 URLs can contain both
/// private library data and signing credentials.
final class PosterImagePipelineDiagnostics: ImagePipelineDelegate, @unchecked Sendable {
    static let shared = PosterImagePipelineDiagnostics()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "image.pipeline"
    )

    private let limiter = PosterImageDiagnosticLimiter()

    private init() {}

    func imageTask(
        _ task: ImageTask,
        didReceiveEvent event: ImageTask.Event,
        pipeline: ImagePipeline
    ) {
        guard case .finished(.failure(let error)) = event,
              let failure = PosterImageFailureClassifier.classify(
                  error: error,
                  url: task.request.url
              ),
              limiter.shouldRecord(
                  url: task.request.url,
                  path: failure.path,
                  errorCode: failure.errorCode
              ) else {
            return
        }

        let status = failure.status.map(String.init) ?? "none"
        Self.logger.error(
            "image load failed path=\(failure.path, privacy: .public) code=\(failure.errorCode, privacy: .public) status=\(status, privacy: .public)"
        )
        #if DEBUG
        // `devicectl --console` does not consistently forward unified Logger
        // events from physical tvOS. Mirror this already-sanitized line to
        // stdout in development builds so a live device repro is observable.
        print(
            "[ImageDiag] image load failed "
                + "path=\(failure.path) code=\(failure.errorCode) status=\(status)"
        )
        #endif

        var attrs: [String: DiagLogAttributeValue] = [
            "method": .string("GET"),
            "path": .string(failure.path),
            "outcome": .string("image_load_failed"),
            "error_code": .string(failure.errorCode),
        ]
        if let status = failure.status {
            attrs["status"] = .int(status)
        }

        DiagTrace.log(
            .essential,
            level: .error,
            category: .network,
            tag: "Image",
            message: "image load failed",
            attrs: attrs
        )
    }
}

struct PosterImageFailureDiagnostic: Equatable {
    let path: String
    let errorCode: String
    let status: Int?
}

enum PosterImageFailureClassifier {
    private static let artworkKinds = Set([
        "backdrop", "logo", "poster", "profile", "still", "thumb",
    ])

    static func classify(
        error: ImagePipeline.Error,
        url: URL?
    ) -> PosterImageFailureDiagnostic? {
        let path = artworkPath(for: url)

        switch error {
        case .dataLoadingFailed(let underlying):
            if let loaderError = underlying as? DataLoader.Error,
               case .statusCodeUnacceptable(let status) = loaderError {
                return PosterImageFailureDiagnostic(
                    path: path,
                    errorCode: "http_status",
                    status: status
                )
            }

            if let urlError = underlying as? URLError {
                guard let code = transportErrorCode(for: urlError.code) else {
                    return nil
                }
                return PosterImageFailureDiagnostic(path: path, errorCode: code, status: nil)
            }

            if underlying is CancellationError {
                return nil
            }
            return PosterImageFailureDiagnostic(
                path: path,
                errorCode: "data_load_failed",
                status: nil
            )

        case .dataIsEmpty:
            return PosterImageFailureDiagnostic(path: path, errorCode: "empty_data", status: nil)
        case .decoderNotRegistered:
            return PosterImageFailureDiagnostic(path: path, errorCode: "decoder_unavailable", status: nil)
        case .decodingFailed:
            return PosterImageFailureDiagnostic(path: path, errorCode: "decode_failed", status: nil)
        case .processingFailed:
            return PosterImageFailureDiagnostic(path: path, errorCode: "processing_failed", status: nil)
        case .dataMissingInCache, .imageRequestMissing, .pipelineInvalidated:
            // These are local control-flow states, not evidence that the
            // artwork endpoint or downloaded bytes failed.
            return nil
        }
    }

    /// Returns a synthetic diagnostics route, never any portion of the object
    /// key except closed vocabulary such as `poster` and `w780`.
    static func artworkPath(for url: URL?) -> String {
        let components = url?.pathComponents.map { $0.lowercased() } ?? []
        let kind = components.first(where: artworkKinds.contains) ?? "image"
        let rung = components.compactMap(artworkRung).first ?? "other"
        return "/artwork/\(kind)/\(rung)"
    }

    static func transportErrorCode(for code: URLError.Code) -> String? {
        switch code {
        case .cancelled:
            return nil
        case .timedOut:
            return "transport_timeout"
        case .cannotFindHost:
            return "transport_dns"
        case .cannotConnectToHost:
            return "transport_connect"
        case .networkConnectionLost:
            return "transport_connection_lost"
        case .notConnectedToInternet:
            return "transport_offline"
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired,
             .appTransportSecurityRequiresSecureConnection:
            return "transport_tls"
        default:
            return "transport_error"
        }
    }

    private static func artworkRung(in component: String) -> String? {
        // Public URLs use filenames such as `w780.<content-hash>.webp`,
        // while older/object-store layouts may use `w780` as a directory.
        let candidate = String(component.split(separator: ".", maxSplits: 1)[0])
        if candidate == "original" {
            return candidate
        }
        guard candidate.first == "w", candidate.count <= 6 else {
            return nil
        }
        return candidate.dropFirst().allSatisfy(\.isNumber) ? candidate : nil
    }
}

/// Suppresses duplicate processed/prefetch failures without retaining a URL.
/// `Hasher` is process-random, so the in-memory key cannot become a stable
/// identifier if it is ever inspected in a memory graph.
private final class PosterImageDiagnosticLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var windowStartedAt = Date()
    private var emittedInWindow = 0
    private var recentFailures: [Int: Date] = [:]

    private let windowDuration: TimeInterval = 10 * 60
    private let duplicateCooldown: TimeInterval = 5 * 60
    private let maximumEmissionsPerWindow = 50

    func shouldRecord(url: URL?, path: String, errorCode: String, now: Date = Date()) -> Bool {
        var hasher = Hasher()
        hasher.combine(url?.absoluteString)
        hasher.combine(path)
        hasher.combine(errorCode)
        let fingerprint = hasher.finalize()

        lock.lock()
        defer { lock.unlock() }

        if now.timeIntervalSince(windowStartedAt) >= windowDuration {
            windowStartedAt = now
            emittedInWindow = 0
            recentFailures = recentFailures.filter {
                now.timeIntervalSince($0.value) < duplicateCooldown
            }
        }

        if let previous = recentFailures[fingerprint],
           now.timeIntervalSince(previous) < duplicateCooldown {
            return false
        }
        guard emittedInWindow < maximumEmissionsPerWindow else {
            return false
        }

        recentFailures[fingerprint] = now
        emittedInWindow += 1
        return true
    }
}
#endif
