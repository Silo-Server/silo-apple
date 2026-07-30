import XCTest
@testable import Silo

/// Tests for the two things C2c moved onto the canonical settings contract:
/// the shared quality presets (`playback.preferred_quality` +
/// `playback.max_bitrate_kbps`) and the profile-scoped preferences that used
/// to travel as fields on `PUT /profiles/{id}`.
///
/// The preset table is asserted against the *contract*, not against a copy of
/// itself: a preset whose resolution is not a member of the manifest's enum is
/// a permanent `invalid_value` on the server, and the failure would otherwise
/// only show up as a preference that silently stops syncing.
@MainActor
final class ProfileAndQualitySettingsTests: XCTestCase {

    // MARK: - Preset table

    /// The contract's `playback.preferred_quality` members. Spelled out here
    /// rather than read from the generated bindings because the bindings
    /// generate the key list, not each key's enum — so this is the pin that
    /// catches a preset naming a resolution the server would refuse.
    private static let contractResolutions: Set<String> = [
        "auto", "480p", "720p", "1080p", "2160p", "original",
    ]

    func testEveryPresetResolutionIsAContractEnumMember() {
        for preset in SiloQualityPresets.all {
            XCTAssertTrue(
                Self.contractResolutions.contains(preset.resolution),
                "preset \(preset.id) sends resolution \(preset.resolution), which the contract's enum does not define"
            )
        }
    }

    func testEveryPresetBitrateIsWithinTheContractsBounds() {
        for preset in SiloQualityPresets.all {
            guard let bitrate = preset.bitrateKbps else { continue }
            // The manifest declares minimum 100, maximum 200000 on
            // playback.max_bitrate_kbps.
            XCTAssertGreaterThanOrEqual(bitrate, 100, "preset \(preset.id) is below the contract minimum")
            XCTAssertLessThanOrEqual(bitrate, 200_000, "preset \(preset.id) is above the contract maximum")
        }
    }

    /// The preset ids, labels and pairs the web and Android clients ship, in
    /// order. A divergence here is a user seeing "1080p High" mean one thing on
    /// the phone and another in a browser, which is exactly what the shared
    /// table exists to prevent.
    func testPresetTableMatchesTheOtherClients() {
        let expected: [(id: String, label: String, resolution: String, bitrate: Int?)] = [
            ("auto", "Auto", "auto", nil),
            ("original", "Original", "original", nil),
            ("2160p", "4K", "2160p", nil),
            ("1080p-high", "1080p High", "1080p", 10_000),
            ("1080p", "1080p", "1080p", 6_000),
            ("1080p-low", "1080p Low", "1080p", 3_000),
            ("720p-high", "720p High", "720p", 4_000),
            ("720p", "720p", "720p", 2_000),
            ("480p", "480p", "480p", 1_500),
        ]

        XCTAssertEqual(SiloQualityPresets.all.count, expected.count)
        for (actual, want) in zip(SiloQualityPresets.all, expected) {
            XCTAssertEqual(actual.id, want.id)
            XCTAssertEqual(actual.label, want.label, "\(want.id) label")
            XCTAssertEqual(actual.resolution, want.resolution, "\(want.id) resolution")
            XCTAssertEqual(actual.bitrateKbps, want.bitrate, "\(want.id) bitrate")
        }
    }

    func testEveryPresetRoundTripsFromItsStoredPair() {
        for preset in SiloQualityPresets.all {
            let recovered = SiloQualityPresets.preset(
                resolution: preset.resolution,
                bitrateKbps: preset.bitrateKbps
            )
            XCTAssertEqual(recovered?.id, preset.id, "\(preset.id) did not round-trip")
        }
    }

    /// Two presets share the `1080p` resolution and differ only by bitrate, so
    /// a lookup that ignored the bitrate axis would collapse them.
    func testPresetsAreDistinguishedByBothAxes() {
        XCTAssertEqual(SiloQualityPresets.preset(resolution: "1080p", bitrateKbps: 10_000)?.id, "1080p-high")
        XCTAssertEqual(SiloQualityPresets.preset(resolution: "1080p", bitrateKbps: 6_000)?.id, "1080p")
        XCTAssertEqual(SiloQualityPresets.preset(resolution: "1080p", bitrateKbps: 3_000)?.id, "1080p-low")
    }

    /// A pair no preset covers must report itself rather than resolve to a
    /// nearby preset: showing "1080p" for a stored 1080p/8000 would tell the
    /// user their cap is 6 Mbps when it is 8.
    func testAPairNoPresetCoversHasNoPresetAndDescribesItself() {
        XCTAssertNil(SiloQualityPresets.preset(resolution: "1080p", bitrateKbps: 8_000))
        XCTAssertEqual(SiloQualityPresets.describe(resolution: "1080p", bitrateKbps: 8_000), "1080p at 8 Mbps")
        XCTAssertEqual(SiloQualityPresets.describe(resolution: "720p", bitrateKbps: 1_800), "720p at 1.8 Mbps")
        // A covered pair answers with the preset's own label.
        XCTAssertEqual(SiloQualityPresets.describe(resolution: "720p", bitrateKbps: 4_000), "720p High")
        XCTAssertEqual(SiloQualityPresets.describe(resolution: "auto", bitrateKbps: nil), "Auto")
        XCTAssertEqual(SiloQualityPresets.describe(resolution: "2160p", bitrateKbps: nil), "4K")
    }

