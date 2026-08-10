//
//  ProfileSettingsWriter.swift
//  Silo (iOS + tvOS + macOS)
//
//  Writes the profile-scoped preferences — subtitle language / mode / forced,
//  metadata language — through the canonical settings API at `scope=profile`.
//
//  These used to travel as fields on `PUT /profiles/{id}`. The server still
//  accepts that and mirrors the fields into the canonical rows
//  (internal/api/handlers/profiles_settings_sync.go), so the legacy path is not
//  broken — but it is a narrower pipe than the contract: it can only address
//  the profile's own scope, spells "no preference" as the empty string where
//  the contract spells it null, and validates nothing a client sends until the
//  mirror runs. Writing the canonical keys directly is what lets a value
//  authored here read back identically on web and Android, and what will keep
//  working when the legacy fields are eventually retired.
//
//  Reads go through the same batched effective endpoint every other surface
//  uses, so a value overridden at a library, series or device scope is reported
//  as such rather than being silently masked by the profile row this writes.
//

import Foundation
import OSLog

/// The slice of the canonical settings API the profile preferences need.
///
/// A protocol rather than a direct ``ContinuumAPI`` reference so the mapping
/// between editor state and wire values can be exercised without a network.
/// The scope is baked in at `profile`: these are the household member's own
/// choices, and the contract resolves device, library and series overrides
/// above them.
protocol ProfileSettingsTransport: AnyObject, Sendable {
    func effectiveValues(keys: [SettingKey]) async throws -> EffectiveSettingValuesResponse
    func putValue(
        key: SettingKey,
        value: SettingJSONValue,
        mutationId: String,
        profileId: String?
    ) async throws
}

/// The production transport: the canonical endpoints on ``ContinuumAPI``.
final class ContinuumProfileSettingsTransport: ProfileSettingsTransport {
    private let api: ContinuumAPI

    init(api: ContinuumAPI = .shared) {
        self.api = api
    }

    func effectiveValues(keys: [SettingKey]) async throws -> EffectiveSettingValuesResponse {
        try await api.getEffectiveValues(keys: keys)
    }

    func putValue(
        key: SettingKey,
        value: SettingJSONValue,
        mutationId: String,
        profileId: String?
    ) async throws {
        _ = try await api.putValue(
            key: key,
            scope: .profile,
            value: value,
            mutationId: mutationId,
            profileId: profileId
        )
    }
}

/// The profile-scoped preferences both settings screens edit.
///
/// Deliberately *not* including `playback.audio_language`, even though the
/// settings screens offer a spoken-language picker. That control writes at
/// `profile_device` through ``PlayerSettings``, and the contract resolves
/// `profile_device` above `profile` — so a profile-scope write from here would
/// be shadowed by this device's own row and appear not to save. Old Apple
/// builds already wrote those device rows, so the shadowing is real on existing
/// installs rather than hypothetical.
enum ProfileSettingKeys {
    static let subtitleLanguage: SettingKey = .playbackSubtitleLanguage
    static let subtitleMode: SettingKey = .playbackSubtitleMode
    static let showForcedSubtitles: SettingKey = .playbackShowForcedSubtitles
    static let metadataLanguage: SettingKey = .catalogMetadataLanguage

    /// The keys a settings screen reads in one batch, in a stable order.
    static let all: [SettingKey] = [
        subtitleLanguage,
        subtitleMode,
        showForcedSubtitles,
        metadataLanguage,
    ]
}

/// The profile preferences as the settings screens hold them.
///
/// Optionals mean what the contract means by null: "no preference". The
/// editors' `__none__` sentinel is translated at the boundary rather than
/// carried in here, so nothing downstream has to know about it.
struct ProfilePreferences: Equatable, Sendable {
    var subtitleLanguage: String?
    var subtitleMode: String
    var showForcedSubtitles: Bool
    var metadataLanguage: String?

    /// The contract's declared defaults, used before the first read lands and
    /// when the server sends no row for a key at all.
    static let contractDefaults = ProfilePreferences(
        subtitleLanguage: nil,
        subtitleMode: SubtitleMode.auto.rawValue,
        showForcedSubtitles: true,
        metadataLanguage: nil
    )
}

