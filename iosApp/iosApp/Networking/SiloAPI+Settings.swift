import Foundation

// MARK: - Canonical settings API

/// The typed settings endpoints (`/api/v1/settings/contract*`,
/// `/api/v1/settings/values/*`).
///
/// The methods on ``SiloAPI`` itself — `effectiveSettings`,
/// `setDeviceSetting`, `getUserSetting` — speak the legacy string-only
/// registry: every value is a string, the scope is implied by which function
/// you call, and an unknown key is accepted silently. These speak the contract
/// instead: values are typed JSON, the scope is explicit and validated against
/// the manifest, and a key that is not in the manifest cannot be named because
/// ``SettingKey`` is generated from it.
///
/// Everything here codes through ``SettingsWireCoding`` rather than the shared
/// `HTTPClient` coders, so a setting value's own object keys never come near a
/// key strategy. See the header of SettingValueModels.swift for the reasoning;
/// the models decode identically under either coder either way.
extension SiloAPI {

    // MARK: Contract

    /// What the connected server's settings contract supports.
    ///
    /// Returns a typed result rather than throwing, because the interesting
    /// failure is not an error: a server may predate the canonical settings
    /// API entirely or serve an older manifest revision than this build. The
    /// UI must say "this server needs an upgrade" rather than render an empty
    /// or incomplete settings screen, so that case is
    /// ``SettingsCapabilitiesResult/serverUpgradeRequired`` instead of
    /// dissolving into the generic error path.
    ///
    /// Needs no profile: the contract is the same for every profile on the
    /// server, so this route sits outside the server's `RequireProfile` group
    /// and can be probed before profile selection.
    func getContractCapabilities(
        requestIdentity: HTTPRequestIdentity? = nil
    ) async -> SettingsCapabilitiesResult {
        do {
            let response = try await http.requestData(
                method: "GET",
                path: "/api/v1/settings/contract/capabilities",
                // A 404 here is the documented "server is too old" signal, not
                // a failure worth logging as one.
                quietStatuses: [404],
                requestIdentity: requestIdentity
            )
            let capabilities = try SettingsWireCoding.makeDecoder()
                .decode(SettingsContractCapabilities.self, from: response.data)
            guard !capabilities.contractIsAheadOfServer else {
                return .serverUpgradeRequired
            }
            return .available(capabilities)
        } catch {
            let mapped = SettingsAPIError.from(error)
            return mapped == .serverUpgradeRequired ? .serverUpgradeRequired : .failed(mapped)
        }
    }

    // MARK: Read

    /// Resolve settings the way the server does, including the scope each
    /// answer came from.
    ///
    /// Batched on purpose: a settings screen wants every key at once and a
    /// season view wants several keys across many series, and the server
    /// answers either in one store read. Passing no `keys` resolves every
    /// remote definition in the server's contract.
    ///
    /// `libraryIds` and `seriesIds` widen the resolution context to those
    /// content scopes — a key stored at `profile_library` only surfaces when
    /// its library is named here. The profile and device halves of the context
    /// come from the session headers.
    func getEffectiveValues(
        keys: [SettingKey] = [],
        libraryIds: [Int] = [],
        seriesIds: [String] = [],
        profileId: String? = nil,
        requestIdentity: HTTPRequestIdentity? = nil
    ) async throws -> EffectiveSettingValuesResponse {
        guard keys.count <= 200, libraryIds.count + seriesIds.count <= 200,
              libraryIds.allSatisfy({ $0 > 0 }) else { throw APIv2Error.invalidCatalogQuery }
        let activeProfile = await currentProfileId()
        let targetProfile = profileId ?? activeProfile
        let query = keys.map { URLQueryItem(name: "keys", value: $0.rawValue) }
            + libraryIds.map { URLQueryItem(name: "library_ids", value: String($0)) }
            + seriesIds.map { URLQueryItem(name: "series_ids", value: $0) }
        do {
            let data = try await v2.settingsRead("/api/v2/settings/values/effective", query: query,
                profileID: targetProfile, expectedIdentity: requestIdentity, profileRequired: true)
            let wire = try SettingsWireCoding.makeDecoder().decode(APIv2EffectiveSettings.self, from: data)
            guard !wire.page.hasMore, wire.page.nextCursor?.isEmpty != false else { throw APIv2Error.incompleteCatalogRead }
            let settings = wire.items.map(\.value)
            var identities = Set<String>()
            for item in settings {
                let identity = [item.key, item.libraryId.map(String.init) ?? "", item.seriesId ?? ""]
                guard identities.insert(identity.joined(separator: "\u{0}")).inserted,
                      item.profileId == nil || item.profileId == targetProfile,
                      keys.isEmpty || keys.contains(where: { $0.rawValue == item.key }),
                      item.libraryId == nil || libraryIds.contains(item.libraryId!),
                      item.seriesId == nil || seriesIds.contains(item.seriesId!) else { throw APIv2Error.incompleteCatalogRead }
            }
            let decoded = EffectiveSettingValuesResponse(settings: settings, revision: wire.revision)
            guard !decoded.contractIsAheadOfServer else {
                throw SettingsAPIError.transport(description: APIv2Error.serverUpdateRequiredMessage)
            }
            return decoded
        } catch {
            // A v2 failure must not activate the overlay store's legacy fallback.
            if let settingsError = error as? SettingsAPIError { throw settingsError }
            throw SettingsAPIError.transport(description: error.localizedDescription)
        }
    }

