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

    // MARK: Report uploads (authenticated)
    //
    // Every request runs under the owner the caller captured for the whole
    // upload. The selected profile, if any, goes out as `X-Profile-Id`, which
    // v2 reads as the report's attribution.

    /// `uploadDiagnosticsReport` (`non_retryable`): the manifest part, then the
    /// bundle part. Expects 201.
    func uploadDiagnosticsReport(manifestData: Data, bundleData: Data,
                                 auth: CapturedOrdinaryRequestAuth) async throws -> DiagnosticsUploadResponse {
        let boundary = "SiloDiagnostics-\(UUID().uuidString)"
        let body = HTTPClient.multipartBody(parts: [
            HTTPMultipartPart(name: "manifest", filename: "manifest.json", contentType: "application/json",
                              data: manifestData),
            HTTPMultipartPart(name: "bundle", filename: "bundle.tar.gz", contentType: "application/gzip",
                              data: bundleData),
        ], boundary: boundary)
        let raw = try await ownedRequest(method: "POST", path: "/api/v2/diagnostics/reports", body: body,
            contentType: "multipart/form-data; boundary=\(boundary)", timeout: .extended, auth: auth)
        return try Self.diagnosticsIngestResult(raw)
    }

    /// `createDiagnosticsUpload` (`non_retryable`). Expects 201.
    ///
    /// The manifest bytes are spliced into the body verbatim rather than
    /// re-encoded: the server compares the received manifest against the
    /// archive's embedded `manifest.json`, and re-serializing could reorder
    /// keys and break that equality.
    func createDiagnosticsUpload(manifestData: Data, bundleBytes: Int,
                                 auth: CapturedOrdinaryRequestAuth) async throws -> APIv2DiagnosticsUploadSession {
        var body = Data(#"{"bundle_bytes":\#(bundleBytes),"manifest":"#.utf8)
        body.append(manifestData)
        body.append(Data("}".utf8))
        let raw = try await ownedRequest(method: "POST", path: "/api/v2/diagnostics/reports/uploads", body: body,
            auth: auth)
        guard raw.statusCode == 201,
              let session = try? HTTPClient.makeJSONDecoder().decode(APIv2DiagnosticsUploadSession.self, from: raw.data),
              CatalogPathSegment.encode(session.uploadId) != nil else {
            throw APIv2DiagnosticsUnexpectedResponse(status: raw.statusCode)
        }
        return session
    }

    /// `putDiagnosticsUploadChunk` (`natural_idempotent`). Expects 200.
    func putDiagnosticsUploadChunk(uploadID: String, index: Int, data: Data,
                                   auth: CapturedOrdinaryRequestAuth) async throws {
        let raw = try await ownedRequest(method: "PUT",
            path: "\(try Self.diagnosticsUploadPath(uploadID))/chunks/\(index)", body: data,
            contentType: "application/octet-stream", timeout: .extended, auth: auth)
        guard raw.statusCode == 200 else { throw APIv2DiagnosticsUnexpectedResponse(status: raw.statusCode) }
    }

    /// `completeDiagnosticsUpload` (`non_retryable`). Expects 201.
    func completeDiagnosticsUpload(uploadID: String,
                                   auth: CapturedOrdinaryRequestAuth) async throws -> DiagnosticsUploadResponse {
        let raw = try await ownedRequest(method: "POST",
            path: "\(try Self.diagnosticsUploadPath(uploadID))/complete", timeout: .extended, auth: auth)
        return try Self.diagnosticsIngestResult(raw)
    }

    /// `abortDiagnosticsUpload` (`natural_idempotent`). Expects 204.
    func abortDiagnosticsUpload(uploadID: String, auth: CapturedOrdinaryRequestAuth) async throws {
        let raw = try await ownedRequest(method: "DELETE", path: try Self.diagnosticsUploadPath(uploadID), auth: auth)
        guard raw.statusCode == 204 else { throw APIv2DiagnosticsUnexpectedResponse(status: raw.statusCode) }
    }

    private static func diagnosticsUploadPath(_ uploadID: String) throws -> String {
        guard let segment = CatalogPathSegment.encode(uploadID) else {
            throw APIv2DiagnosticsUnexpectedResponse(status: 0)
        }
        return "/api/v2/diagnostics/reports/uploads/\(segment)"
    }

    private static func diagnosticsIngestResult(_ raw: HTTPRawResponse) throws -> DiagnosticsUploadResponse {
        guard raw.statusCode == 201,
              let result = try? HTTPClient.makeJSONDecoder().decode(APIv2DiagnosticsIngestResult.self, from: raw.data),
              !result.reportId.isEmpty, !result.shortId.isEmpty else {
            throw APIv2DiagnosticsUnexpectedResponse(status: raw.statusCode)
        }
        return result.response
    }
}
#endif
