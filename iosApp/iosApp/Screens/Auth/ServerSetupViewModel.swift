import Foundation
import OSLog
import SwiftUI

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

@MainActor
@Observable
class ServerSetupViewModel {
    var host: String = ""
    var selectedScheme: ServerSetupScheme = .auto
    var port: String = ""
    /// What a running connect is for. Set while `isLoading`.
    @ObservationIgnored private var submitted: (host: String, scheme: ServerSetupScheme, port: String)?
    var showsAdvancedOptions: Bool = false
    var isLoading: Bool = false
    /// A failure for the typed address; the address field shows it.
    private(set) var error: FormError?
    /// A failure connecting to a found server; shown beside the found list,
    /// not on the address field the person never used.
    private(set) var discoveryError: FormError?
    /// The found server being connected to, so its row can show progress.
    private(set) var connectingServerID: DiscoveredServer.ID?

    /// Probes one candidate URL and commits it on success.
    typealias ServerCheck = @Sendable (String) async throws -> APIv2SetupStatus
    /// Resolves a bare overlay machine name (`silo`) to its HTTPS origin.
    typealias BareNameResolver = @Sendable (String) async -> String?

    private let checkServer: ServerCheck
    private let resolveBareName: BareNameResolver
    /// Whether the now-active server already has a signed-in session, as when
    /// a saved server is picked from Recent.
    private let hasSession: @Sendable () -> Bool
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "ServerSetup"
    )

    init(
        checkServer: @escaping ServerCheck = { try await AuthService.shared.checkServer(url: $0) },
        hasSession: @escaping @Sendable () -> Bool = { AuthService.shared.isLoggedIn },
        // Typed, so it may wait as long as any address probe: a cold or
        // relayed tailnet path can take longer than background discovery's limit.
        resolveBareName: @escaping BareNameResolver = {
            await OverlayNameResolver(timeout: ServerIdentity.probeTimeout).resolve(name: $0)?.origin
        }
    ) {
        self.checkServer = checkServer
        self.hasSession = hasSession
        self.resolveBareName = resolveBareName
    }

    /// Where a connect started: the address field, or a found server.
    fileprivate enum Source: Equatable {
        /// `bareName` is a typed machine name whose overlay redirect is
        /// looked up once HTTPS fails, before plain HTTP is offered.
        case typed(bareName: String?)
        case discovered(DiscoveredServer.ID)
    }

    /// Set when every secure address failed and the next one is plain HTTP.
    /// The screen asks before anything is sent unencrypted.
    struct InsecurePrompt: Equatable {
        let address: String
        fileprivate let remaining: [String]
        fileprivate let attempted: [String]
        fileprivate let source: Source
    }

    private(set) var insecurePrompt: InsecurePrompt?

    /// Validate the server URL and determine whether setup or login is needed.
    func connect(router: AppRouter) async {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = FormError("Please enter a server host.")
            return
        }

        var candidates: [String]
        do {
            candidates = try buildCandidateURLs()
        } catch {
            self.error = FormError(error.localizedDescription)
            return
        }

        insecurePrompt = nil
        // A bare machine name ("media-box") may be an overlay node whose
        // certificate covers only its full name. Its provider redirects plain
        // HTTP to that HTTPS origin, which `run` looks up once HTTPS fails.
        let allowInsecure = selectedScheme == .http || typedScheme == "http"
        let bareName = selectedScheme == .auto && port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && OverlayNameResolver.isBareName(host) ? host.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        await run(candidates: candidates, attempted: [], allowInsecure: allowInsecure,
                  source: .typed(bareName: bareName), router: router)
    }

    /// Connects to an address discovery found. The address was already
    /// confirmed by its identity; a plain-HTTP one still asks first, like a
    /// typed address that falls back to HTTP.
    func connect(to server: DiscoveredServer, router: AppRouter) async {
        guard !isLoading else { return }
        insecurePrompt = nil
        await run(candidates: [server.url], attempted: [], allowInsecure: false,
                  source: .discovered(server.id), router: router)
    }

    /// Fills in a saved server's address. Its URL already names the scheme
    /// and port, so a protocol or port chosen for an earlier attempt must not
    /// override them.
    func useRecent(_ url: String) {
        host = url
        selectedScheme = .auto
        port = ""
    }

    /// Continues a connect the person agreed to finish over plain HTTP.
    /// `prompt` is the one the alert showed: dismissing the alert clears the
    /// model's copy before this runs.
    func confirmInsecure(_ prompt: InsecurePrompt? = nil, router: AppRouter) async {
        guard let prompt = prompt ?? insecurePrompt else { return }
        insecurePrompt = nil
        await run(candidates: prompt.remaining, attempted: prompt.attempted, allowInsecure: true,
                  source: prompt.source, router: router)
    }

    /// The fields stay enabled while connecting so the keyboard stays up, but
    /// the probe has already committed to what was submitted: an edit made
    /// meanwhile is put back rather than shown over a different server.
    func restoreSubmittedInputs() {
        guard let submitted else { return }
        if host != submitted.host { host = submitted.host }
        if selectedScheme != submitted.scheme { selectedScheme = submitted.scheme }
        if port != submitted.port { port = submitted.port }
    }

    func clearError() {
        error = nil
        discoveryError = nil
    }

    /// The alert went away. Its buttons say whether to connect or give up.
    func dismissInsecurePrompt() {
        insecurePrompt = nil
    }

    /// The person declined plain HTTP. For a typed address that means every
    /// secure address failed; a found server was never tried over HTTPS, so
    /// declining it is not a failure.
    func cancelInsecure(_ prompt: InsecurePrompt? = nil) {
        let source = (prompt ?? insecurePrompt)?.source
        insecurePrompt = nil
        if case .typed = source {
            error = FormError("Could not reach a Silo server at that address over HTTPS.")
        }
    }

    private func run(
        candidates: [String],
        attempted previous: [String],
        allowInsecure: Bool,
        source: Source,
        router: AppRouter
    ) async {
        isLoading = true
        submitted = (host, selectedScheme, port)
        if case .discovered(let id) = source { connectingServerID = id }
        clearError()
        var connected = false
        // After a successful connect the screen fades out to sign-in; it keeps
        // showing "Connecting…" rather than snapping back to its idle state.
        defer {
            if !connected {
                isLoading = false
                submitted = nil
                connectingServerID = nil
            }
        }

        var candidates = candidates
        var attempted = previous
        var lastError: Error?
        var updateRequirement: UpdateRequirement?
        var lookedUpBareName = false
        var index = 0
        while index < candidates.count {
            let candidate = candidates[index]
            if !allowInsecure, candidate.lowercased().hasPrefix("http://") {
                // A secure address already proved a version mismatch; asking to
                // drop encryption would not change the answer.
                if let updateRequirement {
                    fail(FormError(updateRequirement.message), source: source)
                    return
                }
                // Before offering plain HTTP for a typed machine name, ask its
                // overlay provider for the HTTPS origin. Save that origin, never
                // the bare name, which answers reads only and would fail sign-in.
                if case .typed(let bareName?) = source, !lookedUpBareName {
                    lookedUpBareName = true
                    if let origin = await resolveBareName(bareName), !attempted.contains(origin) {
                        candidates.insert(origin, at: index)
                        continue
                    }
                }
                insecurePrompt = InsecurePrompt(
                    address: ServerBranding.hostLabel(candidate),
                    remaining: Array(candidates[index...]),
                    attempted: attempted,
                    source: source
                )
                return
            }
            index += 1
            attempted.append(candidate)
            do {
                let status = try await checkServer(candidate)
                connected = true
                // This view is also pushed onto the login stack (Change
                // Server, then Add Server) while `authState` is already
                // `needsLogin`. Setting the same state is a no-op there, so
                // the stack must be reset explicitly or the setup screen
                // stays put after a successful connect.
                router.popToRoot()
                // A saved server that is still signed in goes straight to its
                // profiles; only a server without a session needs sign-in.
                if !status.needsSetup, hasSession() {
                    router.showProfileSelection()
                    return
                }
                router.authState = .needsLogin
                if status.needsSetup {
                    router.navigate(to: .serverNeedsSetup)
                }
                return
            } catch let connectError {
                lastError = connectError
                // One candidate proving a version mismatch explains the whole
                // attempt, even when a later scheme or port is unreachable.
                updateRequirement = updateRequirement ?? UpdateRequirement(connectError)
            }
        }

        Self.logger.error(
            "Server autodiscovery failed candidates=\(attempted.joined(separator: ", "), privacy: .public) lastError=\(String(describing: lastError), privacy: .public)"
        )
        fail(FormError(updateRequirement?.message ?? "Could not reach a Silo server at that address."), source: source)
    }

    private func fail(_ failure: FormError, source: Source) {
        switch source {
        case .typed: error = failure
        case .discovered: discoveryError = failure
        }
    }

    /// The scheme typed into the address field, if any.
    private var typedScheme: String? {
        let raw = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = raw.range(of: "://") else { return nil }
        return raw[..<range.lowerBound].lowercased()
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

extension View {
    /// Puts back the submitted address, protocol and port when one is edited
    /// during a connect. Undoing the edit after the field has shown it, not
    /// inside the setter, is what makes the field redraw with the restored text.
    func keepsSubmittedServerInputs(_ model: ServerSetupViewModel) -> some View {
        onChange(of: model.host) { model.restoreSubmittedInputs() }
            .onChange(of: model.selectedScheme) { model.restoreSubmittedInputs() }
            .onChange(of: model.port) { model.restoreSubmittedInputs() }
    }

    /// Asks before a connect continues over plain HTTP (`insecurePrompt`).
    func serverInsecurePromptAlert(_ model: ServerSetupViewModel, router: AppRouter) -> some View {
        alert(
            "Connect without encryption?",
            isPresented: Binding(
                get: { model.insecurePrompt != nil },
                set: { if !$0 { model.dismissInsecurePrompt() } }
            ),
            presenting: model.insecurePrompt
        ) { prompt in
            // tvOS lists alert buttons in declaration order and focuses the
            // first; it has always offered Connect there.
            #if os(tvOS)
            Button("Connect") {
                Task { await model.confirmInsecure(prompt, router: router) }
            }
            Button("Cancel", role: .cancel) { model.cancelInsecure(prompt) }
            #else
            Button("Cancel", role: .cancel) { model.cancelInsecure(prompt) }
            Button("Connect") {
                Task { await model.confirmInsecure(prompt, router: router) }
            }
            #endif
        } message: { prompt in
            Text("Your password and what you watch will be sent unencrypted to \(prompt.address). Only do this on a network you trust.")
        }
    }
}
