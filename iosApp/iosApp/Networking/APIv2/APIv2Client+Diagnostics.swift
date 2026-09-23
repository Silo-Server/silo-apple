#if os(iOS) || os(tvOS)
import Foundation

extension APIv2Client {
    // MARK: getDiagnosticsCapabilities (authenticated, no profile required)

    /// Reads diagnostics upload availability and limits for the account,
    /// discarded if the owner changed while the request was in flight.
    func diagnosticsCapabilities() async throws -> DiagnosticsStatusResponse {
        let wire: APIv2DiagnosticsCapabilities = try await requestGet("/api/v2/diagnostics/capabilities")
        return wire.statusResponse
    }
}
#endif
