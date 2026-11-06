//
//  AppLanguagePreferences.swift
//  Silo (iOS + tvOS + macOS)
//
//  The profile's app language (`ui.app_language`) and the system per-app
//  language are one knob:
//
//  - The root shows the profile's language at once, through `\.locale` and
//    `\.layoutDirection`.
//  - Silo also writes it as the app's own `AppleLanguages`, so system UI,
//    permission prompts and anything missed follow after the next launch. On
//    iOS and macOS that key is what Settings → Silo → Language edits.
//  - A ledger records what Silo wrote and what was there before, so a profile
//    without a language restores the user's own value, and a change the user
//    makes in system settings afterwards is never overwritten: the next launch
//    writes it back as this device's `profile_device` value.
//
//  `null` means follow the device. A tag the build doesn't ship (no match)
//  behaves as `null` but stays stored and shown in the picker.
//

import Foundation

/// What Silo last wrote to the app's `AppleLanguages`, and what the key held
/// before Silo first wrote it (`nil`: absent).
struct AppLanguageLedger: Codable, Equatable, Sendable {
    var applied: String
    var baseline: [String]?
}

enum AppLanguageReconciler {
    enum Write: Equatable, Sendable {
        case set([String])
        case remove
    }

    struct Decision: Equatable, Sendable {
        var write: Write?
        var ledger: AppLanguageLedger?
    }

    /// What to do with the app's `AppleLanguages` (`current`) when the active
    /// profile's matched language is `override` (nil: follow the device).
    static func reconcile(current: [String]?, override: String?, ledger: AppLanguageLedger?) -> Decision {
        let ownsCurrent = ledger.map { current == [$0.applied] } ?? false
        if let override {
            // A value the user set after Silo's (or before any) is the one to
            // come back to.
            let baseline = ownsCurrent ? ledger?.baseline : current
            return Decision(
                write: current == [override] ? nil : .set([override]),
                ledger: AppLanguageLedger(applied: override, baseline: baseline)
            )
        }
        guard let ledger, ownsCurrent, ledger.baseline != current else {
            return Decision(write: nil, ledger: nil)
        }
        return Decision(write: ledger.baseline.map(Write.set) ?? .remove, ledger: nil)
    }

    /// A change the user made in system settings after Silo applied a
    /// language, as the value to write back (`tag` nil: follow the device).
    /// Nil when there is nothing to write back.
    static func systemChoice(
        current: [String]?,
        ledger: AppLanguageLedger?,
        shipped: [String]
    ) -> AppLanguageSystemChoice? {
        guard let ledger, current != [ledger.applied] else { return nil }
        return AppLanguageSystemChoice(tag: current?.first.flatMap { AppLanguage.match($0, shipped: shipped) })
    }
}

struct AppLanguageSystemChoice: Equatable, Sendable {
    let tag: String?
}

/// The app's language state on this device.
@MainActor
protocol AppLanguageSystem: AnyObject {
    /// The app's own `AppleLanguages`, never the global list.
    var appValue: [String]? { get }
    /// The list the next launch resolves: the app's value, else the device's.
    var effectiveList: [String] { get }
    var ledger: AppLanguageLedger? { get set }
    func write(_ write: AppLanguageReconciler.Write)
    func storeDisplayed(_ tag: String)
}

@MainActor
final class StandardAppLanguageSystem: AppLanguageSystem {
    private static let key = "AppleLanguages"
    private static let ledgerKey = "appLanguage.ledger.v1"
    private let defaults = UserDefaults.standard

    var appValue: [String]? {
        guard let domain = Bundle.main.bundleIdentifier else { return nil }
        return defaults.persistentDomain(forName: domain)?[Self.key] as? [String]
    }

    var effectiveList: [String] {
        defaults.stringArray(forKey: Self.key) ?? Locale.preferredLanguages
    }

    var ledger: AppLanguageLedger? {
        get { defaults.data(forKey: Self.ledgerKey).flatMap { try? JSONDecoder().decode(AppLanguageLedger.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.ledgerKey)
            } else {
                defaults.removeObject(forKey: Self.ledgerKey)
            }
        }
    }

    func write(_ write: AppLanguageReconciler.Write) {
        switch write {
        case .set(let tags): defaults.set(tags, forKey: Self.key)
        case .remove: defaults.removeObject(forKey: Self.key)
        }
    }

    func storeDisplayed(_ tag: String) {
        AppLanguage.storeDisplayedTag(tag)
    }
}

@MainActor
@Observable
final class AppLanguagePreferences {
    static let shared = AppLanguagePreferences()

