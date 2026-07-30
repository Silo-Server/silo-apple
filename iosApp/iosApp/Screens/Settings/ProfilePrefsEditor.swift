//
//  ProfilePrefsEditor.swift
//  Silo (iOS + tvOS + macOS)
//
//  Editor state and save behaviour for the profile-scoped preferences, shared
//  by the iOS and tvOS settings screens.
//
//  The two screens had a verbatim copy of this each — same fields, same
//  sentinel translation, same coalescing for the metadata language — which is
//  how they came to disagree in small ways over time. One implementation means
//  a scope or wire-value fix lands on both platforms at once, which matters
//  more now that the values are contract-validated: a spelling only one screen
//  got right would be a permanent `invalid_value` on the other.
//

import Foundation

/// Profile-scoped preferences as the settings screens edit them.
///
/// Fields are the picker-facing spellings (the `__none__` sentinel, "on"/"off")
/// because that is what SwiftUI's `Picker` and `Toggle` bind to. Translation to
/// the contract's wire values happens on the way out, in one place.
@Observable
final class ProfilePrefsEditor {

    /// How the last write went. The screens show a transient message.
    enum PrefSaveState: Equatable {
        case saving
        case saved
        case failed(String)
        /// The server predates the canonical settings API. Distinct from a
        /// failure because retrying cannot help and the user needs to be told
        /// something actionable rather than shown an error they can't act on.
        case serverUpgradeRequired
    }

    // MARK: - Editor fields

    /// `PlaybackPrefSentinel.none` or a concrete language code.
    var subtitleLanguage: String = PlaybackPrefSentinel.none
    var subtitleMode: String = SubtitleMode.auto.rawValue
    /// Bound as "on" / "off" so it can share the picker plumbing on tvOS.
    var showForcedSubtitles: String = "on"
    /// `PlaybackPrefSentinel.none` means "inherit the library default".
    /// Gated on `AICapabilities.shared.metadataEnabled` at the row.
    var preferredMetadataLanguage: String = PlaybackPrefSentinel.none

    /// Deployment-observed advisory values from the effective settings API.
    /// Picker helpers add the generated floor and exact current value.
    private(set) var subtitleLanguageSuggestions: [String] = []
    private(set) var metadataLanguageSuggestions: [String] = []

    var saveState: PrefSaveState?

    /// True when the connected server has no canonical settings API. The
    /// screens render an explanation in place of controls that cannot work.
    var serverUpgradeRequired = false

    /// The scope each preference actually resolved from, so a screen can say
    /// "a series override is winning over this" rather than showing a control
    /// whose value the user cannot explain.
    private(set) var resolvedSources: [SettingKey: SettingSource] = [:]

    /// User-facing explanation when a narrower subtitle scope wins over the
    /// profile row edited by this screen.
    var subtitleProfileOverrideMessage: String? {
        let scopes = Set(Self.subtitleKeys.compactMap { key -> SettingScope? in
            guard case .scope(let scope) = resolvedSources[key],
                  Self.profileWriteMayBeShadowed(by: .scope(scope)) else {
                return nil
            }
            return scope
        })
        guard let scope = scopes.first else { return nil }
        guard scopes.count == 1 else {
            return "More specific device, library, or series subtitle settings override this profile default. Changes here are saved for the profile, but those overrides still apply where configured."
        }
        switch scope {
        case .profileDevice:
            return "This device, for this profile, has a more specific subtitle setting. Changes here update the profile default, but the device override still applies."
        case .profileLibrary:
            return "A library-specific subtitle setting overrides this profile default. Changes here are saved for the profile, but the library override still applies."
        case .profileSeries:
            return "A series-specific subtitle setting overrides this profile default. Changes here are saved for the profile, but the series override still applies."
        case .other:
            return "A more specific subtitle setting overrides this profile default. Changes here are saved for the profile, but the override still applies."
        case .account, .profile:
            return nil
        }
    }

