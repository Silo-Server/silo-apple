#if os(iOS) || os(tvOS)
import CryptoKit
import Foundation

/// SHA-256 helpers shared by every diagnostics consumer, including the
/// SiloTVTopShelf extension. It lives in its own file (rather than alongside
/// `PendingReportStore`) so targets that only compile the logging/redaction
/// slice — where `DiagLog.hostToken` hashes server hostnames — still link it
/// without pulling in the pending-report store.
enum DiagnosticsSHA256 {
    static func hex(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func shortHex(data: Data, count: Int = 16) -> String {
        String(hex(data: data).prefix(count))
    }
}
#endif