/// Reads and writes the profile-scoped preferences.
///
/// Writes are immediate rather than debounced, unlike the player's device
/// settings: every control here is a discrete choice (a picker commit, a
/// toggle) rather than a slider or a stepper, so there is no stream of
/// intermediate values worth coalescing, and the screens show a per-write
/// "Saving… / Saved" state that a debounce would make dishonest.
final class ProfileSettingsWriter: @unchecked Sendable {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "ProfileSettingsWriter"
    )

    private let transport: ProfileSettingsTransport

    /// The mutation id in flight per key and profile, so a retry of the *same*
    /// logical write replays the server's receipt instead of applying twice.
    private struct MutationIdentity: Hashable {
        let key: SettingKey
        let profileId: String?
    }

    private let lock = NSLock()
    private var inFlight: [MutationIdentity: (
        value: SettingJSONValue,
        mutationId: String
    )] = [:]

    init(transport: ProfileSettingsTransport) {
        self.transport = transport
    }

    convenience init() {
        self.init(transport: ContinuumProfileSettingsTransport())
    }

    // MARK: - Read

    /// Resolve the profile preferences, and report where each came from.
    ///
    /// Returns the resolved values plus the raw rows, because "which scope
    /// answered" is worth surfacing: a subtitle language resolved from
    /// `profile_series` is not something editing this screen can change.
    func load() async throws -> (preferences: ProfilePreferences, byKey: [SettingKey: EffectiveSettingValue]) {
        let response = try await transport.effectiveValues(keys: ProfileSettingKeys.all)
        let byKey = response.byKey
        var preferences = ProfilePreferences.contractDefaults

        // Each falls back to the contract default only when the server sent no
        // row at all — a server whose contract predates the key. A row with
        // source "default" still carries the typed value, so an explicitly
        // stored false is never confused with an absent one.
        preferences.subtitleLanguage = byKey[ProfileSettingKeys.subtitleLanguage]?
            .value.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        preferences.subtitleMode = byKey[ProfileSettingKeys.subtitleMode]?.value.stringValue
            ?? ProfilePreferences.contractDefaults.subtitleMode
        preferences.showForcedSubtitles = byKey[ProfileSettingKeys.showForcedSubtitles]?.value.boolValue
            ?? ProfilePreferences.contractDefaults.showForcedSubtitles
        preferences.metadataLanguage = byKey[ProfileSettingKeys.metadataLanguage]?
            .value.stringValue.flatMap { $0.isEmpty ? nil : $0 }

        return (preferences, byKey)
    }

    // MARK: - Write

    /// Write one profile-scoped value, holding its mutation id across retries.
    ///
    /// Throws ``SettingsAPIError`` so a caller can distinguish "this server is
    /// too old" and "no profile selected" from a value the contract refused.
    func write(
        _ key: SettingKey,
        value: SettingJSONValue,
        profileId: String? = nil
    ) async throws {
        let mutationId = mutationId(for: key, value: value, profileId: profileId)
        do {
            try await transport.putValue(
                key: key,
                value: value,
                mutationId: mutationId,
                profileId: profileId
            )
            clearInFlight(key, profileId: profileId, matching: mutationId)
        } catch {
            let mapped = SettingsAPIError.from(error, key: key.rawValue, scope: .profile)
            switch mapped {
            case .unknownSetting, .clientLocalSetting, .scopeNotAllowed, .invalidValue, .mutationIdConflict:
                // The contract refused it, so the id is spent: a retry of this
                // exact content would fail identically, and reusing the id for
                // corrected content is the 409 case. Drop it so the next
                // attempt is a genuinely new write.
                clearInFlight(key, profileId: profileId, matching: mutationId)
                Self.logger.warning(
                    "\(key.rawValue, privacy: .public): contract refused the profile write: \(String(describing: mapped), privacy: .public)"
                )
            case .serverUpgradeRequired, .profileRequired, .noValueAtScope, .server, .transport:
                // Retryable in principle: keep the id so a repeat of the same
                // logical write replays rather than double-applies.
                break
            }
            throw mapped
        }
    }

    /// A "no preference" language: the contract's null, never the empty string
    /// its `language_tag` validator rejects.
    static func languageValue(_ code: String?) -> SettingJSONValue {
        guard let code, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .null
        }
        return .string(code)
    }

    // MARK: - Mutation ids

    /// The id for this write: reused when the same content is being retried,
    /// fresh when the content changed.
    private func mutationId(
        for key: SettingKey,
        value: SettingJSONValue,
        profileId: String?
    ) -> String {
        lock.lock()
        defer { lock.unlock() }
        let identity = MutationIdentity(key: key, profileId: profileId)
        if let existing = inFlight[identity], existing.value == value {
            return existing.mutationId
        }
        let minted = newSettingMutationId()
        inFlight[identity] = (value, minted)
        return minted
    }

    /// Retire an id once its write settled, but only if a newer write has not
    /// already claimed the key for this profile.
    private func clearInFlight(
        _ key: SettingKey,
        profileId: String?,
        matching mutationId: String
    ) {
        lock.lock()
        let identity = MutationIdentity(key: key, profileId: profileId)
        if inFlight[identity]?.mutationId == mutationId {
            inFlight.removeValue(forKey: identity)
        }
        lock.unlock()
    }
}