    /// Legacy compound spellings reduce to the contract's enum. The bitrate
    /// half is dropped rather than guessed at — the bitrate axis carries it,
    /// and inventing a cap would silently throttle playback.
    func testCompoundLegacyResolutionsNormalizeToContractMembers() {
        XCTAssertEqual(SiloQualityPresets.normalizeResolution("1080p-high"), "1080p")
        XCTAssertEqual(SiloQualityPresets.normalizeResolution("720p-medium"), "720p")
        XCTAssertEqual(SiloQualityPresets.normalizeResolution("1080p-8"), "1080p")
        XCTAssertEqual(SiloQualityPresets.normalizeResolution("4k"), "2160p")
        XCTAssertEqual(SiloQualityPresets.normalizeResolution("uhd"), "2160p")
        XCTAssertEqual(SiloQualityPresets.normalizeResolution("  1080P  "), "1080p")
        // 328p and 420p predate the contract's ladder and have no member.
        XCTAssertEqual(SiloQualityPresets.normalizeResolution("328p"), "auto")
        XCTAssertEqual(SiloQualityPresets.normalizeResolution(nil), "auto")
        XCTAssertEqual(SiloQualityPresets.normalizeResolution(""), "auto")
        XCTAssertEqual(SiloQualityPresets.normalizeResolution("1440p"), "auto")

        for resolution in SiloQualityPresets.all.map(\.resolution) {
            XCTAssertTrue(
                Self.contractResolutions.contains(SiloQualityPresets.normalizeResolution(resolution)),
                "normalizing \(resolution) escaped the contract's enum"
            )
        }
    }

    // MARK: - Preset writes

    func testApplyingAPresetWritesBothAxes() async throws {
        let harness = try PlayerSettingsHarness()
        let preset = try XCTUnwrap(SiloQualityPresets.preset(id: "720p-high"))

        harness.settings.setQualityPreset(preset)
        await harness.settings.flushPendingDeviceSettings()

        let byKey = harness.transport.writesByKey()
        XCTAssertEqual(byKey[.playbackPreferredQuality]?.value, .string("720p"))
        XCTAssertEqual(byKey[.playbackMaxBitrateKbps]?.value, .int(4_000))
        XCTAssertEqual(harness.settings.currentQualityPreset?.id, "720p-high")
    }

    /// An uncapped preset must send an explicit null, not omit the write:
    /// leaving the previous cap in place would keep throttling a preference the
    /// user just widened.
    func testAnUncappedPresetClearsTheBitrateAxis() async throws {
        let harness = try PlayerSettingsHarness()

        harness.settings.setQualityPreset(try XCTUnwrap(SiloQualityPresets.preset(id: "480p")))
        await harness.settings.flushPendingDeviceSettings()
        harness.transport.reset()

        harness.settings.setQualityPreset(try XCTUnwrap(SiloQualityPresets.preset(id: "2160p")))
        await harness.settings.flushPendingDeviceSettings()

        let byKey = harness.transport.writesByKey()
        XCTAssertEqual(byKey[.playbackPreferredQuality]?.value, .string("2160p"))
        XCTAssertEqual(byKey[.playbackMaxBitrateKbps]?.value, .null)
        XCTAssertNil(harness.settings.maxBitrateKbps)
    }

    /// Every preset must survive a write/read cycle unchanged. This is the
    /// regression that motivated storing the pair: `1080p-high` names 10 Mbps
    /// in the preset table and 20 Mbps in the in-player ladder, so a client
    /// that stored the *id* would reinterpret the user's choice depending on
    /// which table read it back.
    func testEveryPresetSurvivesAServerRoundTrip() async throws {
        for preset in SiloQualityPresets.all {
            let harness = try PlayerSettingsHarness()
            harness.settings.setQualityPreset(preset)
            await harness.settings.flushPendingDeviceSettings()

            let byKey = harness.transport.writesByKey()
            let sentResolution = try XCTUnwrap(byKey[.playbackPreferredQuality]?.value.stringValue)
            let sentBitrate = byKey[.playbackMaxBitrateKbps]?.value.intValue

            // Feed exactly what was sent back as the server's answer.
            harness.transport.effective = [
                .init(
                    key: SettingKey.playbackPreferredQuality.rawValue,
                    value: .string(sentResolution),
                    source: .scope(.profileDevice),
                    scope: .profileDevice
                ),
                .init(
                    key: SettingKey.playbackMaxBitrateKbps.rawValue,
                    value: sentBitrate.map { .int($0) } ?? .null,
                    source: .scope(.profileDevice),
                    scope: .profileDevice
                ),
            ]
            await harness.settings.refreshFromServer()

            XCTAssertEqual(
                harness.settings.currentQualityPreset?.id, preset.id,
                "\(preset.id) did not survive the round trip"
            )
        }
    }

    /// A pair authored elsewhere is adopted verbatim rather than snapped onto
    /// this client's ladder. Quantizing here would rewrite the profile's stored
    /// choice on the next edit made from this device.
    func testAForeignPairIsAdoptedWithoutBeingQuantized() async throws {
        let harness = try PlayerSettingsHarness()
        harness.transport.effective = [
            .init(
                key: SettingKey.playbackPreferredQuality.rawValue,
                value: .string("1080p"),
                source: .scope(.profile),
                scope: .profile
            ),
            .init(
                key: SettingKey.playbackMaxBitrateKbps.rawValue,
                value: .int(8_000),
                source: .scope(.profile),
                scope: .profile
            ),
        ]
        await harness.settings.refreshFromServer()

        XCTAssertEqual(harness.settings.preferredQualityResolution, "1080p")
        XCTAssertEqual(harness.settings.maxBitrateKbps, 8_000)
        // No preset covers it, so the UI describes the pair rather than
        // showing a preset the user never chose.
        XCTAssertNil(harness.settings.currentQualityPreset)
        XCTAssertEqual(harness.settings.preferredQualityLabel, "1080p at 8 Mbps")
    }

