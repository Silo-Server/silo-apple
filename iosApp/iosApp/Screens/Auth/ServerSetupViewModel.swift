import Foundation
import OSLog

enum ServerSetupScheme: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case https = "HTTPS"
    case http = "HTTP"

    var id: String { rawValue }

    var urlScheme: String? {
        switch self {
        case .auto: nil
        case .https: "https"
        case .http: "http"
        }
    }
}

@Observable
class ServerSetupViewModel {
    var host: String = ""
    var selectedScheme: ServerSetupScheme = .auto
    var port: String = ""
    var showsAdvancedOptions: Bool = false
    var isLoading: Bool = false
    var error: String?

    /// Probes one candidate URL; see `AuthService.checkServer(url:)`.
    /// Injectable so tests can drive the error handling without a network.
    private let checkServer: @Sendable (String) async throws -> SetupStatus
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "ServerSetup"
    )

    init(
        checkServer: @escaping @Sendable (String) async throws -> SetupStatus = {
            try await AuthService.shared.checkServer(url: $0)
        }
    ) {
        self.checkServer = checkServer
    }

    /// Validate the server URL and determine whether setup or login is needed.
    func connect(router: AppRouter) async {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Please enter a server host."
            return
        }

        let candidates: [String]
        do {
            candidates = try buildCandidateURLs()
        } catch let validationError as ServerSetupValidationError {
            error = validationError.localizedDescription
            return
        } catch {
            self.error = error.localizedDescription
            return
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        var attempted: [String] = []
        var lastError: Error?
        // A candidate that answered but is v1-only is a verdict about the
        // server, not a connectivity failure. It is not the active server, so
        // nothing is recorded in ConnectionMonitor and no Home pill will
        // appear; the message has to be shown here. It wins over "could not
        // reach" from the other candidates, which typically fail on the same
        // host with a different scheme or port.
        var sawUpdateRequired = false
        for candidate in candidates {
            attempted.append(candidate)
            do {
                let status = try await checkServer(candidate)
                router.authState = .needsLogin
                if status.needsSetup {
                    router.navigate(to: .serverNeedsSetup)
                }
                return
            } catch APIv2Error.serverUpdateRequired {
                sawUpdateRequired = true
                lastError = APIv2Error.serverUpdateRequired
            } catch let connectError {
                lastError = connectError
            }
        }

        Self.logger.error(
            "Server autodiscovery failed candidates=\(attempted.joined(separator: ", "), privacy: .public) lastError=\(String(describing: lastError), privacy: .public)"
        )
        self.error = sawUpdateRequired
            ? APIv2Error.serverUpdateRequiredMessage
            : "Could not reach a Silo server at that address."
    }

    func buildCandidateURLs() throws -> [String] {
        let parsed = try parseInput()
        let explicitPort = try normalizedPort(parsed.portOverride ?? port)
        let schemes = candidateSchemes(parsedScheme: parsed.schemeOverride)

        var candidates: [String] = []
        for scheme in schemes {
            candidates.append(try makeURL(scheme: scheme, host: parsed.host, port: explicitPort, path: parsed.path))
        }

        if selectedScheme == .auto, explicitPort == nil {
            candidates.append(try makeURL(scheme: "http", host: parsed.host, port: "8090", path: parsed.path))
        }

        return unique(candidates)
    }

    private func candidateSchemes(parsedScheme: String?) -> [String] {
        if let explicit = selectedScheme.urlScheme {
            return [explicit]
        }
        if let parsedScheme {
            return [parsedScheme]
        }
        return ["https", "http"]
    }

    private func parseInput() throws -> ParsedServerInput {
        let rawHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !rawHost.isEmpty else {
            throw ServerSetupValidationError.missingHost
        }

        let parseValue = rawHost.contains("://") ? rawHost : "https://\(rawHost)"
        if let components = URLComponents(string: parseValue),
           let parsedHost = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
           !parsedHost.isEmpty {
            let parsedScheme = rawHost.contains("://") ? components.scheme?.lowercased() : nil
            let parsedPort = components.port.map(String.init)
            return ParsedServerInput(
                schemeOverride: parsedScheme,
                host: parsedHost,
                portOverride: parsedPort,
                path: normalizedPath(components.percentEncodedPath)
            )
        }

        throw ServerSetupValidationError.invalidHost
    }

    private func normalizedPort(_ value: String) throws -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.allSatisfy(\.isNumber),
              let intValue = Int(trimmed),
              (1...65535).contains(intValue) else {
            throw ServerSetupValidationError.invalidPort
        }
        return String(intValue)
    }

    private func normalizedPath(_ path: String) -> String {
        guard !path.isEmpty, path != "/" else { return "" }
        var normalized = path
        while normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized
    }

    private func makeURL(scheme: String, host: String, port: String?, path: String) throws -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if let port, !isDefaultPort(port, for: scheme) {
            components.port = Int(port)
        }
        components.percentEncodedPath = path
        guard let url = components.url?.absoluteString else {
            throw ServerSetupValidationError.invalidHost
        }
        return ServerRegistry.normalize(url: url)
    }

    private func isDefaultPort(_ port: String, for scheme: String) -> Bool {
        (scheme == "https" && port == "443") || (scheme == "http" && port == "80")
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

private struct ParsedServerInput {
    let schemeOverride: String?
    let host: String
    let portOverride: String?
    let path: String
}

private enum ServerSetupValidationError: LocalizedError {
    case missingHost
    case invalidHost
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .missingHost:
            return "Please enter a server host."
        case .invalidHost:
            return "Please enter a valid server host."
        case .invalidPort:
            return "Port must be a number between 1 and 65535."
        }
    }
}
