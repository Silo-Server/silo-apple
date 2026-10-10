//
//  ProfileScopedSettingTransport.swift
//  Silo (iOS + tvOS + macOS)
//
//  The slice of the settings API that a store for a few profile-scoped keys
//  needs: probe the contract, read effective values for its own keys, and
//  write at `scope=profile`. Skip intervals and episode spoiler protection
//  share it.
//

import Foundation

/// The write scope is baked in at `profile`, the only scope the contract
/// allows for the keys that use this transport.
protocol ProfileScopedSettingTransport: AnyObject, Sendable {
    func contractCapabilities(
        requestIdentity: HTTPRequestIdentity
    ) async -> SettingsCapabilitiesResult
    func effectiveValues(
        keys: [SettingKey],
        requestIdentity: HTTPRequestIdentity
    ) async throws -> EffectiveSettingValuesResponse
    func putProfileValue(
        key: SettingKey,
        value: SettingJSONValue,
        requestIdentity: HTTPRequestIdentity
    ) async throws
}

final class SiloProfileScopedSettingTransport: ProfileScopedSettingTransport {
    private let api: SiloAPI

    init(api: SiloAPI = .shared) {
        self.api = api
    }

    func contractCapabilities(
        requestIdentity: HTTPRequestIdentity
    ) async -> SettingsCapabilitiesResult {
        await api.getContractCapabilities(requestIdentity: requestIdentity)
    }

    func effectiveValues(
        keys: [SettingKey],
        requestIdentity: HTTPRequestIdentity
    ) async throws -> EffectiveSettingValuesResponse {
        try await api.getEffectiveValues(
            keys: keys,
            requestIdentity: requestIdentity
        )
    }

    func putProfileValue(
        key: SettingKey,
        value: SettingJSONValue,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        try await api.putValue(
            key: key,
            scope: .profile,
            value: value,
            profileId: requestIdentity.profileId,
            requestIdentity: requestIdentity
        )
    }
}
