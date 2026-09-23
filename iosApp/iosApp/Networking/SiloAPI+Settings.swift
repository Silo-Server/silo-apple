import Foundation

// MARK: - Canonical settings API

/// The typed settings endpoints: the v2 contract capabilities and effective
/// reads, and the `/settings/values/*` writes. All of them go through the
/// shared ``APIv2Client`` (`APIv2Client+Settings.swift`).
///
/// Values are typed JSON, the scope is explicit and validated against the
/// manifest, and a key that is not in the manifest cannot be named because
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
    /// failure is not an error: a server may be v1-only or serve a manifest
    /// revision below ``SettingKey/minimumServerRevision``. The UI must say
    /// "this server needs an upgrade" rather than render an empty or
    /// incomplete settings screen, so that case is
    /// ``SettingsCapabilitiesResult/serverUpgradeRequired`` instead of
    /// dissolving into the generic error path. A server at or above the
    /// minimum but behind this build is still `available`; features built on
    /// newer keys check ``APIv2SettingsContractCapabilities/supports(_:)``.
    ///
    /// Needs no profile: the contract is the same for every profile on the
    /// server, so it can be probed before profile selection.
    func getContractCapabilities(
        requestIdentity: HTTPRequestIdentity? = nil
    ) async -> SettingsCapabilitiesResult {
        do {
            let capabilities = try await apiV2Client.settingsContractCapabilities(
                expectedIdentity: requestIdentity
            )
            if capabilities.isAvailable {
                return capabilities.predatesMinimumRevision ? .serverUpgradeRequired : .available(capabilities)
            }
            // `unsupported` means this server build cannot provide the
            // settings contract; any other state is an answer about this
            // principal or configuration, not about the server's version.
            return capabilities.state == "unsupported" ? .serverUpgradeRequired : .unavailable
        } catch {
            let mapped = SettingsAPIError.from(error)
            return mapped == .serverUpgradeRequired ? .serverUpgradeRequired : .failed(mapped)
        }
    }

    // MARK: Read

    /// The server-wide card overlay config: the admin kill switch and the
    /// optional baseline document for profiles that have not customized.
    /// Needs no profile; the server caches it for 60s.
    func overlayConfig() async throws -> APIv2OverlayConfig {
        try await apiV2Client.overlayConfig()
    }

    /// Resolve settings the way the server does, including the scope each
    /// answer came from, for the session's selected profile.
    ///
    /// Batched on purpose: a settings screen wants every key at once and a
    /// season view wants several keys across many series, and the server
    /// answers either in one store read. Passing no `keys` resolves every
    /// remote definition in the server's contract.
    ///
    /// `libraryIds` and `seriesIds` widen the resolution context to those
    /// content scopes — a key stored at `profile_library` only surfaces when
    /// its library is named here. The profile and device halves of the context
    /// come from the session headers. `requestIdentity`, when given, pins the
    /// read to that server and profile: it fails rather than follow a switch.
    func getEffectiveValues(
        keys: [SettingKey] = [],
        libraryIds: [Int] = [],
        seriesIds: [String] = [],
        requestIdentity: HTTPRequestIdentity? = nil
    ) async throws -> EffectiveSettingValuesResponse {
        // Resolved here so a call made before profile selection fails locally
        // with a named error instead of the server's 400.
        var profile = requestIdentity?.profileId
        if profile?.isEmpty ?? true {
            profile = await currentProfileId()
        }
        guard let profile, !profile.isEmpty else {
            throw SettingsAPIError.profileRequired
        }

        do {
            let decoded = try await apiV2Client.effectiveSettings(
                keys: keys,
                libraryIds: libraryIds,
                seriesIds: seriesIds,
                profileID: profile,
                expectedIdentity: requestIdentity
            )
            // Per key rather than against this build's newest revision: an
            // older server still resolves the keys it defines, while a key it
            // never heard of would come back as a missing row.
            guard !decoded.predatesMinimumRevision, decoded.servesAll(keys) else {
                throw SettingsAPIError.serverUpgradeRequired
            }
            return decoded
        } catch {
            throw SettingsAPIError.from(error)
        }
    }

    // MARK: Write

    /// Write one typed value at one scope and return the stored row.
    ///
    /// The write names the desired state of the row, so repeating it is safe
    /// (the contract marks it `natural_idempotent`) but not free: every
    /// accepted attempt advances the row's revision. There is no mutation id
    /// and no replayed receipt. `profileId`, when given, must be the session's
    /// selected profile: a write captured for one profile is refused rather
    /// than sent for another.
    ///
    /// A value that exceeds a policy restriction is stored, not rejected: the
    /// restriction filters what the preference does at resolution time, so a
    /// successful write does not mean playback will use this value. Call
    /// ``getEffectiveValues(keys:libraryIds:seriesIds:requestIdentity:)``
    /// for that.
    @discardableResult
    func putValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: SettingJSONValue,
        profileId: String? = nil,
        requestIdentity: HTTPRequestIdentity? = nil
    ) async throws -> StoredSettingValue {
        do {
            return try await apiV2Client.updateSettingValue(
                key: key,
                scope: scope,
                value: value,
                profileID: try await writeProfile(explicit: profileId ?? requestIdentity?.profileId),
                expectedIdentity: requestIdentity
            )
        } catch {
            throw SettingsAPIError.from(error, key: key.rawValue, scope: scope.scope)
        }
    }

    /// Atomically add or remove one semantic shortcut from `nav.shortcuts`.
    ///
    /// Unlike a whole-value PUT, this operation is safe when multiple clients
    /// edit different shortcuts from stale effective snapshots.
    @discardableResult
    func putNavigationShortcutItem(
        _ item: PrimaryMenuItem,
        present: Bool,
        profileId: String? = nil,
        requestIdentity: HTTPRequestIdentity? = nil
    ) async throws -> StoredSettingValue {
        guard item.isContractValid else {
            throw SettingsAPIError.invalidValue(message: "Shortcut item is invalid.")
        }
        if case .builtin = item {
            throw SettingsAPIError.invalidValue(message: "Built-in destinations cannot be shortcuts.")
        }
        do {
            return try await apiV2Client.updateNavigationShortcut(
                item,
                present: present,
                profileID: try await writeProfile(explicit: profileId ?? requestIdentity?.profileId),
                expectedIdentity: requestIdentity
            )
        } catch {
            throw SettingsAPIError.from(error, key: SettingKey.navShortcuts.rawValue, scope: .profile)
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
        do {
            try await apiV2Client.deleteSettingValue(
                key: key,
                scope: scope,
                profileID: try await writeProfile(explicit: profileId ?? requestIdentity?.profileId),
                expectedIdentity: requestIdentity
            )
        } catch {
            throw SettingsAPIError.from(error, key: key.rawValue, scope: scope.scope)
        }
    }

    // MARK: Profile

    /// The profile a write acts for: the caller's captured profile, or the
    /// session's when the caller did not capture one.
    ///
    /// Every `/settings/values/*` route requires `X-Profile-Id`, so a call
    /// made before profile selection fails locally with a named error instead
    /// of the server's 422. The v2 client then refuses the write when the
    /// session's profile is no longer this one.
    private func writeProfile(explicit profileId: String?) async throws -> String {
        var resolved = profileId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolved == nil || resolved?.isEmpty == true {
            resolved = await currentProfileId()
        }
        guard let profile = resolved, !profile.isEmpty else {
            throw SettingsAPIError.profileRequired
        }
        return profile
    }
}