    /// The profile's stored value, for the picker.
    struct Choice: Equatable, Sendable {
        /// Nil: Match Device.
        var tag: String?
        /// This device's own row (a system choice written back) won.
        var isDeviceValue: Bool
    }

    /// The shipped language on screen. Always set: when following the device
    /// it is what the device's list resolves to, so a profile without a
    /// language switches back at once.
    private(set) var displayed: String
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    /// The answer for ``loadedIdentity``; nil before one arrives or on a
    /// server without the setting.
    private var choice: Choice?
    private var loadedIdentity: HTTPRequestIdentity?

    @ObservationIgnored let shipped: [String]
    @ObservationIgnored private let transport: TitleArtTransport
    @ObservationIgnored private let requestIdentity: @MainActor () -> HTTPRequestIdentity?
    @ObservationIgnored private let system: AppLanguageSystem
    /// A system choice still to write back. Held for this process only: until
    /// it is sent the ledger is untouched, so the next launch finds it again.
    @ObservationIgnored private var pendingSystemChoice: AppLanguageSystemChoice?
    /// One write-back at a time, so a profile switch mid-write can't send it
    /// to a second profile.
    @ObservationIgnored private var isWritingBack = false
    @ObservationIgnored private var refreshSequence = 0

    init(
        transport: TitleArtTransport = SiloTitleArtTransport(),
        requestIdentity: @escaping @MainActor () -> HTTPRequestIdentity? = TitleArtPreferences.activeRequestIdentity,
        system: AppLanguageSystem? = nil,
        shipped: [String] = AppLanguage.shipped
    ) {
        self.transport = transport
        self.requestIdentity = requestIdentity
        let system = system ?? StandardAppLanguageSystem()
        self.system = system
        self.shipped = shipped
        // Before Silo writes anything in this process.
        pendingSystemChoice = AppLanguageReconciler.systemChoice(
            current: system.appValue, ledger: system.ledger, shipped: shipped
        )
        displayed = AppLanguage.match(preferences: system.effectiveList, shipped: shipped)
        system.storeDisplayed(displayed)
    }

    var locale: Locale { AppLanguage.locale(for: displayed) }
    var isRightToLeft: Bool { AppLanguage.isRightToLeft(displayed) }

    /// The stored value for the active profile; nil hides the picker.
    var currentChoice: Choice? {
        let loaded = choice
        guard let identity = requestIdentity(), identity == loadedIdentity else { return nil }
        return loaded
    }

    // MARK: Refresh

    func refresh() async {
        guard let identity = requestIdentity() else { return }
        if identity != loadedIdentity {
            loadedIdentity = identity
            choice = nil
            errorMessage = nil
        }
        // Also a change made in system settings while Silo runs (macOS keeps
        // the app open). Only Silo and the system write the key, and Silo
        // updates the ledger with each of its own writes.
        if pendingSystemChoice == nil, !isWritingBack {
            pendingSystemChoice = AppLanguageReconciler.systemChoice(
                current: system.appValue, ledger: system.ledger, shipped: shipped
            )
        }
        refreshSequence += 1
        let sequence = refreshSequence
        switch await transport.contractCapabilities(requestIdentity: identity) {
        case .available(let capabilities) where capabilities.supports(.uiAppLanguage):
            break
        case .available, .serverUpgradeRequired, .unavailable:
            // No app language here: follow the device, but keep a system
            // choice still to write back for a server that has one.
            guard isCurrent(identity, sequence) else { return }
            choice = nil
            if pendingSystemChoice == nil, !isWritingBack { apply(override: nil) }
            return
        case .failed:
            return
        }
        guard isCurrent(identity, sequence), !isWritingBack else { return }
        if let pending = pendingSystemChoice {
            guard await writeBack(pending, identity: identity) else { return }
            // A refresh started meanwhile (a profile switch) skipped its read.
            guard isCurrent(identity, sequence) else { return await refresh() }
        }
        await read(identity: identity, sequence: sequence)
    }

    /// Sends a system choice as this device's value. False while it is still
    /// to send: until then nothing from the server is applied, so the
    /// profile's value can't replace the user's choice.
    private func writeBack(_ pending: AppLanguageSystemChoice, identity: HTTPRequestIdentity) async -> Bool {
        isWritingBack = true
        defer { isWritingBack = false }
        do {
            try await transport.putValue(
                key: .uiAppLanguage,
                scope: .profileDevice,
                value: pending.tag.map(SettingJSONValue.string) ?? .null,
                requestIdentity: identity
            )
        } catch {
            switch SettingsAPIError.from(error) {
            case .transport, .ownerChanged:
                return false
            case .server(let status, _, _) where status >= 500 || status == 429:
                return false
            default:
                // Refused for good: the profile's value applies again, and the
                // user's value stays the one to come back to.
                pendingSystemChoice = nil
                return true
            }
        }
        pendingSystemChoice = nil
        // The server now holds it, so record it even if the read fails.
        apply(override: pending.tag)
        return true
    }

