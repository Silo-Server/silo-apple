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
        /// A change ran out of automatic retries and is held on this device
        /// until the user retries or discards it (``hasHeldChanges``).
        case held
    }

    // MARK: - Editor fields

    // Read-only outside the editor: a screen changes them through the `set…`
    // methods, which are the only way a write starts. Reads repaint them
    // without sending anything.

    /// `PlaybackPrefSentinel.none` or a concrete language code.
    private(set) var subtitleLanguage: String = PlaybackPrefSentinel.none
    private(set) var subtitleMode: String = SubtitleMode.auto.rawValue
    /// Stored as "on" / "off" so it can share the picker plumbing on tvOS.
    private(set) var showForcedSubtitles: String = "on"
    /// `PlaybackPrefSentinel.none` means "inherit the library default".
    /// Gated on `AICapabilities.shared.metadataEnabled` at the row.
    private(set) var preferredMetadataLanguage: String = PlaybackPrefSentinel.none

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
        case .profileClient:
            return "This device family has a more specific subtitle setting. Changes here update the profile default, but the family override still applies."
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

    /// The value the server last confirmed for each field: read by
    /// ``seed(from:)`` or ``load()``, or landed by a write this editor made.
    /// It is used only to put a control back when the server refuses its
    /// value or the user discards a held change. It does not decide what is
    /// sent: only the `set…` methods send, and each sends the one key it
    /// changed.
    ///
    /// Reads must never send. `load()` reads through the effective endpoint,
    /// which resolves `profile_series → profile_library → profile_device →
    /// profile → default`, while every write here goes to `profile`, so
    /// sending a value that was read would promote a narrower scope's value
    /// (for example a per-device override set from the web admin) into the
    /// household profile row.
    private var serverValues = ServerValues()

    private struct ServerValues: Equatable {
        var subtitleLanguage: String?
        var subtitleMode: String?
        var showForcedSubtitles: String?
        var metadataLanguage: String?
    }

    private struct SubtitleWrite {
        let key: SettingKey
        let value: SettingJSONValue
        /// Picker-facing value captured before the network suspension. A
        /// successful older PUT records only this value as the server's,
        /// never a newer edit currently visible in the field.
        let editorValue: String
        let language: String?
        /// Profile that owned the editor when this logical write was queued.
        let profileId: String?
    }

    private struct SubtitleWriteIdentity: Hashable {
        let key: SettingKey
        let profileId: String?
    }

    private struct MetadataWrite: Equatable {
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

    /// The user can make another edit while a PUT is suspended. That edit
    /// queues its value, marks another pass owed and returns; the running
    /// drain sends it, preserving call order for every profile key.
    private var isSavingSubtitlePrefs = false
    private var subtitleSaveRequested = false
    /// Per-profile, per-key values waiting to be sent: the newest edit of
    /// each control, and values owed after an ambiguous failure (a request can
    /// reach the server even when its response is lost). Different profiles
    /// own independent rows, so a queued edit for one must not displace an
    /// ambiguous failure still owed by another.
    private var pendingSubtitleEditorValues: [SubtitleWriteIdentity: String] = [:]
    /// Writes taken from the queue whose request has not settled yet.
    private var inFlightSubtitleWrites: Set<SubtitleWriteIdentity> = []

    /// Subtitle values that ran out of automatic retries (owner decision D4).
    /// A held value is not sent again until the user retries it, edits that
    /// control, or discards it.
    private var heldSubtitleEditorValues: [SubtitleWriteIdentity: String] = [:]
    /// The metadata language write that ran out of automatic retries.
    private var heldMetadataWrite: MetadataWrite?

    /// True while any change is held for the profile this editor shows.
    var hasHeldChanges: Bool {
        heldSubtitleEditorValues.keys.contains { $0.profileId == boundProfileId }
            || (heldMetadataWrite.map { $0.profileId == boundProfileId } ?? false)
    }

    /// Coalescing for the metadata language: it has a side effect the others
    /// don't (flushing cached translations), so overlapping writes are folded
    /// into one rather than each invalidating the cache.
    private var isSavingMetadataLanguage = false
    private var pendingMetadataWrite: MetadataWrite?
    private var inFlightMetadataWrite: MetadataWrite?

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
            showHeldValues()
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
        paintServerValues(ServerValues(
            subtitleLanguage: preferences.subtitleLanguage ?? PlaybackPrefSentinel.none,
            subtitleMode: preferences.subtitleMode,
            showForcedSubtitles: preferences.showForcedSubtitles ? "on" : "off",
            metadataLanguage: preferences.metadataLanguage ?? PlaybackPrefSentinel.none
        ))
    }

    /// Record what the server holds, and show it in every control whose
    /// user edit has settled. A control with an edit still queued or in
    /// flight keeps showing the edit: the read may predate it, and replacing
    /// it would make a retry of that write look superseded.
    @MainActor
    private func paintServerValues(_ values: ServerValues) {
        serverValues = values
        for key in Self.subtitleKeys + [ProfileSettingKeys.metadataLanguage] {
            guard !hasUnsettledEdit(for: key), let value = serverValue(for: key) else { continue }
            setEditorValue(value, for: key)
        }
    }

    /// Whether the control for `key` shows a user edit, or an owed value, that
    /// the current profile's writes have not finished sending.
    @MainActor
    private func hasUnsettledEdit(for key: SettingKey) -> Bool {
        if key == ProfileSettingKeys.metadataLanguage {
            return (pendingMetadataWrite.map { $0.profileId == boundProfileId } ?? false)
                || (inFlightMetadataWrite.map { $0.profileId == boundProfileId } ?? false)
        }
        let identity = SubtitleWriteIdentity(key: key, profileId: boundProfileId)
        return pendingSubtitleEditorValues[identity] != nil || inFlightSubtitleWrites.contains(identity)
    }

    /// Keep showing the user's held choices over the server's answer, which
    /// does not have them. The server values stay as read, so a discard can
    /// put the controls back; the held record keeps the choices from being
    /// sent again on their own.
    ///
    /// A control with a newer edit still unsettled keeps showing that edit.
    /// The writer records a hold only after the final attempt fails, which
    /// can be after the user has already queued a newer value; the next pass
    /// drops the stale hold, and until then a read must not paint it.
    @MainActor
    private func showHeldValues() {
        for (identity, value) in heldSubtitleEditorValues
        where identity.profileId == boundProfileId && !hasUnsettledEdit(for: identity.key) {
            setEditorValue(value, for: identity.key)
        }
        if let held = heldMetadataWrite,
           held.profileId == boundProfileId,
           !hasUnsettledEdit(for: ProfileSettingKeys.metadataLanguage) {
            preferredMetadataLanguage = held.language ?? PlaybackPrefSentinel.none
        }
    }

    @MainActor
    private func setEditorValue(_ value: String, for key: SettingKey) {
        if key == ProfileSettingKeys.subtitleLanguage {
            subtitleLanguage = value
        } else if key == ProfileSettingKeys.subtitleMode {
            subtitleMode = value
        } else if key == ProfileSettingKeys.showForcedSubtitles {
            showForcedSubtitles = value
        } else if key == ProfileSettingKeys.metadataLanguage {
            preferredMetadataLanguage = value
        }
    }

    // MARK: - Held changes

    /// "Try Again": send every held change once more with a fresh retry
    /// budget.
    @MainActor
    func retryHeldChanges() async {
        for (identity, value) in heldSubtitleEditorValues where pendingSubtitleEditorValues[identity] == nil {
            pendingSubtitleEditorValues[identity] = value
        }
        heldSubtitleEditorValues.removeAll()
        let heldMetadata = heldMetadataWrite
        heldMetadataWrite = nil
        saveState = nil
        await drainSubtitleWrites()
        if let heldMetadata {
            await saveMetadataLanguage(retrying: heldMetadata)
        }
    }

    /// "Discard Held Change": stop trying to send the held changes and repaint
    /// what the server holds. Nothing is sent.
    ///
    /// Each control still showing a discarded value is put back to the server
    /// value first. A change is usually held because the server is
    /// unreachable, and then `load()` fails and leaves the fields alone, so
    /// the discarded value would otherwise stay on screen. A control the user
    /// has since moved shows a newer edit, which is not discarded.
    @MainActor
    func discardHeldChanges() async {
        for (identity, held) in heldSubtitleEditorValues
        where identity.profileId == boundProfileId && currentEditorValue(for: identity.key) == held {
            if pendingSubtitleEditorValues[identity] == held {
                pendingSubtitleEditorValues.removeValue(forKey: identity)
            }
            if let confirmed = serverValue(for: identity.key) {
                setEditorValue(confirmed, for: identity.key)
            }
        }
        if let held = heldMetadataWrite,
           held.profileId == boundProfileId,
           Self.outboundLanguage(preferredMetadataLanguage) == held.language {
            if pendingMetadataWrite == held { pendingMetadataWrite = nil }
            preferredMetadataLanguage = serverValues.metadataLanguage ?? PlaybackPrefSentinel.none
        }
        heldSubtitleEditorValues.removeAll()
        heldMetadataWrite = nil
        saveState = nil
        await load()
    }

    @MainActor
    private func adoptLanguageSuggestions(from byKey: [SettingKey: EffectiveSettingValue]) {
        subtitleLanguageSuggestions = byKey[ProfileSettingKeys.subtitleLanguage]?.suggestedValues ?? []
        metadataLanguageSuggestions = byKey[ProfileSettingKeys.metadataLanguage]?.suggestedValues ?? []
    }

    /// Record the exact captured value that landed as the server's for one key.
    @MainActor
    private func recordServerValue(for key: SettingKey, value: String) {
        if key == ProfileSettingKeys.subtitleLanguage {
            serverValues.subtitleLanguage = value
        } else if key == ProfileSettingKeys.subtitleMode {
            serverValues.subtitleMode = value
        } else if key == ProfileSettingKeys.showForcedSubtitles {
            serverValues.showForcedSubtitles = value
        } else if key == ProfileSettingKeys.metadataLanguage {
            serverValues.metadataLanguage = value
        }
    }

    /// Seed the editor from an already-fetched profile.
    ///
    /// Used for first paint while the effective read is still in flight, so the
    /// screen opens on the profile's own values rather than on contract
    /// defaults that visibly correct themselves a moment later. The effective
    /// read overwrites this, and is the authority — it is the only source that
    /// accounts for library, series and device overrides. Like a read, this
    /// only paints; it never sends.
    @MainActor
    func seed(from profile: UserProfile?) {
        let language = profile?.subtitleLanguage ?? ""
        let mode = profile?.subtitleMode ?? ""
        let metadata = profile?.preferredMetadataLanguage ?? ""
        paintServerValues(ServerValues(
            subtitleLanguage: language.isEmpty ? PlaybackPrefSentinel.none : language,
            subtitleMode: mode.isEmpty ? SubtitleMode.auto.rawValue : mode,
            showForcedSubtitles: (profile?.showForcedSubtitles ?? true) ? "on" : "off",
            metadataLanguage: metadata.isEmpty ? PlaybackPrefSentinel.none : metadata
        ))
    }

    // MARK: - Edits

    // The only entry points that send. Each shows the new value at once,
    // before its first suspension, and sends exactly the key it changed at
    // `profile` scope. Choosing the value a control already shows sends
    // nothing.

    @MainActor
    func setSubtitleLanguage(_ value: String) async {
        await editSubtitle(ProfileSettingKeys.subtitleLanguage, to: value)
    }

    @MainActor
    func setSubtitleMode(_ value: String) async {
        await editSubtitle(ProfileSettingKeys.subtitleMode, to: value)
    }

    @MainActor
    func setShowForcedSubtitles(_ enabled: Bool) async {
        await editSubtitle(ProfileSettingKeys.showForcedSubtitles, to: enabled ? "on" : "off")
    }

    /// Separate from the subtitle trio because it has a side effect they don't:
    /// when it actually changes, the cached overviews and taglines have to be
    /// dropped so the next fetch picks up the server-side translation.
    @MainActor
    func setPreferredMetadataLanguage(_ value: String) async {
        guard value != preferredMetadataLanguage else { return }
        preferredMetadataLanguage = value
        guard !serverUpgradeRequired else {
            saveState = .serverUpgradeRequired
            return
        }
        let write = MetadataWrite(language: Self.outboundLanguage(value), profileId: boundProfileId)
        // A new edit replaces a held one. It is sent even when it matches the
        // server value, because the held one may have reached the server.
        if let held = heldMetadataWrite, held.profileId == boundProfileId {
            heldMetadataWrite = nil
        }
        if isSavingMetadataLanguage {
            pendingMetadataWrite = write
            return
        }
        await drainMetadataWrites(startingWith: write)
    }

    @MainActor
    private func editSubtitle(_ key: SettingKey, to value: String) async {
        guard currentEditorValue(for: key) != value else { return }
        setEditorValue(value, for: key)
        guard !serverUpgradeRequired else {
            saveState = .serverUpgradeRequired
            return
        }
        let identity = SubtitleWriteIdentity(key: key, profileId: boundProfileId)
        // A new edit replaces a held one. It is sent even when it matches the
        // server value, because the held one may have reached the server.
        heldSubtitleEditorValues.removeValue(forKey: identity)
        pendingSubtitleEditorValues[identity] = value
        await drainSubtitleWrites()
    }

    // MARK: - Save

    /// Send the queued subtitle values at `profile` scope, one serialized
    /// drain at a time.
    ///
    /// The queue holds only what the `set…` methods, "Try Again" and owed
    /// ambiguous failures put there, so every write is a key the user chose
    /// to change. Keys are tracked per profile and per key: one edited
    /// control must not drag its siblings along with it.
    @MainActor
    private func drainSubtitleWrites() async {
        guard !serverUpgradeRequired else {
            saveState = .serverUpgradeRequired
            return
        }
        // Set before the ownership check: a caller that queued values while
        // another drain runs relies on that drain taking one more pass.
        subtitleSaveRequested = true
        guard !isSavingSubtitlePrefs else { return }

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
                    defer { inFlightSubtitleWrites.remove(identity) }
                    do {
                        try await writer.write(
                            write.key,
                            value: write.value,
                            profileId: write.profileId,
                            isLatest: { [weak self] in
                                self?.isLatestSubtitleWrite(write, identity: identity) ?? false
                            }
                        )
                        failures.removeValue(forKey: identity)
                        let stillEditingWrittenProfile = boundProfileId == write.profileId
                        if stillEditingWrittenProfile {
                            recordServerValue(for: write.key, value: write.editorValue)
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
                    } catch is ProfileSettingsWriter.Superseded {
                        // A newer edit of this control replaced the value
                        // while it waited for a retry; that edit is queued
                        // and its own write reports.
                        failures.removeValue(forKey: identity)
                    } catch is ProfileSettingsWriter.HeldChange {
                        failures.removeValue(forKey: identity)
                        heldSubtitleEditorValues[identity] = write.editorValue
                    } catch {
                        if Self.isServerUpgradeRequired(error) {
                            serverUpgradeRequired = true
                            // Route absence is definitive, not an ambiguous
                            // response that might have applied. Stop this
                            // already-owned drain and discard edits queued
                            // while its request was suspended.
                            subtitleSaveRequested = false
                            pendingSubtitleEditorValues.removeAll()
                            inFlightSubtitleWrites.removeAll()
                            saveState = .serverUpgradeRequired
                            return
                        }
                        failures[identity] = error
                        let stillEditingWrittenProfile = boundProfileId == write.profileId
                        if SettingsAPIError.from(error).writeFailure == .release {
                            // The server answered and refused this value;
                            // sending it again gets the same answer. Release
                            // it: nothing is owed, and a control still showing
                            // it goes back to the server value.
                            if stillEditingWrittenProfile,
                               currentEditorValue(for: write.key) == write.editorValue,
                               let confirmed = serverValue(for: write.key) {
                                setEditorValue(confirmed, for: write.key)
                            }
                        } else if pendingSubtitleEditorValues[identity] == nil,
                           (!stillEditingWrittenProfile
                            || currentEditorValue(for: write.key) == write.editorValue) {
                            // The server may have applied this request even
                            // though its response was lost. Keep it as an
                            // explicit owed value, sent with the next edit or
                            // "Try Again", even when it matches the server
                            // value.
                            pendingSubtitleEditorValues[identity] = write.editorValue
                        }
                    }
                }
            }

            if failures.isEmpty, needsEffectiveRefresh {
                needsEffectiveRefresh = false
                await refreshSubtitleResolutionAfterWrite()
                // An edit made while the effective read was suspended queued
                // its value and returned because this drain still owns
                // serialization. Send it before releasing that ownership.
                if subtitleSaveRequested { continue }
            }
            break
        }

        let firstFailure = Self.subtitleKeys.lazy.compactMap { key in
            failures.first(where: { $0.key.key == key })?.value
        }.first
        if hasHeldChanges {
            saveState = .held
        } else if let firstFailure {
            saveState = Self.saveState(for: firstFailure)
        } else {
            saveState = .saved
        }
    }

    /// Whether `write` is still the value to retry: no newer value is queued
    /// for its key and profile, and the control still shows it when its
    /// profile is the one on screen.
    @MainActor
    private func isLatestSubtitleWrite(_ write: SubtitleWrite, identity: SubtitleWriteIdentity) -> Bool {
        guard pendingSubtitleEditorValues[identity] == nil else { return false }
        return boundProfileId != write.profileId || currentEditorValue(for: write.key) == write.editorValue
    }

    @MainActor
    private func takePendingSubtitleWrites() -> [SubtitleWrite] {
        var queued = pendingSubtitleEditorValues
        pendingSubtitleEditorValues.removeAll()

        // A held value is only sent again on request. Any other queued value
        // replaces the hold; that includes an edit queued while the final
        // attempt was still in flight, because the writer records that hold
        // only after the edit was queued.
        for (identity, value) in queued {
            if heldSubtitleEditorValues[identity] == value {
                queued.removeValue(forKey: identity)
            } else {
                heldSubtitleEditorValues.removeValue(forKey: identity)
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
        inFlightSubtitleWrites.formUnion(writes.map {
            SubtitleWriteIdentity(key: $0.key, profileId: $0.profileId)
        })
        return writes
    }

    @MainActor
    private func serverValue(for key: SettingKey) -> String? {
        if key == ProfileSettingKeys.subtitleLanguage { return serverValues.subtitleLanguage }
        if key == ProfileSettingKeys.subtitleMode { return serverValues.subtitleMode }
        if key == ProfileSettingKeys.showForcedSubtitles { return serverValues.showForcedSubtitles }
        if key == ProfileSettingKeys.metadataLanguage { return serverValues.metadataLanguage }
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
        case .profileClient, .profileDevice, .profileLibrary, .profileSeries, .other:
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
            serverValues.subtitleLanguage = subtitleLanguage
            serverValues.subtitleMode = subtitleMode
            serverValues.showForcedSubtitles = showForcedSubtitles
            for key in Self.subtitleKeys {
                resolvedSources[key] = byKey[key]?.source
            }
            adoptLanguageSuggestions(from: byKey)
        } catch {
            // The profile write itself succeeded. Keep the captured values and
            // retry effective resolution on the next ordinary load.
        }
    }

    /// Send a held metadata language again (``retryHeldChanges()``).
    @MainActor
    private func saveMetadataLanguage(retrying write: MetadataWrite) async {
        if isSavingMetadataLanguage {
            pendingMetadataWrite = write
            return
        }
        await drainMetadataWrites(startingWith: write)
    }

    @MainActor
    private func drainMetadataWrites(startingWith write: MetadataWrite) async {
        pendingMetadataWrite = write

        isSavingMetadataLanguage = true
        defer { isSavingMetadataLanguage = false }

        while let next = pendingMetadataWrite {
            pendingMetadataWrite = nil
            inFlightMetadataWrite = next
            await writeMetadataLanguage(next)
            inFlightMetadataWrite = nil
        }
    }

    @MainActor
    private func writeMetadataLanguage(_ write: MetadataWrite) async {
        saveState = .saving
        do {
            try await writer.write(
                ProfileSettingKeys.metadataLanguage,
                value: ProfileSettingsWriter.languageValue(write.language),
                profileId: write.profileId,
                isLatest: { [weak self] in
                    guard let self else { return false }
                    return self.pendingMetadataWrite == nil
                        && self.boundProfileId == write.profileId
                        && Self.outboundLanguage(self.preferredMetadataLanguage) == write.language
                }
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
            recordServerValue(
                for: ProfileSettingKeys.metadataLanguage,
                value: preferredMetadataLanguage
            )
            saveState = .saved
        } catch is ProfileSettingsWriter.Superseded {
            // The newer value queued in `pendingMetadataWrite` reports.
            if pendingMetadataWrite == nil { saveState = nil }
        } catch is ProfileSettingsWriter.HeldChange {
            heldMetadataWrite = write
            if boundProfileId == write.profileId {
                saveState = .held
            } else if pendingMetadataWrite == nil {
                saveState = nil
            }
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
        case .unknownSetting, .scopeNotAllowed:
            return .failed("This server can't store that preference.")
        case .ownerChanged:
            return .failed("The profile changed before this could be saved.")
        case .server(let status, _, _) where settingsError.writeFailure == .release:
            return .failed("The server didn't accept this change (HTTP \(status)).")
        case .noValueAtScope, .server, .transport:
            return .failed("Couldn't reach the server.")
        }
    }
}
