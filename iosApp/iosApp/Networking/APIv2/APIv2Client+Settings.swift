import Foundation

/// The v2 settings reads and value writes. Reads go through `settingsRead` and
/// writes through `settingsWrite`; both gate on the probe verdict, capture the
/// owner, refuse a request whose captured identity no longer matches
/// `expectedIdentity`, and discard the response when the owner changed while
/// it was in flight.
///
/// The three writes are `natural_idempotent` in the contract: each names the
/// desired state of one row, so sending the same request again converges on
/// the same row. They carry no mutation id (the server rejects a
/// `mutation_id` body member and replays nothing), and every retry advances
/// the row's revision. Which failures may be retried is the caller's
/// decision; see `SettingWriteFailure`.
extension APIv2Client {
    /// `getSettingsContractCapabilities` (profile optional). The contract is
    /// the same for every profile, so this can be probed before profile
    /// selection.
    func settingsContractCapabilities(
        expectedIdentity: HTTPRequestIdentity? = nil
    ) async throws -> APIv2SettingsContractCapabilities {
        let data = try await settingsRead(
            "/api/v2/settings/contract/capabilities",
            expectedIdentity: expectedIdentity
        )
        return try HTTPClient.makeJSONDecoder().decode(APIv2SettingsContractCapabilities.self, from: data)
    }

    /// `listEffectiveSettings` (profile required) for `profileID`, which must
    /// be the profile the captured session has selected: the household-parent
    /// `profile_id` override is not used, so every row answers for the caller.
    ///
    /// Keys, libraries and series each travel as one repeated query item per
    /// value, and library ids are sent as strings.
    func effectiveSettings(
        keys: [SettingKey],
        libraryIds: [Int],
        seriesIds: [String],
        profileID: String,
        expectedIdentity: HTTPRequestIdentity? = nil
    ) async throws -> EffectiveSettingValuesResponse {
        let query = keys.map { URLQueryItem(name: "keys", value: $0.rawValue) }
            + libraryIds.map { URLQueryItem(name: "library_ids", value: String($0)) }
            + seriesIds.map { URLQueryItem(name: "series_ids", value: $0) }
        let data = try await settingsRead(
            "/api/v2/settings/values/effective",
            query: query,
            profileID: profileID,
            expectedIdentity: expectedIdentity,
            profileRequired: true
        )
        // Values keep their own object keys verbatim, so this decodes through
        // the settings coder rather than the shared snake_case one.
        let response = try SettingsWireCoding.makeDecoder()
            .decode(EffectiveSettingValuesResponse.self, from: data)
        guard response.settings.allSatisfy({ $0.profileId == nil || $0.profileId == profileID }) else {
            throw SettingsAPIError.transport(description: "The server resolved settings for another profile.")
        }
        guard Set(response.settings.map(\.key)).count == response.settings.count else {
            throw SettingsAPIError.transport(description: "The server resolved the same setting twice.")
        }
        return response
    }

    /// `updateSettingValue` (200 with the stored row) for `profileID`, which
    /// must be the captured session's profile. The receipt must describe the
    /// row that was addressed; anything else is `unexpectedSettingReceipt`.
    @discardableResult
    func updateSettingValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: SettingJSONValue,
        profileID: String,
        expectedIdentity: HTTPRequestIdentity? = nil
    ) async throws -> StoredSettingValue {
        let body = try SettingsWireCoding.makeEncoder().encode(SettingValueWriteRequest(value: value))
        let response = try await settingsWrite(
            "PUT",
            path: try Self.settingValuePath(key),
            query: scope.queryItems,
            body: body,
            profileID: profileID,
            expectedIdentity: expectedIdentity
        )
        return try Self.settingReceipt(response, key: key, scope: scope, profileID: profileID)
    }

    /// `updateNavigationShortcut` (200 with the stored `nav.shortcuts` row):
    /// add (`present`) or remove one shortcut of the acting profile. Only that
    /// entry changes, so concurrent edits of other shortcuts are kept.
    @discardableResult
    func updateNavigationShortcut(
        _ item: PrimaryMenuItem,
        present: Bool,
        profileID: String,
        expectedIdentity: HTTPRequestIdentity? = nil
    ) async throws -> StoredSettingValue {
        let body = try SettingsWireCoding.makeEncoder().encode(
            NavigationShortcutMutation(item: item, present: present)
        )
        let response = try await settingsWrite(
            "PUT",
            path: "\(try Self.settingValuePath(.navShortcuts))/item",
            query: [:],
            body: body,
            profileID: profileID,
            expectedIdentity: expectedIdentity
        )
        return try Self.settingReceipt(response, key: .navShortcuts, scope: .profile, profileID: profileID)
    }

    /// `deleteSettingValue` (204). A 404 means nothing is stored at that scope,
    /// which is the state the delete asked for, so it is reported as
    /// `SettingsAPIError.noValueAtScope` rather than as a failure.
    func deleteSettingValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        profileID: String,
        expectedIdentity: HTTPRequestIdentity? = nil
    ) async throws {
        let response: HTTPRawResponse
        do {
            response = try await settingsWrite(
                "DELETE",
                path: try Self.settingValuePath(key),
                query: scope.queryItems,
                body: nil,
                profileID: profileID,
                expectedIdentity: expectedIdentity,
                quietStatuses: [404]
            )
        } catch APIv2Error.problem(let problem) where problem.status == 404 {
            throw SettingsAPIError.noValueAtScope
        }
        guard response.statusCode == 204 else { throw APIv2Error.httpStatus(response.statusCode) }
    }

    private static func settingValuePath(_ key: SettingKey) throws -> String {
        guard let segment = CatalogPathSegment.encode(key.rawValue) else {
            throw SettingsAPIError.unknownSetting(key: key.rawValue)
        }
        return "/api/v2/settings/values/\(segment)"
    }

    /// Checks a write's 200 receipt against what was sent: the key, the scope
    /// and every identity member of that scope. The device and client family
    /// travel in the headers HTTPClient attaches for this device.
    private static func settingReceipt(
        _ response: HTTPRawResponse,
        key: SettingKey,
        scope: SettingScopeIdentity,
        profileID: String
    ) throws -> StoredSettingValue {
        guard response.statusCode == 200 else { throw APIv2Error.httpStatus(response.statusCode) }
        // The value keeps its own object keys, so the receipt decodes through
        // the settings coder rather than the shared snake_case one.
        let receipt = try SettingsWireCoding.makeDecoder().decode(StoredSettingValue.self, from: response.data)
        let device = AppleDeviceIdentity.current
        var libraryID: String?
        var seriesID: String?
        switch scope {
        case .profileLibrary(let id): libraryID = String(id)
        case .profileSeries(let id): seriesID = id
        case .account, .profile, .profileClient, .profileDevice: break
        }
        guard receipt.key == key.rawValue,
              receipt.scope == scope.scope,
              receipt.revision > 0,
              receipt.profileId == (scope == .account ? nil : profileID),
              receipt.deviceId == (scope == .profileDevice ? device.id : nil),
              receipt.clientFamily == (scope == .profileClient ? device.clientFamily : nil),
              receipt.libraryId == libraryID,
              receipt.seriesId == seriesID else {
            throw APIv2Error.unexpectedSettingReceipt
        }
        return receipt
    }
}

/// `NavigationShortcutMutation`: both members are required.
private struct NavigationShortcutMutation: Encodable {
    let item: PrimaryMenuItem
    let present: Bool
}
