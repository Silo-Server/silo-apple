import Foundation
import SwiftUI

/// Profile overlay preferences use canonical v2 values. A server without that
/// contract leaves a visible error; it never redirects a write to legacy storage.
@MainActor
final class OverlayPrefsStore: ObservableObject {
    static let shared = OverlayPrefsStore()
    @Published private(set) var enabled = true
    @Published private(set) var prefs = OverlaySchema.buildDefaults()
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    private(set) var hasUserOverride = false
    private var hasHydrated = false
    private var adminDefaultsRaw: String?
    private var generation: UInt = 0
    private var owner: CapturedDurableAccountAuth?
    private var pendingWrite: Task<Void, Never>?
    private let api: SiloAPI
    private let settings: CanonicalProfileSettingsV2

    init(api: SiloAPI = .shared, tokens: TokenStore = .shared, journal: SettingsMutationJournal? = nil) {
        self.api = api
        settings = CanonicalProfileSettingsV2(api: api, tokens: tokens, journal: journal)
    }

    @discardableResult
    func hydrateIfNeeded() async -> Bool {
        guard !hasHydrated, !isLoading else { return false }
        await refresh()
        return true
    }

    func refresh() async {
        generation &+= 1
        let capturedGeneration = generation
        isLoading = true
        lastError = nil
        defer { if generation == capturedGeneration { isLoading = false } }
        do {
            let captured = try await settings.capture()
            let config = try await api.overlayConfig()
            try await settings.requireCurrent(captured)
            guard generation == capturedGeneration else { return }
            enabled = config.enabled
            adminDefaultsRaw = config.defaults
            let response = try await settings.read([.uiCardOverlays], owner: captured)
            guard generation == capturedGeneration else { return }
            let entry = response.value(for: .uiCardOverlays)
            let userRaw = entry?.source == .scope(.profile) && entry?.value != .null
                ? entry.flatMap { Self.jsonString(from: $0.value) } : nil
            owner = captured
            enabled = config.enabled
            adminDefaultsRaw = config.defaults
            hasUserOverride = userRaw != nil
            prefs = OverlaySchema.parse(userRaw ?? config.defaults)
            hasHydrated = true
        } catch {
            guard generation == capturedGeneration else { return }
            hasHydrated = false
            lastError = error.localizedDescription
        }
    }

    func setPrefs(_ next: CardOverlayPrefs) async {
        guard let owner else { lastError = SettingsMutationHold.noAuthority.localizedDescription; return }
        guard let value = Self.jsonValue(from: OverlaySchema.serialize(next)) else {
            lastError = "Overlay prefs did not serialize to JSON."
            return
        }
        await persist(value, owner: owner)
    }

    func resetToDefaults() async {
        guard let owner else { lastError = SettingsMutationHold.noAuthority.localizedDescription; return }
        await persist(nil, owner: owner)
    }

    private func persist(_ value: SettingJSONValue?, owner: CapturedDurableAccountAuth) async {
        let capturedGeneration = generation
        do {
            // Persist before scheduling any dispatch. Each intent retains its own
            // bytes; serialized tasks cannot cancel uncertainty into a DELETE.
            let id = try await settings.prepare(key: .uiCardOverlays, value: value, owner: owner)
            guard generation == capturedGeneration else { return }
            let predecessor = pendingWrite
            let task = Task { [weak self] in
                await predecessor?.value
                guard let self else { return }
                do {
                    try await self.settings.send(id, owner: owner)
                    guard self.generation == capturedGeneration else { return }
                    self.hasUserOverride = value != nil
                    self.prefs = OverlaySchema.parse(value.flatMap { Self.jsonString(from: $0) } ?? self.adminDefaultsRaw)
                    self.lastError = nil
                } catch {
                    guard self.generation == capturedGeneration,
                          (try? await self.settings.requireCurrent(owner)) != nil else { return }
                    self.lastError = error.localizedDescription
                }
            }
            pendingWrite = task
            await task.value
        } catch {
            guard generation == capturedGeneration,
                  (try? await settings.requireCurrent(owner)) != nil else { return }
            lastError = error.localizedDescription
        }
    }

    func clear() {
        generation &+= 1
        // An already dispatched write keeps its original owner. Queued tasks
        // recheck that owner before dispatch; clearing never deletes the journal.
        pendingWrite = nil
        owner = nil
        isLoading = false
        enabled = true
        prefs = OverlaySchema.buildDefaults()
        adminDefaultsRaw = nil
        hasUserOverride = false
        hasHydrated = false
        lastError = nil
    }

    // MARK: - Wire bridging

    /// The contract stores the document as a JSON object; `OverlaySchema`
    /// speaks JSON strings (shared with the admin `overlay-config`
    /// baseline, which still travels as a string). These two hops keep
    /// one codec — `OverlaySchema` — as the single interpreter of the
    /// document shape.
    private static func jsonString(from value: SettingJSONValue) -> String? {
        guard let data = try? SettingsWireCoding.makeEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func jsonValue(from raw: String) -> SettingJSONValue? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? SettingsWireCoding.makeDecoder().decode(SettingJSONValue.self, from: data)
    }

}
