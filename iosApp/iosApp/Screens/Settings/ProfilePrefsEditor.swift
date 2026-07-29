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

    var saveState: PrefSaveState?

    /// True when the connected server has no canonical settings API. The
    /// screens render an explanation in place of controls that cannot work.
    var serverUpgradeRequired = false

    /// The scope each preference actually resolved from, so a screen can say
    /// "a series override is winning over this" rather than showing a control
    /// whose value the user cannot explain.
    private(set) var resolvedSources: [SettingKey: SettingSource] = [:]

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

    /// Coalescing for the metadata language: it has a side effect the others
    /// don't (flushing cached translations), so overlapping writes are folded
    /// into one rather than each invalidating the cache.
    private var isSavingMetadataLanguage = false
    private var pendingMetadataLanguage: String??

    init(writer: ProfileSettingsWriter = ProfileSettingsWriter()) {
        self.writer = writer
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

    /// Move one key's baseline up to the field's current value, after a write
    /// for that key succeeded.
    @MainActor
    private func adoptBaseline(for key: SettingKey) {
        if key == ProfileSettingKeys.subtitleLanguage {
            savedBaseline.subtitleLanguage = subtitleLanguage
        } else if key == ProfileSettingKeys.subtitleMode {
            savedBaseline.subtitleMode = subtitleMode
        } else if key == ProfileSettingKeys.showForcedSubtitles {
            savedBaseline.showForcedSubtitles = showForcedSubtitles
        } else if key == ProfileSettingKeys.metadataLanguage {
            savedBaseline.metadataLanguage = preferredMetadataLanguage
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
        let language = Self.outboundLanguage(subtitleLanguage)

        var writes: [(SettingKey, SettingJSONValue)] = []
        if subtitleLanguage != savedBaseline.subtitleLanguage {
            writes.append((ProfileSettingKeys.subtitleLanguage, ProfileSettingsWriter.languageValue(language)))
        }
        if subtitleMode != savedBaseline.subtitleMode {
            writes.append((ProfileSettingKeys.subtitleMode, .string(subtitleMode)))
        }
        if showForcedSubtitles != savedBaseline.showForcedSubtitles {
            writes.append((ProfileSettingKeys.showForcedSubtitles, .bool(showForcedSubtitles == "on")))
        }
        guard !writes.isEmpty else { return }

        saveState = .saving

        // Every key is attempted even when an earlier one fails. They are
        // independent rows with no ordering between them, so stopping at the
        // first error would mean a hiccup writing the language silently
        // prevented the mode and forced-subtitle choices from ever being
        // sent — the user changed one control and lost two others. The first
        // failure is what gets reported; a repeat of a write that already
        // landed replays its mutation id and is a no-op server-side.
        var firstFailure: Error?
        for (key, value) in writes {
            do {
                try await writer.write(key, value: value)
                // Only a key that actually landed advances the baseline. A
                // failed one stays "changed" so the next save retries it —
                // under its original mutation id, which the writer holds.
                adoptBaseline(for: key)
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }

        if let firstFailure {
            saveState = Self.saveState(for: firstFailure)
            return
        }
        saveState = .saved
        // Keep the detail page's track ordering in step without a refetch.
        ProfilePrefsStore.shared.setPreferredSubtitleLanguage(language)
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
        guard preferredMetadataLanguage != savedBaseline.metadataLanguage else { return }
        pendingMetadataLanguage = .some(Self.outboundLanguage(preferredMetadataLanguage))
        guard !isSavingMetadataLanguage else { return }

        isSavingMetadataLanguage = true
        defer { isSavingMetadataLanguage = false }

        while let next = pendingMetadataLanguage {
            pendingMetadataLanguage = nil
            await writeMetadataLanguage(next)
        }
    }

    @MainActor
    private func writeMetadataLanguage(_ language: String?) async {
        saveState = .saving
        do {
            try await writer.write(
                ProfileSettingKeys.metadataLanguage,
                value: ProfileSettingsWriter.languageValue(language)
            )
            // A newer edit landed while this was in flight; let its own pass
            // report, or this one would announce a value already superseded.
            guard Self.outboundLanguage(preferredMetadataLanguage) == language else { return }
            adoptBaseline(for: ProfileSettingKeys.metadataLanguage)
            saveState = .saved
            ResponseCache.shared.invalidateAllItemMetadata()
            #if os(tvOS)
            ItemDetailCache.shared.clearAll()
            #endif
        } catch {
            guard Self.outboundLanguage(preferredMetadataLanguage) == language else { return }
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