    /// What was last *painted* into the fields — by ``seed(from:)``, by
    /// ``load()``, or by a write this editor made. A save only sends keys that
    /// differ from it.
    ///
    /// Without this baseline the editor writes back what it just read, one
    /// scope up. `load()` reads through the effective endpoint, which resolves
    /// `profile_series → profile_library → profile_device → profile → default`,
    /// while every write here goes to `profile` — so a value that came from a
    /// narrower scope would be promoted into the profile row. The device half
    /// of that is reachable today: all three subtitle keys list `profile_device`
    /// in `allowed_scopes`, and the web admin's per-device settings pane writes
    /// them there. The user then opens Settings on that device, touches
    /// nothing, `load()` repaints, `onChange` fires because the value moved,
    /// and the household profile silently adopts one device's override.
    ///
    /// A diff is the fix rather than refusing to save a shadowed key: a value
    /// the user actually typed must still be written, and only a change the
    /// user made can differ from what was last painted.
    private var savedBaseline = Baseline()

    private struct Baseline: Equatable {
        var subtitleLanguage: String?
        var subtitleMode: String?
        var showForcedSubtitles: String?
        var metadataLanguage: String?
    }

    private struct SubtitleWrite {
        let key: SettingKey
        let value: SettingJSONValue
        /// Picker-facing value captured before the network suspension. A
        /// successful older PUT must advance the baseline only to this value,
        /// never to a newer edit currently visible in the field.
        let editorValue: String
        let language: String?
        /// Profile that owned the editor when this logical write was queued.
        let profileId: String?
    }

    private struct SubtitleWriteIdentity: Hashable {
        let key: SettingKey
        let profileId: String?
    }

    private struct MetadataWrite {
        let language: String?
        let profileId: String?
    }

    /// What the screens show in place of server-backed controls when the
    /// server predates the canonical settings API. Playback is unaffected —
    /// it falls back to this device's local defaults — so the message says
    /// that rather than implying nothing works.
    static let serverUpgradeMessage = """
        This server is too old to store playback preferences. \
        Playback still works using this device's defaults. \
        Ask your server administrator to update Silo.
        """

    private let writer: ProfileSettingsWriter

    /// The profile whose values this editor currently represents. Every write
    /// captures this before its first suspension so a later session switch
    /// cannot redirect the request through a newly active X-Profile-Id.
    private var boundProfileId: String?

    /// SwiftUI can launch another onChange task while a PUT is suspended. The
    /// later task marks another pass owed and returns, preserving call order
    /// for every profile key.
    private var isSavingSubtitlePrefs = false
    private var subtitleSaveRequested = false
    /// Latest per-profile, per-key edits made while another subtitle PUT is
    /// suspended. Different profiles own independent rows, so a queued edit for
    /// one must not displace an ambiguous failure still owed by another.
    /// Kept independently of `savedBaseline`: a request can reach the server
    /// even when its response is lost, so reverting to the baseline still owes
    /// an explicit compensating write.
    private var pendingSubtitleEditorValues: [SubtitleWriteIdentity: String] = [:]
    private var activeSubtitleEditorValues: [SubtitleWriteIdentity: String] = [:]

    /// Coalescing for the metadata language: it has a side effect the others
    /// don't (flushing cached translations), so overlapping writes are folded
    /// into one rather than each invalidating the cache.
    private var isSavingMetadataLanguage = false
    private var pendingMetadataWrite: MetadataWrite?

    private static let subtitleKeys: [SettingKey] = [
        ProfileSettingKeys.subtitleLanguage,
        ProfileSettingKeys.subtitleMode,
        ProfileSettingKeys.showForcedSubtitles,
    ]

    init(writer: ProfileSettingsWriter = ProfileSettingsWriter()) {
        self.writer = writer
    }