    // MARK: Write

    /// Write one typed value at one scope.
    ///
    /// `mutationId` (sent as `X-Silo-Mutation-Id`) makes retries safe: create
    /// it once per logical write with ``newSettingMutationId()`` and reuse it
    /// for every retry of *that* write. A retry the server already applied
    /// replays the recorded receipt rather than re-applying — the returned
    /// receipt has `isIdempotentReplay == true` — while reusing an id for
    /// different content fails with ``SettingsAPIError/mutationIdConflict``.
    /// Generating a fresh id per retry defeats both.
    ///
    /// A value that exceeds a policy restriction is stored, not rejected: the
    /// restriction filters what the preference does at resolution time, so a
    /// successful write does not mean playback will use this value. Call
    /// ``getEffectiveValues(keys:libraryIds:seriesIds:profileId:requestIdentity:)``
    /// for that.
    @discardableResult
    func putValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: SettingJSONValue,
        mutationId: String,
        profileId: String? = nil,
        requestIdentity: HTTPRequestIdentity? = nil
    ) async throws -> SettingValueWriteReceipt {
        let trimmedMutationId = mutationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMutationId.isEmpty else {
            throw SettingsAPIError.invalidValue(message: "Mutation ID must not be blank.")
        }
        var headers = try await profileHeaders(explicit: profileId)
        headers["X-Silo-Mutation-Id"] = trimmedMutationId

        do {
            let body = try SettingsWireCoding.makeEncoder().encode(SettingValueWriteRequest(value: value))
            let response = try await http.requestData(
                method: "PUT",
                path: "/api/v1/settings/values/\(key.rawValue)",
                query: scope.queryItems,
                body: body,
                headers: headers,
                requestIdentity: requestIdentity
            )
            let stored = try SettingsWireCoding.makeDecoder()
                .decode(StoredSettingValue.self, from: response.data)
            return SettingValueWriteReceipt(
                value: stored,
                isIdempotentReplay: response.header("X-Silo-Idempotent-Replay") == "true"
            )
        } catch {
            throw SettingsAPIError.from(error, key: key.rawValue, scope: scope.scope)
        }
    }

    /// Atomically add or remove one semantic shortcut from `nav.shortcuts`.
    ///
    /// Unlike a whole-value PUT, this operation is safe when multiple clients
    /// edit different shortcuts from stale effective snapshots. The mutation
    /// id still belongs to one exact `{item, present}` operation and must be
    /// reused when its response is ambiguous.
    @discardableResult
    func putNavigationShortcutItem(
        _ item: PrimaryMenuItem,
        present: Bool,
        mutationId: String,
        profileId: String? = nil,
        requestIdentity: HTTPRequestIdentity? = nil
    ) async throws -> SettingValueWriteReceipt {
        guard item.isContractValid else {
            throw SettingsAPIError.invalidValue(message: "Shortcut item is invalid.")
        }
        if case .builtin = item {
            throw SettingsAPIError.invalidValue(message: "Built-in destinations cannot be shortcuts.")
        }
        let trimmedMutationId = mutationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMutationId.isEmpty else {
            throw SettingsAPIError.invalidValue(message: "Mutation ID must not be blank.")
        }

        var headers = try await profileHeaders(explicit: profileId)
        headers["X-Silo-Mutation-Id"] = trimmedMutationId

        do {
            let body = try SettingsWireCoding.makeEncoder().encode(
                NavigationShortcutItemWriteRequest(item: item, present: present)
            )
            let response = try await http.requestData(
                method: "PUT",
                path: "/api/v1/settings/values/\(SettingKey.navShortcuts.rawValue)/item",
                body: body,
                headers: headers,
                requestIdentity: requestIdentity
            )
            let stored = try SettingsWireCoding.makeDecoder()
                .decode(StoredSettingValue.self, from: response.data)
            return SettingValueWriteReceipt(
                value: stored,
                isIdempotentReplay: response.header("X-Silo-Idempotent-Replay") == "true"
            )
        } catch {
            throw SettingsAPIError.from(
                error,
                key: SettingKey.navShortcuts.rawValue,
                scope: .profile
            )
        }
    }

    /// Clear the explicit value at one scope, so the setting inherits again.
    ///
    /// Throws ``SettingsAPIError/noValueAtScope`` when nothing was stored
    /// there (the server's 404). A caller retrying a clear should treat that
    /// as already done.
    func deleteValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        profileId: String? = nil,
        requestIdentity: HTTPRequestIdentity? = nil
    ) async throws {
        let headers = try await profileHeaders(explicit: profileId)
        do {
            _ = try await http.requestData(
                method: "DELETE",
                path: "/api/v1/settings/values/\(key.rawValue)",
                query: scope.queryItems,
                headers: headers,
                quietStatuses: [404],
                requestIdentity: requestIdentity
            )
        } catch {
            throw SettingsAPIError.from(error, key: key.rawValue, scope: scope.scope)
        }
    }

    // MARK: Headers

    /// The `X-Profile-Id` header every `/settings/values/*` route needs.
    ///
    /// `HTTPClient` already attaches the session's profile to every request,
    /// but only when one is selected. Each of these routes sits behind the
    /// server's `RequireProfile` middleware, and `profile_device`,
    /// `profile_library` and `profile_series` additionally take their profile
    /// half from this header rather than the query — so a call made before
    /// profile selection reaches the server without it and comes back as an
    /// opaque 400. Resolving it here fails locally with a named error instead.
    ///
    /// Setting the header explicitly also lets a caller act for a profile
    /// other than the session's, which is how a household parent edits a
    /// child's settings.
    private func profileHeaders(explicit profileId: String?) async throws -> [String: String] {
        var resolved = profileId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolved == nil || resolved?.isEmpty == true {
            resolved = await currentProfileId()
        }
        guard let profile = resolved, !profile.isEmpty else {
            throw SettingsAPIError.profileRequired
        }
        return ["X-Profile-Id": profile]
    }
}