    private func read(identity: HTTPRequestIdentity, sequence: Int) async {
        guard let response = try? await transport.effectiveValues(keys: [.uiAppLanguage], requestIdentity: identity),
              isCurrent(identity, sequence), pendingSystemChoice == nil,
              let row = response.value(for: .uiAppLanguage) else { return }
        var tag: String?
        if case .string(let value) = row.value { tag = value }
        choice = Choice(tag: tag, isDeviceValue: row.source == .scope(.profileDevice))
        apply(override: tag.flatMap { AppLanguage.match($0, shipped: shipped) })
    }

    private func isCurrent(_ identity: HTTPRequestIdentity, _ sequence: Int) -> Bool {
        sequence == refreshSequence && requestIdentity() == identity
    }

    private func apply(override: String?) {
        let decision = AppLanguageReconciler.reconcile(
            current: system.appValue, override: override, ledger: system.ledger
        )
        if let write = decision.write { system.write(write) }
        system.ledger = decision.ledger
        let next = override ?? AppLanguage.match(preferences: system.effectiveList, shipped: shipped)
        // Every assignment re-renders the whole app from the root.
        if next != displayed { displayed = next }
        system.storeDisplayed(next)
    }

    // MARK: Picker

    struct Option: Identifiable, Equatable, Sendable {
        /// Nil: Match Device.
        let tag: String?
        let label: String
        var id: String { tag ?? "" }
    }

    static let matchDeviceLabel = "Match Device"

    /// Match Device, each shipped language by its own name, and a stored tag
    /// the build doesn't ship as itself, so re-saving never clears it (D5).
    var options: [Option] {
        var tags = shipped.sorted {
            AppLanguage.endonym($0).localizedStandardCompare(AppLanguage.endonym($1)) == .orderedAscending
        }
        if let stored = currentChoice?.tag, !tags.contains(stored) { tags.append(stored) }
        return [Option(tag: nil, label: Self.matchDeviceLabel)]
            + tags.map { Option(tag: $0, label: AppLanguage.endonym($0)) }
    }

    var selectedLabel: String {
        currentChoice?.tag.map(AppLanguage.endonym) ?? Self.matchDeviceLabel
    }

    /// Footer text for the picker.
    var footer: String {
        if let stored = currentChoice?.tag, AppLanguage.match(stored, shipped: shipped) == nil {
            return "Silo isn’t available in \(AppLanguage.endonym(stored)) yet, so it uses the device language."
        }
        return "The language of Silo’s menus and buttons on this profile. Audio and subtitle languages are set in Playback."
    }

    /// Saves the profile's language (nil: Match Device) and clears this
    /// device's own value, so the choice takes effect here too.
    func select(_ tag: String?) async {
        // The shown language over this device's own row still saves: it makes
        // that language the profile's.
        guard let identity = requestIdentity(), identity == loadedIdentity,
              let current = choice, current.tag != tag || current.isDeviceValue, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        // Show the choice at once; the read below settles it.
        choice = Choice(tag: tag, isDeviceValue: false)
        do {
            try await transport.putValue(
                key: .uiAppLanguage,
                scope: .profile,
                value: tag.map(SettingJSONValue.string) ?? .null,
                requestIdentity: identity
            )
            if current.isDeviceValue {
                do {
                    try await transport.deleteValue(key: .uiAppLanguage, scope: .profileDevice, requestIdentity: identity)
                } catch SettingsAPIError.noValueAtScope {}
            }
            // An explicit Match Device also clears the app's own system
            // language, instead of bringing back one from before Silo's.
            if tag == nil, var ledger = system.ledger {
                ledger.baseline = nil
                system.ledger = ledger
            }
        } catch {
            choice = current
            errorMessage = Self.writeFailureMessage(for: error)
        }
        isSaving = false
        // Success or not, show what the server now resolves: a failed step may
        // have landed anyway.
        guard requestIdentity() == identity else { return }
        refreshSequence += 1
        await read(identity: identity, sequence: refreshSequence)
    }

    static func writeFailureMessage(for error: Error) -> String {
        switch SettingsAPIError.from(error) {
        case .transport:
            return "Couldn't save the app language. Check the connection and try again."
        case .serverUpgradeRequired, .unknownSetting, .scopeNotAllowed:
            return "This server can't save the app language."
        default:
            return "The server didn't save the app language. Try again."
        }
    }
}
