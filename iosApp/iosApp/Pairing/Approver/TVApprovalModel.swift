import Foundation
import Observation

/// Network seam for approving a TV's sign-in code from this device, against
/// one saved server named explicitly (it need not be the active one).
protocol TVApprovalAPI: Sendable {
    /// A bearer for the saved server, renewed first when it has expired or
    /// is about to, or why there is none.
    func bearer(serverId: String) async -> ApproverBearer
    func lookup(serverURL: String, bearer: String, code: String) async throws -> DeviceLookupResponse
    func approve(serverURL: String, bearer: String, code: String) async throws
    func deny(serverURL: String, bearer: String, code: String) async throws
    /// Who approving would sign the TV in as.
    func accountName(serverURL: String, bearer: String) async -> String?
    /// What "Not you?" on the card can offer on the server.
    func accountSwitch(serverURL: String) async -> TVApprovalAccountSwitch
}

/// What "Not you?" on the approval card offers. In every case it signs out of
/// the server in Silo only; the difference is what the next sign-in lets the
/// person do.
enum TVApprovalAccountSwitch: Equatable, Sendable {
    /// The server lists a browser provider and advertises `select_account`:
    /// the provider is asked to let the person choose an account.
    case chooseAccount
    /// No browser provider: the password form that follows lets the person
    /// choose the account.
    case switchAccount
    /// A browser provider without `select_account` (or discovery could not
    /// be read): the provider may sign the same person straight back in, so
    /// the card promises only a sign-out.
    case signOut

    /// The rule for a server's discovery; nil is discovery that could not
    /// be read.
    init(_ options: SignInOptions?) {
        guard let options else { self = .signOut; return }
        if options.browserProviders.isEmpty {
            self = .switchAccount
        } else {
            self = options.supportsSelectAccount ? .chooseAccount : .signOut
        }
    }
}

struct LiveTVApprovalAPI: TVApprovalAPI {
    var devices = PairingDeviceAPI()

    func bearer(serverId: String) async -> ApproverBearer {
        await HTTPClient.shared.freshAccessToken(serverId: serverId)
    }

    func lookup(serverURL: String, bearer: String, code: String) async throws -> DeviceLookupResponse {
        try await devices.lookup(serverURL: serverURL, bearer: bearer, userCode: code)
    }

    func approve(serverURL: String, bearer: String, code: String) async throws {
        try await devices.approve(serverURL: serverURL, bearer: bearer, userCode: code)
    }

    func deny(serverURL: String, bearer: String, code: String) async throws {
        try await devices.deny(serverURL: serverURL, bearer: bearer, userCode: code)
    }

    func accountName(serverURL: String, bearer: String) async -> String? {
        let account: APIv2Account? = try? await HTTPClient.shared.getWithBearer(
            serverURL: serverURL, path: "/api/v2/account/me", bearer: bearer, timeout: ServerIdentity.probeTimeout
        )
        return account.flatMap { ServerIdentity.usable($0.username) }
    }

    func accountSwitch(serverURL: String) async -> TVApprovalAccountSwitch {
        TVApprovalAccountSwitch(await SiloAPI.shared.apiV2Client.signInOptions(serverURL: serverURL))
    }
}

/// One TV sign-in request as the approval card shows it.
struct TVApprovalRequest: Equatable, Sendable {
    /// The code grouped for display (`4821 7730`).
    let code: String
    let deviceName: String
    /// "Apple TV", "Android TV", or nil when the platform is unknown.
    let platformLabel: String?
    let serverName: String
    let serverHost: String
    let accountName: String?
    /// Partially masked address the request came from.
    let networkHint: String?
    /// When the TV started the request; absent from older servers.
    var requestedAt: Date? = nil
}