private struct NavigationShortcutItemWriteRequest: Encodable {
    let item: PrimaryMenuItem
    let present: Bool
}

private struct APIv2EffectiveSettings: Decodable {
    let items: [APIv2EffectiveSetting]
    let page: Page
    let revision: Int
    struct Page: Decodable {
        let hasMore: Bool
        let nextCursor: String?
        enum CodingKeys: String, CodingKey {
            case hasMore = "has_more"
            case nextCursor = "next_cursor"
        }
    }
}

private struct APIv2EffectiveSetting: Decodable {
    let value: EffectiveSettingValue

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: EffectiveSettingValue.CodingKeys.self)
        let library = try c.decodeIfPresent(String.self, forKey: .libraryId)
        let libraryID = library.flatMap(Int.init)
        if let library {
            guard let libraryID, libraryID > 0, String(libraryID) == library else { throw APIv2Error.incompleteCatalogRead }
        }
        value = try EffectiveSettingValue(
            key: c.decode(String.self, forKey: .key), value: c.decode(SettingJSONValue.self, forKey: .value),
            source: c.decode(SettingSource.self, forKey: .source),
            storedValue: c.contains(.storedValue) ? c.decode(SettingJSONValue.self, forKey: .storedValue) : nil,
            constrained: c.decodeIfPresent(Bool.self, forKey: .constrained) ?? false,
            constraintKind: c.decodeIfPresent(SettingConstraintKind.self, forKey: .constraintKind),
            suggestedValues: c.decodeIfPresent([String].self, forKey: .suggestedValues),
            scope: c.decodeIfPresent(SettingScope.self, forKey: .scope),
            profileId: c.decodeIfPresent(String.self, forKey: .profileId),
            clientFamily: c.decodeIfPresent(String.self, forKey: .clientFamily),
            deviceId: c.decodeIfPresent(String.self, forKey: .deviceId), libraryId: libraryID,
            seriesId: c.decodeIfPresent(String.self, forKey: .seriesId))
    }
}