    /// The server spells uncapped as JSON null; the client must read that as
    /// "no cap" rather than as the integer 0, which the contract would refuse.
    func testANullBitrateReadsBackAsUncapped() async throws {
        let harness = try PlayerSettingsHarness()
        harness.transport.effective = [
            .init(
                key: SettingKey.playbackPreferredQuality.rawValue,
                value: .string("original"),
                source: .scope(.profile),
                scope: .profile
            ),
            .init(
                key: SettingKey.playbackMaxBitrateKbps.rawValue,
                value: .null,
                source: .contractDefault
            ),
        ]
        await harness.settings.refreshFromServer()

        XCTAssertNil(harness.settings.maxBitrateKbps)
        XCTAssertEqual(harness.settings.currentQualityPreset?.id, "original")
    }

    // MARK: - Profile-scoped writes

    func testSubtitlePrefsAreWrittenAtProfileScope() async throws {
        let transport = FakeProfileSettingsTransport()
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))

        editor.subtitleLanguage = "ja"
        editor.subtitleMode = SubtitleMode.always.rawValue
        editor.showForcedSubtitles = "off"
        await editor.saveSubtitlePrefs()

        let byKey = transport.writesByKey()
        XCTAssertEqual(byKey[.playbackSubtitleLanguage]?.value, .string("ja"))
        XCTAssertEqual(byKey[.playbackSubtitleMode]?.value, .string("always"))
        XCTAssertEqual(byKey[.playbackShowForcedSubtitles]?.value, .bool(false))
        XCTAssertEqual(editor.saveState, .saved)
    }

    /// "No preference" is the contract's null. The legacy profile endpoint
    /// spelled it as the empty string, which the `language_tag` validator
    /// rejects outright — so sending "" here would be a permanent
    /// `invalid_value`.
    func testNoLanguagePreferenceIsSentAsNullNotAnEmptyString() async throws {
        let transport = FakeProfileSettingsTransport()
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))

        editor.subtitleLanguage = PlaybackPrefSentinel.none
        editor.preferredMetadataLanguage = PlaybackPrefSentinel.none
        await editor.saveSubtitlePrefs()
        await editor.saveMetadataLanguage()

        let byKey = transport.writesByKey()
        XCTAssertEqual(byKey[.playbackSubtitleLanguage]?.value, .null)
        XCTAssertEqual(byKey[.catalogMetadataLanguage]?.value, .null)
        for write in transport.writes() {
            XCTAssertNotEqual(write.value, .string(""), "\(write.key.rawValue) sent an empty language tag")
        }
    }

    func testMetadataLanguageIsWrittenAtProfileScope() async throws {
        let transport = FakeProfileSettingsTransport()
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))

        editor.preferredMetadataLanguage = "de"
        await editor.saveMetadataLanguage()

        XCTAssertEqual(transport.writesByKey()[.catalogMetadataLanguage]?.value, .string("de"))
        XCTAssertEqual(editor.saveState, .saved)
    }

    /// The spoken-language picker must NOT write here. It is a device-scoped
    /// setting, and the contract resolves `profile_device` above `profile` —
    /// so a profile write would be shadowed by this device's own row and look
    /// like it never saved. Old Apple builds already wrote those device rows,
    /// so the shadowing is real on existing installs.
    func testProfileScopeNeverWritesTheAudioLanguage() async throws {
        let transport = FakeProfileSettingsTransport()
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))

        editor.subtitleLanguage = "fr"
        await editor.saveSubtitlePrefs()
        editor.preferredMetadataLanguage = "fr"
        await editor.saveMetadataLanguage()

        XCTAssertFalse(
            transport.writes().contains { $0.key == .playbackAudioLanguage },
            "playback.audio_language is device-scoped; a profile write would be shadowed by the device row"
        )
        XCTAssertFalse(ProfileSettingKeys.all.contains(.playbackAudioLanguage))
    }

    func testEveryProfileKeyIsReadInOneBatch() async throws {
        let transport = FakeProfileSettingsTransport()
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))

        await editor.load()

        XCTAssertEqual(transport.effectiveCalls().count, 1, "the screen must not fan out one call per key")
        XCTAssertEqual(Set(transport.effectiveCalls().first ?? []), Set(ProfileSettingKeys.all))
    }

    // MARK: - Reads

    func testLoadAdoptsTheResolvedValues() async throws {
        let transport = FakeProfileSettingsTransport()
        transport.effective = [
            .init(key: SettingKey.playbackSubtitleLanguage.rawValue, value: .string("es"),
                  source: .scope(.profile), scope: .profile),
            .init(key: SettingKey.playbackSubtitleMode.rawValue, value: .string("off"),
                  source: .scope(.profile), scope: .profile),
            .init(key: SettingKey.playbackShowForcedSubtitles.rawValue, value: .bool(false),
                  source: .scope(.profile), scope: .profile),
            .init(key: SettingKey.catalogMetadataLanguage.rawValue, value: .string("it"),
                  source: .scope(.profile), scope: .profile),
        ]
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))

        await editor.load()

        XCTAssertEqual(editor.subtitleLanguage, "es")
        XCTAssertEqual(editor.subtitleMode, "off")
        XCTAssertEqual(editor.showForcedSubtitles, "off")
        XCTAssertEqual(editor.preferredMetadataLanguage, "it")
    }

    /// A stored `false` must survive. The contract's default for
    /// `show_forced_subtitles` is true, so a reader that treated a resolved
    /// value as "absent" would flip the toggle back on every refresh.
    func testAStoredFalseIsNotMistakenForAnAbsentValue() async throws {
        let transport = FakeProfileSettingsTransport()
        transport.effective = [
            .init(key: SettingKey.playbackShowForcedSubtitles.rawValue, value: .bool(false),
                  source: .scope(.profile), scope: .profile),
        ]
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))

        await editor.load()

        XCTAssertEqual(editor.showForcedSubtitles, "off")
    }

    /// A null language is "no preference", which the editor shows as its
    /// sentinel rather than as a literal.
    func testANullLanguageBecomesTheNonePickerSentinel() async throws {
        let transport = FakeProfileSettingsTransport()
        transport.effective = [
            .init(key: SettingKey.playbackSubtitleLanguage.rawValue, value: .null,
                  source: .contractDefault),
            .init(key: SettingKey.catalogMetadataLanguage.rawValue, value: .null,
                  source: .contractDefault),
        ]
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))

        await editor.load()

        XCTAssertEqual(editor.subtitleLanguage, PlaybackPrefSentinel.none)
        XCTAssertEqual(editor.preferredMetadataLanguage, PlaybackPrefSentinel.none)
    }

    // MARK: - Server upgrade required

    /// A server with no canonical settings routes is a distinct, actionable
    /// state: the screens explain it instead of rendering a broken control.
    func testAnOldServerSurfacesAsUpgradeRequiredOnRead() async throws {
        let transport = FakeProfileSettingsTransport()
        transport.failReadsWith = .serverUpgradeRequired
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))

        await editor.load()

        XCTAssertTrue(editor.serverUpgradeRequired)
    }

    func testAnOldServerReadDisablesSubsequentProfileSaveAttempts() async throws {
        let transport = FakeProfileSettingsTransport()
        transport.failReadsWith = .serverUpgradeRequired
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))

        await editor.load()
        editor.subtitleLanguage = "en"
        editor.preferredMetadataLanguage = "fr"
        await editor.saveSubtitlePrefs()
        await editor.saveMetadataLanguage()

        XCTAssertTrue(transport.writes().isEmpty)
        XCTAssertEqual(editor.saveState, .serverUpgradeRequired)
    }

    func testAnOldServerSurfacesAsUpgradeRequiredOnWrite() async throws {
        let transport = FakeProfileSettingsTransport()
        transport.failWritesWith = .serverUpgradeRequired
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))

        editor.subtitleLanguage = "en"
        await editor.saveSubtitlePrefs()

        XCTAssertEqual(editor.saveState, .serverUpgradeRequired)
        XCTAssertTrue(editor.serverUpgradeRequired)

        let attempts = transport.writes().count
        editor.subtitleLanguage = "fr"
        await editor.saveSubtitlePrefs()
        XCTAssertEqual(
            transport.writes().count,
            attempts,
            "once the old server is known, later edits must not issue broken requests"
        )
    }

    func testOldServerDetectionStopsAnOverlappingSubtitleSaveDrain() async throws {
        let transport = FakeProfileSettingsTransport()
        transport.failWritesWith = .serverUpgradeRequired
        await transport.writeGate.block(.string("en"))
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))

        editor.subtitleLanguage = "en"
        let firstSave = Task { await editor.saveSubtitlePrefs() }
        await transport.writeGate.waitUntilEntered(.string("en"))

        editor.subtitleLanguage = "fr"
        await editor.saveSubtitlePrefs()
        await transport.writeGate.release(.string("en"))
        await firstSave.value

        XCTAssertEqual(transport.writes().map(\.value), [.string("en")])
        XCTAssertTrue(editor.serverUpgradeRequired)

        transport.failWritesWith = nil
        transport.effective = [
            .init(
                key: SettingKey.playbackSubtitleLanguage.rawValue,
                value: .string("ja"),
                source: .scope(.profile),
                scope: .profile
            ),
        ]
        await editor.load()
        await editor.saveSubtitlePrefs()
        XCTAssertEqual(
            transport.writes().map(\.value),
            [.string("en")],
            "a later successful load must not revive the obsolete queued edit"
        )
    }

    func testOldServerDetectionStopsAnOverlappingMetadataSaveDrain() async throws {
        let transport = FakeProfileSettingsTransport()
        transport.failWritesWith = .serverUpgradeRequired
        await transport.writeGate.block(.string("en"))
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))

        editor.preferredMetadataLanguage = "en"
        let firstSave = Task { await editor.saveMetadataLanguage() }
        await transport.writeGate.waitUntilEntered(.string("en"))

        editor.preferredMetadataLanguage = "fr"
        await editor.saveMetadataLanguage()
        await transport.writeGate.release(.string("en"))
        await firstSave.value

        XCTAssertEqual(transport.writes().map(\.value), [.string("en")])
        XCTAssertTrue(editor.serverUpgradeRequired)

        transport.failWritesWith = nil
        transport.effective = [
            .init(
                key: SettingKey.catalogMetadataLanguage.rawValue,
                value: .string("ja"),
                source: .scope(.profile),
                scope: .profile
            ),
        ]
        await editor.load()
        await editor.saveMetadataLanguage()
        XCTAssertEqual(
            transport.writes().map(\.value),
            [.string("en")],
            "a later successful load must not revive the obsolete queued edit"
        )
    }

    /// A transient read failure must not blank the screen: snapping every
    /// control to a contract default the profile never chose looks exactly like
    /// the server having wiped their settings.
    func testATransientReadFailureLeavesTheEditorAlone() async throws {
        let transport = FakeProfileSettingsTransport()
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))
        editor.subtitleLanguage = "ko"
        editor.showForcedSubtitles = "off"

        transport.failReadsWith = .transport(description: "offline")
        await editor.load()

        XCTAssertEqual(editor.subtitleLanguage, "ko")
        XCTAssertEqual(editor.showForcedSubtitles, "off")
        XCTAssertFalse(editor.serverUpgradeRequired)
    }

    // MARK: - Idempotency

    /// One mutation id per logical write, reused across retries so the server
    /// replays its receipt rather than applying twice.
    func testRetryingTheSameWriteReusesItsMutationId() async throws {
        let transport = FakeProfileSettingsTransport()
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))

        editor.subtitleMode = SubtitleMode.always.rawValue
        transport.failWritesWith = .server(status: 503, code: nil, message: nil)
        await editor.saveSubtitlePrefs()

        transport.failWritesWith = nil
        await editor.saveSubtitlePrefs()

        let modeWrites = transport.writes().filter { $0.key == .playbackSubtitleMode }
        // Two attempts: the failed one and the retry. A count of one means the
        // failed language write earlier in the batch aborted the remaining
        // independent keys, which is
        // the regression this test exists to catch — so it is asserted, not
        // skipped. XCTSkipUnless would report that exact failure as a *skip*,
        // which CI counts as a pass.
        XCTAssertEqual(modeWrites.count, 2,
                       "a failed write must not abort the independent keys after it")
        XCTAssertEqual(modeWrites.first?.mutationId, modeWrites.last?.mutationId,
                       "a retry of the same content must replay its id, not mint a new one")
    }

    func testChangingTheValueMintsAFreshMutationId() async throws {
        let transport = FakeProfileSettingsTransport()
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))

        editor.subtitleMode = SubtitleMode.always.rawValue
        await editor.saveSubtitlePrefs()
        editor.subtitleMode = SubtitleMode.off.rawValue
        await editor.saveSubtitlePrefs()

        let modeWrites = transport.writes().filter { $0.key == .playbackSubtitleMode }
        XCTAssertEqual(modeWrites.count, 2, "each edit must produce its own write")
        // Different content under a reused id is a 409 by design.
        XCTAssertNotEqual(modeWrites.first?.mutationId, modeWrites.last?.mutationId)
    }

    func testSameValueForAnotherProfileMintsAFreshMutationId() async throws {
        let transport = FakeProfileSettingsTransport()
        transport.failWritesWith = .server(status: 503, code: nil, message: nil)
        let writer = ProfileSettingsWriter(transport: transport)

        for profileId in ["profile-1", "profile-2"] {
            do {
                try await writer.write(
                    .playbackSubtitleMode,
                    value: .string(SubtitleMode.always.rawValue),
                    profileId: profileId
                )
                XCTFail("the fake was expected to fail the write")
            } catch {
                // Retryable by design: the writer retains each logical id.
            }
        }

        let writes = transport.writes().filter { $0.key == .playbackSubtitleMode }
        XCTAssertEqual(writes.map(\.profileId), ["profile-1", "profile-2"])
        XCTAssertNotEqual(
            writes.first?.mutationId,
            writes.last?.mutationId,
            "mutation identity includes the profile, not only key and value"
        )
    }

    func testQueuedSubtitleEditsKeepTheProfileThatOwnedEachEdit() async throws {
        let transport = FakeProfileSettingsTransport()
        await transport.writeGate.block(.string("ja"))
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))
        editor.bindProfile(id: "profile-1")
        editor.seed(from: nil)

        editor.subtitleLanguage = "ja"
        let firstSave = Task { @MainActor in await editor.saveSubtitlePrefs() }
        await transport.writeGate.waitUntilEntered(.string("ja"))

        editor.bindProfile(id: "profile-2")
        editor.subtitleLanguage = "ko"
        await editor.saveSubtitlePrefs()
        await transport.writeGate.release(.string("ja"))
        await firstSave.value

        let writes = transport.writes().filter { $0.key == .playbackSubtitleLanguage }
        XCTAssertEqual(writes.map(\.value), [.string("ja"), .string("ko")])
        XCTAssertEqual(writes.map(\.profileId), ["profile-1", "profile-2"])
    }

    func testFailedWriteForPreviousProfileSurvivesAQueuedCurrentProfileEdit() async throws {
        let transport = FakeProfileSettingsTransport()
        await transport.writeGate.block(.string("ja"))
        transport.setWriteFailure(
            .transport(description: "response lost"),
            for: .playbackSubtitleLanguage
        )
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))
        editor.bindProfile(id: "profile-1")
        editor.seed(from: nil)

        editor.subtitleLanguage = "ja"
        let firstSave = Task { @MainActor in await editor.saveSubtitlePrefs() }
        await transport.writeGate.waitUntilEntered(.string("ja"))

        editor.bindProfile(id: "profile-2")
        editor.subtitleLanguage = "ko"
        await editor.saveSubtitlePrefs()
        transport.setWriteFailure(nil, for: .playbackSubtitleLanguage)
        await transport.writeGate.release(.string("ja"))
        await firstSave.value

        let writes = transport.writes().filter { $0.key == .playbackSubtitleLanguage }
        XCTAssertEqual(writes.map(\.value), [.string("ja"), .string("ja"), .string("ko")])
        XCTAssertEqual(writes.map(\.profileId), ["profile-1", "profile-1", "profile-2"])
        XCTAssertEqual(
            writes[0].mutationId,
            writes[1].mutationId,
            "the previous profile's ambiguous write must retry with its original identity"
        )
    }

    func testQueuedMetadataEditsKeepTheProfileThatOwnedEachEdit() async throws {
        let transport = FakeProfileSettingsTransport()
        await transport.writeGate.block(.string("ja"))
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))
        editor.bindProfile(id: "profile-1")
        editor.seed(from: nil)

        editor.preferredMetadataLanguage = "ja"
        let firstSave = Task { @MainActor in await editor.saveMetadataLanguage() }
        await transport.writeGate.waitUntilEntered(.string("ja"))

        editor.bindProfile(id: "profile-2")
        editor.preferredMetadataLanguage = "ko"
        await editor.saveMetadataLanguage()
        await transport.writeGate.release(.string("ja"))
        await firstSave.value

        let writes = transport.writes().filter { $0.key == .catalogMetadataLanguage }
        XCTAssertEqual(writes.map(\.value), [.string("ja"), .string("ko")])
        XCTAssertEqual(writes.map(\.profileId), ["profile-1", "profile-2"])
    }

    func testProfileSwitchSettlesMetadataSaveStateWithoutAReplacementWrite() async throws {
        let outcomes: [SettingsAPIError?] = [
            nil,
            .transport(description: "response lost"),
        ]

        for outcome in outcomes {
            let transport = FakeProfileSettingsTransport()
            await transport.writeGate.block(.string("ja"))
            transport.failWritesWith = outcome
            let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))
            editor.bindProfile(id: "profile-1")
            editor.seed(from: nil)

            editor.preferredMetadataLanguage = "ja"
            let save = Task { @MainActor in await editor.saveMetadataLanguage() }
            await transport.writeGate.waitUntilEntered(.string("ja"))

            editor.bindProfile(id: "profile-2")
            await transport.writeGate.release(.string("ja"))
            await save.value

            XCTAssertNil(
                editor.saveState,
                "a stale completion must not leave the newly bound profile showing Saving"
            )
        }
    }

    // MARK: - Scope promotion

    /// A value the effective read resolved from a *narrower* scope must not be
    /// written back at `profile` scope on screen open.
    ///
    /// All three subtitle keys list `profile_device` in `allowed_scopes`, and
    /// the web admin's per-device settings pane writes them there. This editor
    /// only ever writes at `profile`, so repainting the resolved value into the
    /// fields makes `onChange` fire and promotes one device's override to the
    /// whole household — with the user having touched nothing.
    func testOpeningTheScreenDoesNotPromoteADeviceOverrideToTheProfile() async throws {
        let transport = FakeProfileSettingsTransport()
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))

        // The profile's own language is "ja"; this device has a profile_device
        // row of "en", which is what the effective endpoint resolves.
        editor.seed(from: nil)
        transport.effective = [
            .init(
                key: SettingKey.playbackSubtitleLanguage.rawValue,
                value: .string("en"),
                source: .scope(.profileDevice),
                scope: .profileDevice
            ),
            .init(
                key: SettingKey.playbackSubtitleMode.rawValue,
                value: .string(SubtitleMode.always.rawValue),
                source: .scope(.profileDevice),
                scope: .profileDevice
            ),
            .init(
                key: SettingKey.playbackShowForcedSubtitles.rawValue,
                value: .bool(false),
                source: .scope(.profileDevice),
                scope: .profileDevice
            ),
        ]
        await editor.load()
        XCTAssertEqual(editor.subtitleLanguage, "en", "precondition: the resolved value is painted")

        // Exactly what the screens do on every field the repaint moved.
        await editor.saveSubtitlePrefs()

        XCTAssertTrue(
            transport.writes().isEmpty,
            "a repaint is not a user edit: writing it back would promote the device row to the profile"
        )
    }

    /// The suppression is per key and per value, not a blanket "never write
    /// after a load": a control the user actually touches still saves.
    func testAnEditAfterALoadStillSaves() async throws {
        let transport = FakeProfileSettingsTransport()
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))

        transport.effective = [
            .init(
                key: SettingKey.playbackSubtitleLanguage.rawValue,
                value: .string("en"),
                source: .scope(.profileDevice),
                scope: .profileDevice
            ),
        ]
        await editor.load()

        editor.subtitleLanguage = "ja"
        await editor.saveSubtitlePrefs()

        let byKey = transport.writesByKey()
        XCTAssertEqual(byKey[.playbackSubtitleLanguage]?.value, .string("ja"))
        // And only that key: the two the user did not touch stay where the
        // server resolved them.
        XCTAssertNil(byKey[.playbackSubtitleMode], "an untouched control must not be written")
        XCTAssertNil(byKey[.playbackShowForcedSubtitles], "an untouched control must not be written")
        XCTAssertEqual(editor.saveState, .saved)
    }

    /// A write that failed is still owed, so the next save must retry it rather
    /// than treat the field as already persisted.
    func testAFailedWriteIsRetriedByTheNextSave() async throws {
        let transport = FakeProfileSettingsTransport()
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))

        editor.seed(from: nil)
        editor.subtitleLanguage = "ko"
        transport.failWritesWith = .server(status: 503, code: nil, message: nil)
        await editor.saveSubtitlePrefs()
        XCTAssertEqual(transport.writes().filter { $0.key == .playbackSubtitleLanguage }.count, 1)

        transport.failWritesWith = nil
        await editor.saveSubtitlePrefs()

        let languageWrites = transport.writes().filter { $0.key == .playbackSubtitleLanguage }
        XCTAssertEqual(languageWrites.count, 2,
                       "a failed write must stay owed rather than being marked persisted")
        XCTAssertEqual(languageWrites.last?.value, .string("ko"))
    }

    func testOverlappingEditsToOneProfileKeyLandNewestLast() async throws {
        let transport = FakeProfileSettingsTransport()
        transport.writeDelays[.string("ja")] = .milliseconds(100)
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))

        editor.subtitleLanguage = "ja"
        let firstSave = Task { @MainActor in await editor.saveSubtitlePrefs() }
        try await waitUntil("the first language write to start") {
            transport.writes().count == 1
        }

        editor.subtitleLanguage = "ko"
        await editor.saveSubtitlePrefs()
        await firstSave.value

        let completedLanguages = transport.completedWrites()
            .filter { $0.key == .playbackSubtitleLanguage }
            .map(\.value)
        XCTAssertEqual(
            completedLanguages,
            [.string("ja"), .string("ko")],
            "same-key saves must serialize so an older slow PUT cannot overwrite the newer choice"
        )
        XCTAssertEqual(editor.subtitleLanguage, "ko")
        XCTAssertEqual(editor.saveState, .saved)
    }

    func testSubtitleRevertIsSentAfterTheSupersededWriteFailsAmbiguously() async throws {
        let transport = FakeProfileSettingsTransport()
        await transport.writeGate.block(.string("ja"))
        transport.setWriteFailure(
            .transport(description: "response lost"),
            for: .playbackSubtitleLanguage
        )
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))
        editor.seed(from: nil)

        editor.subtitleLanguage = "ja"
        let firstSave = Task { @MainActor in await editor.saveSubtitlePrefs() }
        try await waitUntil("the first subtitle-language write to start") {
            transport.writes().count == 1
        }

        // The first request may have reached the server even though its
        // response was lost. Reverting to the saved baseline still owes an
        // explicit compensating write.
        transport.setWriteFailure(nil, for: .playbackSubtitleLanguage)
        editor.subtitleLanguage = PlaybackPrefSentinel.none
        await editor.saveSubtitlePrefs()
        await transport.writeGate.release(.string("ja"))
        await firstSave.value

        let values = transport.writes()
            .filter { $0.key == .playbackSubtitleLanguage }
            .map(\.value)
        XCTAssertEqual(
            values,
            [.string("ja"), .null],
            "an ambiguous failure must not let the saved baseline suppress the queued revert"
        )
        XCTAssertEqual(editor.subtitleLanguage, PlaybackPrefSentinel.none)
        XCTAssertEqual(editor.saveState, .saved)
    }

    func testSuccessfulLanguageWriteUpdatesThePreferenceStoreWhenASiblingFails() async throws {
        let transport = FakeProfileSettingsTransport()
        transport.failWritesByKey[.playbackSubtitleMode] = .server(
            status: 503,
            code: "unavailable",
            message: nil
        )
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))
        ProfilePrefsStore.shared.clear()
        defer { ProfilePrefsStore.shared.clear() }

        editor.subtitleLanguage = "ja"
        editor.subtitleMode = SubtitleMode.always.rawValue
        await editor.saveSubtitlePrefs()

        XCTAssertEqual(
            ProfilePrefsStore.shared.preferredSubtitleLanguage,
            "ja",
            "a landed language row must update local ordering even when another row in the batch fails"
        )
        guard case .failed = editor.saveState else {
            return XCTFail("the sibling failure must still be reported")
        }
    }

    func testAProfileWriteReResolvesWhenADeviceOverrideStillWins() async throws {
        let transport = FakeProfileSettingsTransport()
        transport.effective = [
            .init(
                key: SettingKey.playbackSubtitleLanguage.rawValue,
                value: .string("en"),
                source: .scope(.profileDevice),
                scope: .profileDevice
            ),
        ]
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))
        await editor.load()

        editor.subtitleLanguage = "ja"
        await editor.saveSubtitlePrefs()

        XCTAssertEqual(
            transport.effectiveCalls().count,
            2,
            "a successful profile write must refresh an effective value known to be shadowed"
        )
        XCTAssertEqual(
            editor.subtitleLanguage,
            "en",
            "the editor must show the still-winning device override, not the ineffective optimistic profile value"
        )
        XCTAssertTrue(
            editor.subtitleProfileOverrideMessage?.contains("This device, for this profile") == true,
            "the UI needs a visible explanation for why the saved profile value did not become effective"
        )
    }

    func testEditDuringShadowRefreshStillSavesNewestValue() async throws {
        let transport = FakeProfileSettingsTransport()
        transport.effective = [
            .init(
                key: SettingKey.playbackSubtitleLanguage.rawValue,
                value: .string("en"),
                source: .scope(.profileDevice),
                scope: .profileDevice
            ),
        ]
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))
        await editor.load()
        transport.effectiveDelay = .milliseconds(100)

        editor.subtitleLanguage = "ja"
        let firstSave = Task { @MainActor in await editor.saveSubtitlePrefs() }
        for _ in 0..<100 {
            if transport.effectiveCalls().count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(transport.effectiveCalls().count, 2, "the post-write resolution read must start")

        editor.subtitleLanguage = "ko"
        await editor.saveSubtitlePrefs()
        await firstSave.value

        let languages = transport.writes()
            .filter { $0.key == .playbackSubtitleLanguage }
            .map(\.value)
        XCTAssertEqual(
            languages,
            [.string("ja"), .string("ko")],
            "an edit queued while the shadow-resolution read is suspended must get its own serialized write"
        )
        XCTAssertEqual(
            editor.subtitleLanguage,
            "en",
            "the device override remains the displayed effective value after the profile write lands"
        )
        XCTAssertEqual(editor.saveState, .saved)
    }

    func testMetadataEditRevertedDuringWriteStillLandsNewestValue() async throws {
        let transport = FakeProfileSettingsTransport()
        transport.writeDelays[.string("ja")] = .milliseconds(100)
        let editor = ProfilePrefsEditor(writer: ProfileSettingsWriter(transport: transport))
        editor.seed(from: nil)

        editor.preferredMetadataLanguage = "ja"
        let firstSave = Task { @MainActor in await editor.saveMetadataLanguage() }
        try await waitUntil("the first metadata-language write to start") {
            transport.writes().count == 1
        }

        editor.preferredMetadataLanguage = PlaybackPrefSentinel.none
        await editor.saveMetadataLanguage()
        await firstSave.value

        let values = transport.writes()
            .filter { $0.key == .catalogMetadataLanguage }
            .map(\.value)
        XCTAssertEqual(
            values,
            [.string("ja"), .null],
            "reverting to the baseline while an older PUT is suspended must enqueue the revert"
        )
        XCTAssertEqual(editor.preferredMetadataLanguage, PlaybackPrefSentinel.none)
        XCTAssertEqual(editor.saveState, .saved)
    }

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(5),
        _ condition: @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
    }
}

