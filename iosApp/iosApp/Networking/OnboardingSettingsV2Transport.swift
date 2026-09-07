import Foundation

#if !os(tvOS)
/// Binds setting choices to the owner that loaded the flow, before suspension.
final class OnboardingSettingsV2Transport: OnboardingTourAPI, @unchecked Sendable {
    private let api: SiloAPI
    private let settings: CanonicalProfileSettingsV2
    private let journal: SettingsMutationJournal
    private let lock = NSLock()
    private var owner: CapturedDurableAccountAuth?

    init(api: SiloAPI = .shared, tokens: TokenStore = .shared,
         journal: SettingsMutationJournal? = nil, profileJournal: SettingsMutationJournal? = nil) {
        self.api = api
        settings = CanonicalProfileSettingsV2(api: api, tokens: tokens, journal: journal)
        self.journal = profileJournal ?? journal ?? SettingsMutationJournal.sharedCanonical
    }

    func onboardingFlow(surface: String) async throws -> OnboardingFlow {
        let captured = try await settings.capture()
        lock.withLock { owner = nil }
        let flow = try await api.onboardingFlow(surface: surface)
        try await settings.requireCurrent(captured)
        lock.withLock { owner = captured }
        return flow
    }

    private func capturedOwner() async throws -> CapturedDurableAccountAuth {
        guard let captured = lock.withLock({ owner }) else { throw SettingsMutationHold.noAuthority }
        try await settings.requireCurrent(captured)
        return captured
    }

    func requireCurrentFlowOwner() async throws { _ = try await capturedOwner() }
    func flowSettingsOwner() async throws -> CapturedDurableAccountAuth? { try await capturedOwner() }

    func postOnboardingProgress(_ request: OnboardingProgressRequest) async throws {
        let captured = try await capturedOwner()
        try await api.postOnboardingProgress(request)
        try await settings.requireCurrent(captured)
    }

    func updateProfile(profileId: String, body: UpdateProfileBody) async throws {
        let captured = try await capturedOwner()
        guard profileId == captured.request.profileId else { throw HTTPError.requestIdentityChanged }
        let patch = body.asAPIv2Patch
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        let command = SettingsMutationCommand(id: UUID(), authority: try SettingsMutationAuthority(captured),
            key: "onboarding.profile", method: "PATCH", path: "/api/v2/profiles/\(profileId)",
            query: [:], body: try encoder.encode(patch), state: .prepared)
        try journal.append(command)
        try await settings.requireCurrent(captured)
        let sent = try journal.claim(command.id)
        _ = try await api.v2.updateProfile(id: profileId, patch: patch, auth: captured.request)
        try await settings.requireCurrent(captured)
        try journal.acknowledge(sent)
    }

    func setSetting(key: String, value: String) async throws {
        try await write(key: key, raw: value, scope: .profile)
    }

    func setDeviceSetting(key: String, value: String) async throws {
        try await write(key: key, raw: value, scope: .profileDevice)
    }

    private func write(key: String, raw: String, scope: SettingScope) async throws {
        let captured = try await capturedOwner()
        // These are declared canonical keys; legacy aliases are never converted.
        let value: SettingJSONValue
        switch key {
        case SettingKey.playbackAutoPlayNext.rawValue,
             SettingKey.playbackAutoSkipIntro.rawValue, SettingKey.playbackAutoSkipCredits.rawValue,
             SettingKey.playbackShowForcedSubtitles.rawValue:
            switch raw.lowercased() {
            case "true", "1", "yes", "on": value = .bool(true)
            case "false", "0", "no", "off": value = .bool(false)
            default: throw SettingsAPIError.invalidValue(message: "Expected a boolean setting value.")
            }
        case SettingKey.playbackPreferredQuality.rawValue, SettingKey.playbackSubtitleMode.rawValue:
            value = .string(raw)
        case SettingKey.playbackSubtitleLanguage.rawValue, SettingKey.catalogMetadataLanguage.rawValue:
            value = ProfileSettingsWriter.languageValue(raw)
        default: throw SettingsAPIError.unknownSetting(key: key)
        }
        guard let settingKey = SettingKey(rawValue: key) else { throw SettingsAPIError.unknownSetting(key: key) }
        try await settings.write(key: settingKey, value: value, scope: scope, owner: captured)
    }
}
#endif