    /// Bind subsequent edits to the profile painted into this editor.
    @MainActor
    func bindProfile(id: String?) {
        let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        boundProfileId = trimmed.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Load

    /// Read the profile preferences from the batched effective endpoint.
    @MainActor
    func load() async {
        do {
            let (preferences, byKey) = try await writer.load()
            serverUpgradeRequired = false
            apply(preferences)
            resolvedSources = byKey.compactMapValues { $0.source }
            adoptLanguageSuggestions(from: byKey)
        } catch SettingsAPIError.serverUpgradeRequired {
            serverUpgradeRequired = true
        } catch {
            // Offline or transient: leave whatever is on screen rather than
            // snapping every control back to a default the profile never chose.
        }
    }

    @MainActor
    private func apply(_ preferences: ProfilePreferences) {
        subtitleLanguage = preferences.subtitleLanguage ?? PlaybackPrefSentinel.none
        subtitleMode = preferences.subtitleMode
        showForcedSubtitles = preferences.showForcedSubtitles ? "on" : "off"
        preferredMetadataLanguage = preferences.metadataLanguage ?? PlaybackPrefSentinel.none
        captureBaseline()
    }

    /// Record the fields as they now stand, so the next save can tell a user
    /// edit from a repaint.
    @MainActor
    private func captureBaseline() {
        savedBaseline = Baseline(
            subtitleLanguage: subtitleLanguage,
            subtitleMode: subtitleMode,
            showForcedSubtitles: showForcedSubtitles,
            metadataLanguage: preferredMetadataLanguage
        )
    }

    @MainActor
    private func adoptLanguageSuggestions(from byKey: [SettingKey: EffectiveSettingValue]) {
        subtitleLanguageSuggestions = byKey[ProfileSettingKeys.subtitleLanguage]?.suggestedValues ?? []
        metadataLanguageSuggestions = byKey[ProfileSettingKeys.metadataLanguage]?.suggestedValues ?? []
    }

    /// Move one key's baseline to the exact captured value that landed.
    @MainActor
    private func adoptBaseline(for key: SettingKey, value: String) {
        if key == ProfileSettingKeys.subtitleLanguage {
            savedBaseline.subtitleLanguage = value
        } else if key == ProfileSettingKeys.subtitleMode {
            savedBaseline.subtitleMode = value
        } else if key == ProfileSettingKeys.showForcedSubtitles {
            savedBaseline.showForcedSubtitles = value
        } else if key == ProfileSettingKeys.metadataLanguage {
            savedBaseline.metadataLanguage = value
        }
    }

    /// Seed the editor from an already-fetched profile.
    ///
    /// Used for first paint while the effective read is still in flight, so the
    /// screen opens on the profile's own values rather than on contract
    /// defaults that visibly correct themselves a moment later. The effective
    /// read overwrites this, and is the authority — it is the only source that
    /// accounts for library, series and device overrides.
    @MainActor
    func seed(from profile: UserProfile?) {
        let language = profile?.subtitleLanguage ?? ""
        subtitleLanguage = language.isEmpty ? PlaybackPrefSentinel.none : language

        let mode = profile?.subtitleMode ?? ""
        subtitleMode = mode.isEmpty ? SubtitleMode.auto.rawValue : mode

        showForcedSubtitles = (profile?.showForcedSubtitles ?? true) ? "on" : "off"

        let metadata = profile?.preferredMetadataLanguage ?? ""
        preferredMetadataLanguage = metadata.isEmpty ? PlaybackPrefSentinel.none : metadata

        captureBaseline()
    }

    // MARK: - Save

    /// Persist the subtitle trio at `profile` scope.
    ///
    /// Only the keys the *user* changed are sent — a field still equal to what
    /// was last painted into it is not a choice, it is the value that was read
    /// back, and writing it would move it up a scope. See ``savedBaseline``.
    ///
    /// Change tracking is per key rather than per call because the screens
    /// trigger this from an `onChange` on each control: a repaint moves several
    /// fields at once, and one genuinely edited control must not drag the other
    /// two along with it.
    @MainActor
    func saveSubtitlePrefs() async {
        guard !serverUpgradeRequired else {
            saveState = .serverUpgradeRequired
            return
        }
        subtitleSaveRequested = true
        guard !isSavingSubtitlePrefs else {
            capturePendingSubtitleEdits()
            return
        }

        isSavingSubtitlePrefs = true
        defer { isSavingSubtitlePrefs = false }

        var failures: [SubtitleWriteIdentity: Error] = [:]
        var needsEffectiveRefresh = false

        while true {
            while subtitleSaveRequested {
                subtitleSaveRequested = false
                let writes = takePendingSubtitleWrites()
                guard !writes.isEmpty else { continue }
                saveState = .saving

                // Every key is attempted even when an earlier one fails. They
                // are independent rows; failure state is tracked per profile
                // and key so one profile cannot clear another profile's failed
                // attempt.
                for write in writes {
                    let identity = SubtitleWriteIdentity(
                        key: write.key,
                        profileId: write.profileId
                    )
                    do {
                        try await writer.write(
                            write.key,
                            value: write.value,
                            profileId: write.profileId
                        )
                        failures.removeValue(forKey: identity)
                        let stillEditingWrittenProfile = boundProfileId == write.profileId
                        if stillEditingWrittenProfile {
                            adoptBaseline(for: write.key, value: write.editorValue)
                        }

                        if stillEditingWrittenProfile,
                           write.key == ProfileSettingKeys.subtitleLanguage {
                            // This row landed even if a sibling later fails.
                            ProfilePrefsStore.shared.setPreferredSubtitleLanguage(write.language)
                        }

                        if stillEditingWrittenProfile,
                           Self.profileWriteMayBeShadowed(by: resolvedSources[write.key]) {
                            needsEffectiveRefresh = true
                        } else if stillEditingWrittenProfile {
                            resolvedSources[write.key] = .scope(.profile)
                        }
                    } catch {
                        if Self.isServerUpgradeRequired(error) {
                            serverUpgradeRequired = true
                            // Route absence is definitive, not an ambiguous
                            // response that might have applied. Stop this
                            // already-owned drain and discard edits queued
                            // while its request was suspended.
                            subtitleSaveRequested = false
                            pendingSubtitleEditorValues.removeAll()
                            activeSubtitleEditorValues.removeAll()
                            saveState = .serverUpgradeRequired
                            return
                        }
                        failures[identity] = error
                        let stillEditingWrittenProfile = boundProfileId == write.profileId
                        if pendingSubtitleEditorValues[identity] == nil,
                           (!stillEditingWrittenProfile
                            || currentEditorValue(for: write.key) == write.editorValue) {
                            // The server may have applied this request even
                            // though its response was lost. Preserve it as an
                            // explicit owed value so a baseline-equal revert is
                            // still retried on the next trigger.
                            pendingSubtitleEditorValues[identity] = write.editorValue
                        }
                    }
                }

                // A control may have changed while this batch was suspended
                // even before its onChange task got to run. Preserve that
                // newest local operation with another serialized pass.
                if writes.contains(where: {
                    $0.profileId == boundProfileId
                        && currentEditorValue(for: $0.key) != $0.editorValue
                }) {
                    capturePendingSubtitleEdits()
                    subtitleSaveRequested = true
                }
                activeSubtitleEditorValues.removeAll()
            }

            if failures.isEmpty, needsEffectiveRefresh {
                needsEffectiveRefresh = false
                await refreshSubtitleResolutionAfterWrite()
                // An onChange that arrived while the effective read was
                // suspended marked another pass owed and returned because
                // this saver still owns serialization. Drain it before
                // releasing that ownership.
                if subtitleSaveRequested { continue }
            }
            break
        }

        let firstFailure = Self.subtitleKeys.lazy.compactMap { key in
            failures.first(where: { $0.key.key == key })?.value
        }.first
        if let firstFailure {
            saveState = Self.saveState(for: firstFailure)
        } else {
            saveState = .saved
        }
    }

    @MainActor
    private func takePendingSubtitleWrites() -> [SubtitleWrite] {
        var queued = pendingSubtitleEditorValues
        pendingSubtitleEditorValues.removeAll()

        // A previous profile may have an owed retry in `queued` while the
        // currently bound profile has a fresh edit. Keep both identities.
        for key in Self.subtitleKeys {
            let identity = SubtitleWriteIdentity(key: key, profileId: boundProfileId)
            if queued[identity] == nil,
               let current = currentEditorValue(for: key),
               current != savedBaselineValue(for: key) {
                queued[identity] = current
            }
        }

        let keyOrder = Dictionary(
            uniqueKeysWithValues: Self.subtitleKeys.enumerated().map { ($1, $0) }
        )
        let ordered = queued.sorted { lhs, rhs in
            let lhsOrder = keyOrder[lhs.key.key] ?? Int.max
            let rhsOrder = keyOrder[rhs.key.key] ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return (lhs.key.profileId ?? "") < (rhs.key.profileId ?? "")
        }
        let writes = ordered.compactMap { identity, editorValue -> SubtitleWrite? in
            if identity.key == ProfileSettingKeys.subtitleLanguage {
                let language = Self.outboundLanguage(editorValue)
                return SubtitleWrite(
                    key: identity.key,
                    value: ProfileSettingsWriter.languageValue(language),
                    editorValue: editorValue,
                    language: language,
                    profileId: identity.profileId
                )
            }
            if identity.key == ProfileSettingKeys.subtitleMode {
                return SubtitleWrite(
                    key: identity.key,
                    value: .string(editorValue),
                    editorValue: editorValue,
                    language: nil,
                    profileId: identity.profileId
                )
            }
            if identity.key == ProfileSettingKeys.showForcedSubtitles {
                return SubtitleWrite(
                    key: identity.key,
                    value: .bool(editorValue == "on"),
                    editorValue: editorValue,
                    language: nil,
                    profileId: identity.profileId
                )
            }
            return nil
        }
        activeSubtitleEditorValues = Dictionary(
            uniqueKeysWithValues: writes.map {
                (
                    SubtitleWriteIdentity(key: $0.key, profileId: $0.profileId),
                    $0.editorValue
                )
            }
        )
        return writes
    }

    @MainActor
    private func capturePendingSubtitleEdits() {
        for key in Self.subtitleKeys {
            guard let current = currentEditorValue(for: key) else { continue }
            let identity = SubtitleWriteIdentity(key: key, profileId: boundProfileId)
            if let queued = pendingSubtitleEditorValues[identity] {
                if queued != current {
                    pendingSubtitleEditorValues[identity] = current
                }
            } else if let active = activeSubtitleEditorValues[identity] {
                if active != current {
                    pendingSubtitleEditorValues[identity] = current
                }
            } else if current != savedBaselineValue(for: key) {
                pendingSubtitleEditorValues[identity] = current
            }
        }
    }

    @MainActor
    private func savedBaselineValue(for key: SettingKey) -> String? {
        if key == ProfileSettingKeys.subtitleLanguage { return savedBaseline.subtitleLanguage }
        if key == ProfileSettingKeys.subtitleMode { return savedBaseline.subtitleMode }
        if key == ProfileSettingKeys.showForcedSubtitles { return savedBaseline.showForcedSubtitles }
        return nil
    }

    @MainActor
    private func currentEditorValue(for key: SettingKey) -> String? {
        if key == ProfileSettingKeys.subtitleLanguage { return subtitleLanguage }
        if key == ProfileSettingKeys.subtitleMode { return subtitleMode }
        if key == ProfileSettingKeys.showForcedSubtitles { return showForcedSubtitles }
        if key == ProfileSettingKeys.metadataLanguage { return preferredMetadataLanguage }
        return nil
    }

    private static func profileWriteMayBeShadowed(by source: SettingSource?) -> Bool {
        guard case .scope(let scope) = source else { return false }
        switch scope {
        case .profileDevice, .profileLibrary, .profileSeries, .other:
            return true
        case .account, .profile:
            return false
        }
    }

    /// Re-resolve after writing a profile row that was known to be shadowed by
    /// a narrower scope. Apply only if no newer edit appeared during the read.
    @MainActor
    private func refreshSubtitleResolutionAfterWrite() async {
        let expected = [
            ProfileSettingKeys.subtitleLanguage: subtitleLanguage,
            ProfileSettingKeys.subtitleMode: subtitleMode,
            ProfileSettingKeys.showForcedSubtitles: showForcedSubtitles,
        ]
        do {
            let (preferences, byKey) = try await writer.load()
            let current = [
                ProfileSettingKeys.subtitleLanguage: subtitleLanguage,
                ProfileSettingKeys.subtitleMode: subtitleMode,
                ProfileSettingKeys.showForcedSubtitles: showForcedSubtitles,
            ]
            guard current == expected else { return }

            subtitleLanguage = preferences.subtitleLanguage ?? PlaybackPrefSentinel.none
            subtitleMode = preferences.subtitleMode
            showForcedSubtitles = preferences.showForcedSubtitles ? "on" : "off"
            savedBaseline.subtitleLanguage = subtitleLanguage
            savedBaseline.subtitleMode = subtitleMode
            savedBaseline.showForcedSubtitles = showForcedSubtitles
            for key in Self.subtitleKeys {
                resolvedSources[key] = byKey[key]?.source
            }
            adoptLanguageSuggestions(from: byKey)
        } catch {
            // The profile write itself succeeded. Keep the captured values and
            // retry effective resolution on the next ordinary load.
        }
    }

    /// Persist the metadata language at `profile` scope.
    ///
    /// Separate from the subtitle trio because it has a side effect they don't:
    /// when it actually changes, the cached overviews and taglines have to be
    /// dropped so the next fetch picks up the server-side translation — which
    /// is the reason this one is gated on the baseline too even though
    /// `catalog.metadata_language` allows only `profile` scope and so cannot be
    /// shadowed the way the subtitle trio can. A repaint that re-sent it would
    /// invalidate every cached overview for nothing.
    @MainActor
    func saveMetadataLanguage() async {
        guard !serverUpgradeRequired else {
            saveState = .serverUpgradeRequired
            return
        }
        let language = Self.outboundLanguage(preferredMetadataLanguage)
        let write = MetadataWrite(language: language, profileId: boundProfileId)
        // The displayed value may have returned to the saved baseline while
        // an older, different PUT is still suspended. Queue that revert before
        // consulting the baseline or the older value would win on the server.
        if isSavingMetadataLanguage {
            pendingMetadataWrite = write
            return
        }
        guard preferredMetadataLanguage != savedBaseline.metadataLanguage else { return }
        pendingMetadataWrite = write

        isSavingMetadataLanguage = true
        defer { isSavingMetadataLanguage = false }

        while let next = pendingMetadataWrite {
            pendingMetadataWrite = nil
            await writeMetadataLanguage(next)
        }
    }

    @MainActor
    private func writeMetadataLanguage(_ write: MetadataWrite) async {
        saveState = .saving
        do {
            try await writer.write(
                ProfileSettingKeys.metadataLanguage,
                value: ProfileSettingsWriter.languageValue(write.language),
                profileId: write.profileId
            )
            ResponseCache.shared.invalidateAllItemMetadata()
            #if os(tvOS)
            ItemDetailCache.shared.clearAll()
            #endif
            // A newer edit landed while this was in flight; let its own pass
            // report, or this one would announce a value already superseded.
            guard Self.outboundLanguage(preferredMetadataLanguage) == write.language,
                  boundProfileId == write.profileId else {
                if pendingMetadataWrite == nil { saveState = nil }
                return
            }
            adoptBaseline(
                for: ProfileSettingKeys.metadataLanguage,
                value: preferredMetadataLanguage
            )
            saveState = .saved
        } catch {
            if Self.isServerUpgradeRequired(error) {
                serverUpgradeRequired = true
                pendingMetadataWrite = nil
                saveState = .serverUpgradeRequired
                return
            }
            guard Self.outboundLanguage(preferredMetadataLanguage) == write.language,
                  boundProfileId == write.profileId else {
                if pendingMetadataWrite == nil { saveState = nil }
                return
            }
            saveState = Self.saveState(for: error)
        }
    }

    // MARK: - Helpers

    /// The `__none__` sentinel is the picker's spelling of "no preference";
    /// the contract's is null, which ``ProfileSettingsWriter/languageValue(_:)``
    /// produces from nil.
    private static func outboundLanguage(_ value: String) -> String? {
        value == PlaybackPrefSentinel.none ? nil : value
    }

    private static func isServerUpgradeRequired(_ error: Error) -> Bool {
        guard let settingsError = error as? SettingsAPIError else { return false }
        if case .serverUpgradeRequired = settingsError { return true }
        return false
    }

    private static func saveState(for error: Error) -> PrefSaveState {
        guard let settingsError = error as? SettingsAPIError else {
            return .failed((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
        switch settingsError {
        case .serverUpgradeRequired:
            return .serverUpgradeRequired
        case .profileRequired:
            return .failed("Choose a profile first.")
        case .invalidValue(let message):
            return .failed(message.isEmpty ? "That value isn't allowed." : message)
        case .unknownSetting, .clientLocalSetting, .scopeNotAllowed:
            return .failed("This server can't store that preference.")
        case .mutationIdConflict, .noValueAtScope, .server, .transport:
            return .failed("Couldn't reach the server.")
        }
    }
}