// MARK: - Fakes

/// A ``ProfileSettingsTransport`` that records what it was asked to do and can
/// be told to fail the way the real API fails.
final class FakeProfileSettingsTransport: ProfileSettingsTransport, @unchecked Sendable {
    struct Write: Equatable {
        let key: SettingKey
        let value: SettingJSONValue
        let mutationId: String
        let profileId: String?
    }

    var effective: [EffectiveSettingValue] = []
    var failReadsWith: SettingsAPIError?
    var failWritesWith: SettingsAPIError?
    var failWritesByKey: [SettingKey: SettingsAPIError] = [:]
    var writeDelays: [SettingJSONValue: Duration] = [:]
    var effectiveDelay: Duration?
    let writeGate = ProfileSettingsWriteGate()

    private let lock = NSLock()
    private var recordedWrites: [Write] = []
    private var recordedCompletions: [Write] = []
    private var recordedEffectiveCalls: [[SettingKey]] = []

    func writes() -> [Write] {
        lock.lock()
        defer { lock.unlock() }
        return recordedWrites
    }

    /// The last write per key, which is what a caller asserting "what did this
    /// setter send" wants.
    func writesByKey() -> [SettingKey: Write] {
        var byKey: [SettingKey: Write] = [:]
        for write in writes() {
            byKey[write.key] = write
        }
        return byKey
    }