/// Approving a TV from the phone: look the code up on one chosen server,
/// show what approving grants, then approve ("Sign in TV") or deny ("Not
/// now"), and follow the request until the TV has collected its session.
///
/// The code is looked up only on the server the user chose. Nothing here
/// tries other servers; the caller offers them when the code isn't found.
@MainActor
@Observable
final class TVApprovalModel {
    enum Phase: Equatable {
        case idle
        case lookingUp
        case review(TVApprovalRequest)
        case approving(TVApprovalRequest)
        /// Approved. `tvSignedIn` flips once the TV collected its session.
        case approved(TVApprovalRequest, tvSignedIn: Bool)
        /// "Not now" is being sent.
        case declining(TVApprovalRequest)
        /// This device declined the request.
        case declined
        /// Someone else declined the request (another phone or the web page).
        case declinedElsewhere
        /// The TV withdrew the request: it left the screen, signed in with a
        /// password, or showed a new code.
        case canceled
        /// The chosen server has no pending request with this code.
        case notFound(serverName: String)
        case expired
        case alreadyUsed
        /// This device is no longer signed in to the chosen server.
        case needsSignIn(serverName: String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// What "Not you?" offers on this server; a plain sign-out until the
    /// lookup has read the server's discovery.
    private(set) var accountSwitch: TVApprovalAccountSwitch = .signOut
    /// Whether "Not you?" asks the provider for an account choice.
    var offersAccountChoice: Bool { accountSwitch == .chooseAccount }
    let server: ServerEntry
    let code: String

    private let api: any TVApprovalAPI
    private let watchInterval: Duration
    private let watchLimit: Int
    private var watchTask: Task<Void, Never>?
    /// The bearer the review was read with. Approving with another one (it
    /// was renewed, or the saved session changed) first checks that it still
    /// signs in the account the card showed.
    private var reviewedBearer: String?

    init(
        server: ServerEntry,
        code: String,
        api: any TVApprovalAPI = LiveTVApprovalAPI(),
        watchInterval: Duration = .seconds(3),
        watchLimit: Int = 40
    ) {
        self.server = server
        self.code = DeviceUserCode.normalized(code)
        self.api = api
        self.watchInterval = watchInterval
        self.watchLimit = watchLimit
    }

    private var serverName: String { server.displayName }

    func lookUp() async {
        phase = .lookingUp
        guard let bearer = await bearerOrFailure() else { return }
        do {
            let lookup = try await api.lookup(serverURL: server.url, bearer: bearer, code: code)
            guard lookup.temporary != true, lookup.clientPurpose.map({ $0 == "device_login" }) ?? true else {
                phase = .failed("This code isn't for signing in a TV.")
                return
            }
            switch lookup.status ?? "pending" {
            case "pending":
                let api = self.api, serverURL = server.url
                async let account = api.accountName(serverURL: serverURL, bearer: bearer)
                async let accountSwitch = api.accountSwitch(serverURL: serverURL)
                self.accountSwitch = await accountSwitch
                reviewedBearer = bearer
                phase = .review(request(from: lookup, account: await account))
            case "approved", "consumed":
                phase = .alreadyUsed
            case "denied":
                phase = .declinedElsewhere
            case "canceled":
                phase = .canceled
            default: // expired
                phase = .expired
            }
        } catch {
            phase = failure(for: error, notFound: .notFound(serverName: serverName))
        }
    }

    func approve() async {
        guard case .review(let request) = phase else { return }
        phase = .approving(request)
        guard let bearer = await bearerOrFailure() else { return }
        if bearer != reviewedBearer {
            // The TV gets a session for whoever this bearer belongs to. If
            // that is not the account the card showed, show the card again.
            let account = await api.accountName(serverURL: server.url, bearer: bearer)
            guard let account, account == request.accountName else {
                await lookUp()
                return
            }
        }
        do {
            try await api.approve(serverURL: server.url, bearer: bearer, code: code)
            phase = .approved(request, tvSignedIn: false)
            watch(request, bearer: bearer)
        } catch {
            // An approval is sent once. A 404 after a successful lookup
            // means the request expired in between.
            guard error is URLError else {
                phase = failure(for: error, notFound: .expired)
                return
            }
            await confirmLostApproval(request, bearer: bearer)
        }
    }

    /// The approve answer was lost, so the server may have taken the
    /// approval or still be applying it. Stay in `.approving` (the card
    /// offers nothing to tap) and read the request back a few times. Never
    /// call it failed while it may still land; the server applies an
    /// approval once, and repeating it for the same account is a no-op.
    private func confirmLostApproval(_ request: TVApprovalRequest, bearer: String) async {
        for attempt in 0..<Self.lostApprovalReads {
            if attempt > 0 { try? await Task.sleep(for: watchInterval) }
            switch try? await api.lookup(serverURL: server.url, bearer: bearer, code: code).status {
            case "approved"?:
                phase = .approved(request, tvSignedIn: false)
                watch(request, bearer: bearer)
                return
            case "consumed"?:
                phase = .approved(request, tvSignedIn: true)
                return
            case "denied"?:
                phase = .declinedElsewhere
                return
            case "canceled"?:
                phase = .canceled
                return
            case "expired"?:
                phase = .expired
                return
            default: // still pending, or unreadable
                continue
            }
        }
        phase = .failed("Couldn't confirm that \(serverName) approved the TV. If the TV is still waiting, approve its code again.")
    }

    private static let lostApprovalReads = 3

    /// "Not now": deny the request. The TV stops waiting and says the
    /// sign-in was declined. `declined` shows only once the server took it.
    func decline() async {
        guard case .review(let request) = phase else { return }
        phase = .declining(request)
        guard let bearer = await bearerOrFailure() else { return }
        do {
            try await api.deny(serverURL: server.url, bearer: bearer, code: code)
            phase = .declined
        } catch {
            phase = failure(for: error, notFound: .expired)
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
    }

    /// Follow the request until the TV collected its session, so the card
    /// can say "Your TV is signed in." Bounded; lookups are rate-limited.
    private func watch(_ request: TVApprovalRequest, bearer: String) {
        watchTask?.cancel()
        let api = self.api, server = self.server, code = self.code
        let interval = watchInterval, limit = watchLimit
        watchTask = Task { @MainActor [weak self] in
            for _ in 0..<limit {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                let status = try? await api.lookup(serverURL: server.url, bearer: bearer, code: code).status
                guard let self, case .approved = self.phase else { return }
                switch status {
                case "consumed"?:
                    self.phase = .approved(request, tvSignedIn: true)
                    return
                case "denied"?:
                    self.phase = .declinedElsewhere
                    return
                case "canceled"?:
                    self.phase = .canceled
                    return
                case "expired"?:
                    self.phase = .expired
                    return
                default:
                    continue
                }
            }
        }
    }

    private func request(from lookup: DeviceLookupResponse, account: String?) -> TVApprovalRequest {
        TVApprovalRequest(
            code: DeviceUserCode.display(ServerIdentity.usable(lookup.userCode) ?? code),
            deviceName: ServerIdentity.usable(lookup.deviceName) ?? "TV",
            platformLabel: Self.platformLabel(lookup.devicePlatform),
            serverName: ServerIdentity.usable(lookup.serverName) ?? serverName,
            serverHost: TVSignInPresentation.host(of: server.url),
            accountName: account,
            networkHint: ServerIdentity.usable(lookup.ipAddressHint),
            requestedAt: lookup.requestedAt
        )
    }

    /// The server's bearer, or nil after setting the phase that says why
    /// there is none. Only a session the server refused asks the person to
    /// sign in again; an outage keeps the session and says so.
    private func bearerOrFailure() async -> String? {
        switch await api.bearer(serverId: server.id) {
        case .token(let token) where !token.isEmpty:
            return token
        case .token, .rejected:
            phase = .needsSignIn(serverName: serverName)
        case .providerUnavailable:
            phase = .failed(ExternalSignInError.reasonText("provider_unavailable"))
        case .unreachable:
            phase = .failed(unreachableMessage)
        }
        return nil
    }

    private var unreachableMessage: String { "Couldn't reach \(serverName). Check this device's connection." }

    private func failure(for error: Error, notFound: Phase) -> Phase {
        if let requirement = UpdateRequirement(error) { return .failed(requirement.message) }
        let status: Int?
        switch error {
        case APIv2Error.problem(let problem): status = problem.status
        case APIv2Error.httpStatus(let code): status = code
        default: status = nil
        }
        switch status {
        case 404?: return notFound
        case 410?: return .expired
        case 409?: return .alreadyUsed
        case 401?: return .needsSignIn(serverName: serverName)
        case 429?: return .failed("Too many attempts. Wait a moment, then try again.")
        case 503? where Self.isProviderUnavailable(error):
            return .failed(ExternalSignInError.reasonText("provider_unavailable"))
        default:
            if error is URLError { return .failed(unreachableMessage) }
            return .failed("\(serverName) couldn't finish this. Try again.")
        }
    }

    nonisolated static func isProviderUnavailable(_ error: Error) -> Bool {
        if case APIv2Error.problem(let problem) = error { return problem.identifier == "provider_unavailable" }
        return false
    }

    /// The TV family named by the request's platform.
    nonisolated static func platformLabel(_ platform: String?) -> String? {
        switch platform?.lowercased().replacingOccurrences(of: "-", with: "_") {
        case "tvos"?: return "Apple TV"
        case "androidtv"?, "android_tv"?, "googletv"?, "google_tv"?: return "Android TV"
        default: return nil
        }
    }
}
