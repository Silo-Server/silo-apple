import Foundation

/// The v2 settings reads. Both go through `settingsRead`, which gates on the
/// probe verdict, captures the owner, refuses a request whose captured
/// identity no longer matches `expectedIdentity`, and discards the response
/// when the owner changed while it was in flight.
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
            throw HTTPError.authorityChanged
        }
        guard Set(response.settings.map(\.key)).count == response.settings.count else {
            throw SettingsAPIError.transport(description: "The server resolved the same setting twice.")
        }
        return response
    }
}