    func effectiveCalls() -> [[SettingKey]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEffectiveCalls
    }

    func completedWrites() -> [Write] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCompletions
    }

    func setWriteFailure(_ error: SettingsAPIError?, for key: SettingKey) {
        lock.lock()
        failWritesByKey[key] = error
        lock.unlock()
    }

    // MARK: ProfileSettingsTransport

    func effectiveValues(keys: [SettingKey]) async throws -> EffectiveSettingValuesResponse {
        lock.lock()
        recordedEffectiveCalls.append(keys)
        let settings = effective
        let failure = failReadsWith
        let delay = effectiveDelay
        lock.unlock()
        if let delay { try? await Task.sleep(for: delay) }
        if let failure { throw failure }
        return EffectiveSettingValuesResponse(settings: settings, revision: SettingKey.revision)
    }

    func putValue(
        key: SettingKey,
        value: SettingJSONValue,
        mutationId: String,
        profileId: String?
    ) async throws {
        lock.lock()
        let write = Write(
            key: key,
            value: value,
            mutationId: mutationId,
            profileId: profileId
        )
        recordedWrites.append(write)
        let failure = failWritesByKey[key] ?? failWritesWith
        let delay = writeDelays[value]
        lock.unlock()
        await writeGate.waitIfBlocked(value)
        if let delay { try? await Task.sleep(for: delay) }
        if let failure { throw failure }
        lock.lock()
        recordedCompletions.append(write)
        lock.unlock()
    }
}

actor ProfileSettingsWriteGate {
    private var blockedValues: Set<SettingJSONValue> = []
    private var waiters: [SettingJSONValue: [CheckedContinuation<Void, Never>]] = [:]
    private var enteredValues: Set<SettingJSONValue> = []
    private var entryWaiters: [SettingJSONValue: [CheckedContinuation<Void, Never>]] = [:]

    func block(_ value: SettingJSONValue) {
        blockedValues.insert(value)
    }

    func waitIfBlocked(_ value: SettingJSONValue) async {
        enteredValues.insert(value)
        let observers = entryWaiters.removeValue(forKey: value) ?? []
        for observer in observers {
            observer.resume()
        }
        guard blockedValues.contains(value) else { return }
        await withCheckedContinuation { continuation in
            waiters[value, default: []].append(continuation)
        }
    }

    func waitUntilEntered(_ value: SettingJSONValue) async {
        guard !enteredValues.contains(value) else { return }
        await withCheckedContinuation { continuation in
            entryWaiters[value, default: []].append(continuation)
        }
    }

    func release(_ value: SettingJSONValue) {
        blockedValues.remove(value)
        let resumptions = waiters.removeValue(forKey: value) ?? []
        for continuation in resumptions {
            continuation.resume()
        }
    }
}
