import Foundation

extension URLRequest {
    /// URLSession surfaces outgoing bodies to URLProtocol as a stream, not
    /// `httpBody`; drain it.
    var drainedHTTPBody: Data {
        if let body = httpBody {
            return body
        }
        guard let stream = httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

extension URLProtocol {
    /// Emit a complete stub HTTP response to the URLSession client.
    func respond(
        status: Int,
        body: String,
        contentType: String = "application/json",
        headers: [String: String] = [:]
    ) {
        var allHeaders = headers
        allHeaders["Content-Type"] = contentType
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: allHeaders
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty {
            client?.urlProtocol(self, didLoad: Data(body.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// XcodeGen may flatten the fixture tree into the bundle root, so try that
/// first and fall back to the on-disk directory layout.
func diagnosticsContractFixtureURL(
    _ fileName: String,
    subdirectory: String? = nil,
    bundleClass: AnyClass
) throws -> URL {
    let bundle = Bundle(for: bundleClass)
    let baseName = (fileName as NSString).deletingPathExtension
    let ext = (fileName as NSString).pathExtension

    if let flattened = bundle.url(forResource: baseName, withExtension: ext) {
        return flattened
    }

    let tail = subdirectory.map { [$0, fileName] } ?? [fileName]
    func candidate(_ roots: [String]) -> URL? {
        guard var url = bundle.resourceURL else { return nil }
        for component in roots + tail {
            url.appendPathComponent(component)
        }
        return url
    }

    let candidates = [
        candidate(["DiagnosticsContract"]),
        candidate(["Fixtures", "DiagnosticsContract"]),
    ].compactMap { $0 }

    for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
    }

    throw NSError(
        domain: "DiagnosticsContractTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Diagnostics contract fixture missing from test bundle: \(fileName)"]
    )
}
