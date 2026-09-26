import XCTest
@testable import Silo

/// Contract tests for the canonical settings API client.
///
/// The three things that can silently break it: the heterogeneous value
/// representation losing a type on the way through, a key-coding strategy
/// reaching a field or an object key it must not touch, and a server too old
/// to serve the routes at all being reported as a generic failure.
final class SettingValuesAPITests: XCTestCase {

    /// XCTest creates one instance per test method, so every test gets its
    /// own routes and request records.
    private let stub = StubURLProtocol.Handler()

    override func tearDown() {
        XCTAssertEqual(
            stub.unmatched.map { "\($0.method) \($0.path)" },
            [],
            "every request a test sends must hit an explicit route"
        )
        super.tearDown()
    }

    // MARK: - Value round-trips

    func testEveryValueShapeRoundTripsThroughSettingJSONValue() throws {
        // One document covering every JSON shape a contract value can take,
        // including the object-valued settings whose keys must survive.
        let wire = Data("""
        {
          "aBool": true,
          "anInt": 8000,
          "aDouble": 1.25,
          "aString": "2160p",
          "aNull": null,
          "anArray": [1, "two", false, null, {"nested": 3}],
          "anObject": {"fontSize": "large", "backgroundOpacity": 75, "textOutline": false}
        }
        """.utf8)

        let decoded = try SettingsWireCoding.makeDecoder().decode(SettingJSONValue.self, from: wire)
        guard let object = decoded.objectValue else {
            return XCTFail("top level must decode as an object")
        }

        XCTAssertEqual(object["aBool"], .bool(true))
        XCTAssertEqual(object["anInt"], .int(8000))
        XCTAssertEqual(object["aDouble"], .double(1.25))
        XCTAssertEqual(object["aString"], .string("2160p"))
        XCTAssertEqual(object["aNull"], .null)
        XCTAssertEqual(object["anArray"]?.arrayValue?.count, 5)
        XCTAssertEqual(object["anObject"]?.objectValue?["fontSize"], .string("large"))

        // Re-encode, decode again: the value must be identical, which is what
        // proves nothing was coerced on the way through.
        let reEncoded = try SettingsWireCoding.makeEncoder().encode(decoded)
        let reDecoded = try SettingsWireCoding.makeDecoder().decode(SettingJSONValue.self, from: reEncoded)
        XCTAssertEqual(decoded, reDecoded)
    }

    func testIntegerValuesDoNotBecomeDoublesOnTheWire() throws {
        // playback.max_bitrate_kbps is an int in the contract. Encoding it as
        // 8000.0 would fail the server's schema normalization.
        let encoded = try SettingsWireCoding.makeEncoder().encode(SettingJSONValue.int(8000))
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "8000")

        let decoded = try SettingsWireCoding.makeDecoder().decode(SettingJSONValue.self, from: encoded)
        XCTAssertEqual(decoded, .int(8000))
        XCTAssertEqual(decoded.intValue, 8000)
    }

    func testSemanticEqualityTreatsNumericSpellingsAsTheSameJSONValue() throws {
        XCTAssertTrue(SettingJSONValue.double(1.0).isSemanticallyEquivalent(to: .int(1)))
        XCTAssertTrue(
            SettingJSONValue.object([
                "values": .array([.double(1.0), .object(["cap": .int(8_000)])]),
            ]).isSemanticallyEquivalent(
                to: .object([
                    "values": .array([.int(1), .object(["cap": .double(8_000.0)])]),
                ])
            )
        )
    }

    func testSemanticEqualityDoesNotCoerceBooleansToNumbers() throws {
        XCTAssertFalse(SettingJSONValue.bool(true).isSemanticallyEquivalent(to: .int(1)))
        XCTAssertFalse(SettingJSONValue.bool(false).isSemanticallyEquivalent(to: .int(0)))
    }

    func testNullValueIsDistinctFromAbsentValue() throws {
        // Several ui.* settings are nullable objects, so JSON null is a real
        // value and must not collapse into "nothing stored".
        let encoded = try SettingsWireCoding.makeEncoder().encode(SettingJSONValue.null)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "null")
        XCTAssertTrue(try SettingsWireCoding.makeDecoder()
            .decode(SettingJSONValue.self, from: encoded).isNull)
    }

    func testWriteRequestWrapsTheValueUnderValue() throws {
        let body = try SettingsWireCoding.makeEncoder()
            .encode(SettingValueWriteRequest(value: .string("2160p")))
        XCTAssertEqual(String(data: body, encoding: .utf8), #"{"value":"2160p"}"#)
    }

    // MARK: - The snake_case boundary

    func testObjectValuedSettingKeepsItsCamelCaseKeysInBothDirections() throws {
        // playback.subtitle_appearance is camelCase on the wire (the contract's
        // subtitle-appearance.json schema names fontSize, backgroundOpacity, …),
        // and a value whose keys get rewritten is corrupted silently and
        // permanently in the user's stored settings.
        let appearance = Data("""
        {"key":"playback.subtitle_appearance","scope":"profile_device",
         "profile_id":"p1","device_id":"d1",
         "value":{"fontSize":"large","backgroundOpacity":75,"textOutline":false},
         "revision":4,"updated_at":"2026-07-01T00:00:00Z"}
        """.utf8)

        let stored = try SettingsWireCoding.makeDecoder().decode(StoredSettingValue.self, from: appearance)
        XCTAssertEqual(stored.value.objectValue?["fontSize"], .string("large"))
        XCTAssertEqual(stored.value.objectValue?["backgroundOpacity"], .int(75))
        XCTAssertNil(stored.value.objectValue?["font_size"], "value keys must not be snake_cased")

        let body = try SettingsWireCoding.makeEncoder()
            .encode(SettingValueWriteRequest(value: stored.value))
        let json = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"fontSize\""), "outgoing value keys must stay camelCase: \(json)")
        XCTAssertFalse(json.contains("font_size"), "outgoing value keys must not be snake_cased: \(json)")
    }

    func testTheseModelsMustNotBeDecodedWithTheSharedCoder() throws {
        // The hazard, pinned. These models carry explicit snake_case
        // CodingKeys, and .convertFromSnakeCase camel-cases the *incoming* key
        // before matching it — so "profile_id" arrives as "profileId", finds no
        // CodingKey named "profileId", and the field silently decodes as nil.
        // Nothing throws. A caller who routes one of these through
        // `http.get(...)` instead of the settings client gets a value whose
        // scope identity has quietly evaporated, which would make a reset
        // target the wrong row.
        //
        // This is exactly the trap HTTPClient's own doc comment warns about
        // ("only add explicit CodingKeys when the wire name is NOT a clean
        // snake_case of the property"). These models have to break that rule to
        // keep the strategy away from setting values, so the compensating
        // control is that they are only ever coded through SettingsWireCoding —
        // and this test fails loudly if someone assumes otherwise.
        let payload = Data("""
        {"key":"playback.subtitle_appearance","scope":"profile_device",
         "profile_id":"p1","device_id":"d1",
         "value":{"fontSize":"large","backgroundOpacity":75},
         "revision":4,"updated_at":"2026-07-01T00:00:00Z"}
        """.utf8)

        let correct = try SettingsWireCoding.makeDecoder()
            .decode(StoredSettingValue.self, from: payload)
        XCTAssertEqual(correct.profileId, "p1")
        XCTAssertEqual(correct.deviceId, "d1")
        XCTAssertEqual(correct.updatedAt, "2026-07-01T00:00:00Z")

        let viaSharedCoder = try HTTPClient.makeJSONDecoder()
            .decode(StoredSettingValue.self, from: payload)
        XCTAssertNil(viaSharedCoder.profileId, "the shared coder drops snake_case fields silently")
        XCTAssertNotEqual(correct, viaSharedCoder)

        // The value itself survives either way — no strategy reaches into a
        // [String: …] payload — which is why the damage is confined to the
        // envelope and is easy to miss.
        XCTAssertEqual(viaSharedCoder.value, correct.value)
        XCTAssertEqual(viaSharedCoder.value.objectValue?["fontSize"], .string("large"))
    }

    func testValueObjectKeysSurviveTheEncoderVerbatim() throws {
        // Both halves of an object value must come back byte-identical: a key
        // that is already camelCase (subtitle appearance) and one that
        // contains an underscore (a schema that uses snake_case). Neither may
        // be rewritten in either direction.
        let mixed: SettingJSONValue = ["fontSize": "large", "background_opacity": 75]
        let encoded = try SettingsWireCoding.makeEncoder().encode(mixed)
        let json = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"fontSize\""), json)
        XCTAssertTrue(json.contains("\"background_opacity\""), json)

        let decoded = try SettingsWireCoding.makeDecoder().decode(SettingJSONValue.self, from: encoded)
        XCTAssertEqual(decoded, mixed)
    }

    func testGeneratedBindingsStayCamelCaseUnderTheSharedDecoder() throws {
        // The generated SettingKey table is a plain String enum with no
        // CodingKeys, and nothing in this change may alter that: it is keyed
        // by contract key, so it never meets a coding strategy at all.
        XCTAssertEqual(SettingKey.playbackSubtitleAppearance.rawValue, "playback.subtitle_appearance")
        XCTAssertEqual(SettingKey(rawValue: "ui.card_overlays"), .uiCardOverlays)
        XCTAssertTrue(SettingKey.remote.contains(.playbackPreferredQuality))
        XCTAssertTrue(SettingKey.clientLocal.contains(.downloadsWifiOnly))
    }

    func testEnvelopeFieldsDecodeFromSnakeCaseWithoutAStrategy() throws {
        // The envelope around a value is snake_case, and the strategy-free
        // decoder can only read it because every model spells the wire names
        // out in CodingKeys.
        let stored = try SettingsWireCoding.makeDecoder().decode(StoredSettingValue.self, from: Data("""
        {"key":"playback.subtitle_language","scope":"profile_series","profile_id":"p1",
         "series_id":"s-101","value":"ja","revision":7,"updated_at":"2026-07-01T12:00:00Z"}
        """.utf8))

        XCTAssertEqual(stored.settingKey, .playbackSubtitleLanguage)
        XCTAssertEqual(stored.scope, .profileSeries)
        XCTAssertEqual(stored.profileId, "p1")
        XCTAssertEqual(stored.seriesId, "s-101")
        XCTAssertEqual(stored.value, .string("ja"))
        XCTAssertEqual(stored.revision, 7)
        XCTAssertEqual(stored.updatedAt, "2026-07-01T12:00:00Z")
    }

    // MARK: - Effective resolution

    func testEffectiveResponseDecodesSourceScopeAndRevision() throws {
        let response = try SettingsWireCoding.makeDecoder()
            .decode(EffectiveSettingValuesResponse.self, from: Data("""
            {"items":[
              {"key":"playback.subtitle_language","value":"ja","source":"profile_series",
               "scope":"profile_series","profile_id":"p1","series_id":"s-101",
               "suggested_values":["en","ja","pt-BR"],"definition_revision":3,
               "updated_at":"2026-01-02T03:04:05.678Z",
               "source_context":{"profile_id":"p1","series_id":"s-101"}},
              {"key":"playback.auto_play_next","value":true,"source":"default","definition_revision":3}
            ],"revision":1}
            """.utf8))

        XCTAssertEqual(response.revision, 1)
        let series = try XCTUnwrap(response.value(for: .playbackSubtitleLanguage))
        XCTAssertEqual(series.source, .scope(.profileSeries))
        XCTAssertEqual(series.value, .string("ja"))
        XCTAssertEqual(series.storedAt, .profileSeries(seriesId: "s-101"))
        XCTAssertEqual(series.suggestedValues, ["en", "ja", "pt-BR"])

        let fromDefault = try XCTUnwrap(response.value(for: .playbackAutoPlayNext))
        XCTAssertEqual(fromDefault.source, .contractDefault)
        XCTAssertEqual(fromDefault.value, .bool(true))
        XCTAssertNil(fromDefault.storedAt, "a contract default has no row to reset")
        XCTAssertFalse(fromDefault.constrained)
        XCTAssertNil(fromDefault.storedValue)
    }

    func testEffectiveLibraryIdArrivesAsAStringAndStillAddressesTheRow() throws {
        let decoder = SettingsWireCoding.makeDecoder()
        let library = try decoder.decode(EffectiveSettingValue.self, from: Data("""
            {"key":"playback.preferred_quality","value":"auto","source":"profile_library",
             "scope":"profile_library","profile_id":"p1","library_id":"7","definition_revision":3}
            """.utf8))
        XCTAssertEqual(library.libraryId, 7)
        XCTAssertEqual(library.storedAt, .profileLibrary(libraryId: 7))

        // An opaque id this build cannot address degrades to "no reset
        // target" for that row instead of failing the whole batch.
        let opaque = try decoder.decode(EffectiveSettingValue.self, from: Data("""
            {"key":"playback.preferred_quality","value":"auto","source":"profile_library",
             "scope":"profile_library","profile_id":"p1","library_id":"lib-a","definition_revision":3}
            """.utf8))
        XCTAssertNil(opaque.libraryId)
        XCTAssertNil(opaque.storedAt)
    }

    func testProfileClientEnvelopeKeepsTheResolvedFamily() throws {
        let effective = try SettingsWireCoding.makeDecoder()
            .decode(EffectiveSettingValue.self, from: Data("""
            {"key":"ui.card_presentation",
             "value":{"poster_size":"large","caption":"artwork"},
             "source":"profile_client","scope":"profile_client",
             "profile_id":"p1","client_family":"tv"}
            """.utf8))

        XCTAssertEqual(effective.source, .scope(.profileClient))
        XCTAssertEqual(effective.scope, .profileClient)
        XCTAssertEqual(effective.clientFamily, "tv")
        XCTAssertEqual(effective.storedAt, .profileClient)
    }

    func testConstrainedValueKeepsTheAuthoredChoice() throws {
        // Mirrors a conformance case: policy caps a 4K preference at 1080p,
        // and the authored value is reported so the UI can say "capped" rather
        // than showing the cap as the user's choice.
        let effective = try SettingsWireCoding.makeDecoder()
            .decode(EffectiveSettingValue.self, from: Data("""
            {"key":"playback.preferred_quality","value":"1080p","source":"profile",
             "scope":"profile","profile_id":"p1","stored_value":"2160p",
             "constrained":true,"constraint_kind":"ceiling"}
            """.utf8))

        XCTAssertEqual(effective.value, .string("1080p"))
        XCTAssertEqual(effective.storedValue, .string("2160p"))
        XCTAssertTrue(effective.constrained)
        XCTAssertEqual(effective.constraintKind, .ceiling)
        XCTAssertEqual(effective.storedAt, .profile)
    }

    func testConstrainedWithNullStoredValueMeansNothingWasAuthored() throws {
        // The fixture's own note: stored_value may be null, and that is
        // distinct from the field being absent. decodeIfPresent would collapse
        // the two, so the model decodes it through an explicit contains check.
        let authoredNull = try SettingsWireCoding.makeDecoder()
            .decode(EffectiveSettingValue.self, from: Data("""
            {"key":"playback.max_bitrate_kbps","value":8000,"source":"default",
             "stored_value":null,"constrained":true,"constraint_kind":"ceiling"}
            """.utf8))
        XCTAssertEqual(authoredNull.storedValue, SettingJSONValue.null)
        XCTAssertNotNil(authoredNull.storedValue)

        let absent = try SettingsWireCoding.makeDecoder()
            .decode(EffectiveSettingValue.self, from: Data("""
            {"key":"playback.max_bitrate_kbps","value":8000,"source":"default"}
            """.utf8))
        XCTAssertNil(absent.storedValue)
    }

    func testUnknownKeyFromANewerServerDoesNotFailTheBatch() throws {
        // The settings API is additive: a newer server may resolve keys and scopes this
        // build has never heard of, and one unfamiliar row must not take the
        // whole settings screen down with it.
        let response = try SettingsWireCoding.makeDecoder()
            .decode(EffectiveSettingValuesResponse.self, from: Data("""
            {"items":[
              {"key":"playback.auto_play_next","value":false,"source":"profile","scope":"profile"},
              {"key":"future.setting_from_a_newer_server","value":1,"source":"profile_household",
               "scope":"profile_household"}
            ],"revision":9}
            """.utf8))

        XCTAssertEqual(response.settings.count, 2)
        XCTAssertEqual(response.byKey.count, 1, "unknown keys drop out of the typed map")
        XCTAssertEqual(response.settings[1].scope, .other("profile_household"))
        XCTAssertNil(response.settings[1].storedAt, "an unknown scope has no identity to reset")
    }

    // MARK: - Scope identities

    func testScopeIdentitiesCarryTheirIdsInTheQuery() {
        XCTAssertEqual(SettingScopeIdentity.account.queryItems, ["scope": "account"])
        XCTAssertEqual(SettingScopeIdentity.profile.queryItems, ["scope": "profile"])
        XCTAssertEqual(SettingScopeIdentity.profileClient.queryItems, ["scope": "profile_client"])
        // The device half comes from the X-Silo-Device-Id header the client
        // already attaches, never the query — sending it twice is the bug.
        XCTAssertEqual(SettingScopeIdentity.profileDevice.queryItems, ["scope": "profile_device"])
        XCTAssertEqual(
            SettingScopeIdentity.profileLibrary(libraryId: 7).queryItems,
            ["scope": "profile_library", "library_id": "7"]
        )
        XCTAssertEqual(
            SettingScopeIdentity.profileSeries(seriesId: "s-101").queryItems,
            ["scope": "profile_series", "series_id": "s-101"]
        )
    }

    func testCapabilitiesKeepTheOpaqueRevisionApartFromTheManifestRevision() throws {
        // The server's published get_settings_contract_capabilities_ok fixture
        // at 84ed9e596.
        let capabilities = try HTTPClient.makeJSONDecoder()
            .decode(APIv2SettingsContractCapabilities.self, from: Data("""
            {"revision":"36e767e32d6613323df470594b9c91068ed062132912c3af462965668b2d31a4",
             "state":"available","allowed":true,"api_version":1,"manifest_revision":12,
             "contract_etag":"\\"etag-12\\"","definition_count":40,"scopes":["account","profile"],
             "client_families":["tv","web"],"supports_batched_effective":true,
             "supports_idempotent_writes":true,"supports_atomic_shortcuts":true}
            """.utf8))

        XCTAssertEqual(capabilities.revision, "36e767e32d6613323df470594b9c91068ed062132912c3af462965668b2d31a4")
        XCTAssertEqual(capabilities.manifestRevision, 12)
        XCTAssertTrue(capabilities.isAvailable)
        XCTAssertFalse(capabilities.predatesMinimumRevision, "manifest 12 is not below revision \(SettingKey.minimumServerRevision)")
        XCTAssertTrue(capabilities.supports(.playerVideoSkipBackSeconds))
        XCTAssertTrue(capabilities.supportsUICustomization(clientFamily: "tv"))
        XCTAssertFalse(
            capabilities.supportsUICustomization(clientFamily: "mobile"),
            "card presentation is stored at profile_client, which must accept this family"
        )
    }

    func testNotConfiguredCapabilitiesDecodeAsUnavailable() throws {
        // What the server sends when it has no settings contract wired.
        let capabilities = try HTTPClient.makeJSONDecoder()
            .decode(APIv2SettingsContractCapabilities.self, from: Data("""
            {"revision":"abc","state":"not_configured","allowed":false,"api_version":0,
             "manifest_revision":0,"contract_etag":"","definition_count":0,"scopes":[],
             "client_families":[],"supports_batched_effective":false,
             "supports_idempotent_writes":false,"supports_atomic_shortcuts":false}
            """.utf8))

        XCTAssertFalse(capabilities.isAvailable)
        XCTAssertFalse(capabilities.supportsUICustomization(clientFamily: "tv"))
        XCTAssertFalse(capabilities.supports(.playbackSubtitleLanguage))
    }

    // MARK: - Requests over the wire

    func testGetContractCapabilitiesReportsUpgradeRequiredOnAV1OnlyServer() async throws {
        // The chi router's own 404: plain text, no Silo error envelope.
        stub.route(StubURLProtocol.any) { _ in .text("404 page not found\n", status: 404) }
        let api = await makeStubbedAPI()

        let result = await api.getContractCapabilities()
        XCTAssertEqual(result, .serverUpgradeRequired)
        XCTAssertNil(result.capabilities)
        XCTAssertEqual(stub.requests.last?.path, "/api/v2/settings/contract/capabilities")
    }

    func testGetContractCapabilitiesReturnsCapabilitiesOnACurrentServer() async throws {
        routeSettingsServer()
        let api = await makeStubbedAPI()

        guard case .available(let capabilities) = await api.getContractCapabilities() else {
            return XCTFail("a current server must report capabilities")
        }
        XCTAssertEqual(capabilities.manifestRevision, SettingKey.revision)
        XCTAssertTrue(capabilities.supportsAtomicShortcuts)
        let recorded = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(recorded.method, "GET")
        XCTAssertEqual(recorded.path, "/api/v2/settings/contract/capabilities")
    }

    func testGetContractCapabilitiesRequiresTheMinimumServerRevision() async throws {
        routeSettingsServer(manifestRevision: SettingKey.minimumServerRevision - 1)
        let api = await makeStubbedAPI()

        let result = await api.getContractCapabilities()
        XCTAssertEqual(result, .serverUpgradeRequired)
    }

    /// A binding refresh must not turn every settings feature off on a server
    /// one revision behind: only the keys that revision lacks are gated.
    func testCapabilitiesFromThePreviousRevisionGateOnlyTheKeysItLacks() async throws {
        routeSettingsServer(manifestRevision: SettingKey.revision - 1)
        let api = await makeStubbedAPI()

        guard case .available(let capabilities) = await api.getContractCapabilities() else {
            return XCTFail("a server one revision behind must still report capabilities")
        }
        XCTAssertEqual(capabilities.manifestRevision, SettingKey.revision - 1)
        XCTAssertTrue(capabilities.supports(.playbackSubtitleLanguage))
        XCTAssertTrue(capabilities.supports(.playbackIntroSkipMode))
        for key in SettingKey.allCases where key.introducedIn == SettingKey.revision {
            XCTAssertFalse(capabilities.supports(key), "\(key.rawValue) is newer than the server")
        }
    }

    func testGetContractCapabilitiesGatesOnStateAndAllowed() async throws {
        let api = await makeStubbedAPI()
        let cases: [(state: String, allowed: Bool, expected: SettingsCapabilitiesResult)] = [
            ("not_configured", false, .unavailable),
            ("disabled", false, .unavailable),
            ("available", false, .unavailable),
            ("a_future_state", false, .unavailable),
            ("unsupported", false, .serverUpgradeRequired),
        ]
        for (state, allowed, expected) in cases {
            stub.reset()
            stub.route(StubURLProtocol.method("GET", path: SettingsWire.capabilities)) { _ in
                .json(SettingsWire.capabilitiesBody(state: state, allowed: allowed))
            }
            routeSettingsServer()
            let result = await api.getContractCapabilities()
            XCTAssertEqual(result, expected, "state \(state), allowed \(allowed)")
        }
    }

    func testGetContractCapabilitiesMapsAProblemToAFailure() async throws {
        stub.route(StubURLProtocol.method("GET", path: SettingsWire.capabilities)) { _ in
            .text(SettingsWire.internalErrorProblem(status: 500), status: 500, contentType: "application/problem+json")
        }
        routeSettingsServer()
        let api = await makeStubbedAPI()

        guard case .failed(.server(let status, let code, _)) = await api.getContractCapabilities() else {
            return XCTFail("a server error must stay a retryable failure")
        }
        XCTAssertEqual(status, 500)
        XCTAssertEqual(code, "internal_error")
    }

    func testGetContractCapabilitiesRefusesAnIdentityThatIsNoLongerCurrent() async throws {
        routeSettingsServer()
        let api = await makeStubbedAPI()
        let stale = HTTPRequestIdentity(
            serverId: "server-a",
            serverURL: "http://settings-test.invalid/",
            profileId: "a-profile-that-was-switched-away",
            clientFamily: AppleDeviceIdentity.current.clientFamily
        )

        guard case .failed = await api.getContractCapabilities(requestIdentity: stale) else {
            return XCTFail("a probe for a replaced profile must not report an answer")
        }
        XCTAssertTrue(stub.requests.isEmpty, "the request must not be sent at all")

        let current = HTTPRequestIdentity(
            serverId: "server-a",
            // The registry's spelling may carry a trailing slash.
            serverURL: "http://settings-test.invalid/",
            profileId: Self.stubProfileId,
            clientFamily: AppleDeviceIdentity.current.clientFamily
        )
        guard case .available = await api.getContractCapabilities(requestIdentity: current) else {
            return XCTFail("the current identity must be accepted")
        }
    }

    func testCapturedSettingsRequestRefusesToFollowANewActiveIdentity() async throws {
        routeSettingsServer()
        let suiteName = "settings-identity-race-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        let tokenStore = TokenStore(
            keychain: SharedKeychain(
                service: "SettingValuesIdentityTests.\(UUID().uuidString)",
                accessGroup: nil
            ),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await tokenStore.switchActiveServer(serverId: "server-a")
        await tokenStore.setServerUrl("http://settings-test.invalid")
        await tokenStore.setProfileId("profile-a")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokenStore)
        let captured = HTTPRequestIdentity(
            serverId: "server-a",
            serverURL: "http://settings-test.invalid",
            profileId: "profile-a",
            clientFamily: "mobile"
        )

        await tokenStore.switchActiveServer(serverId: "server-b")
        await tokenStore.setServerUrl("http://server-b.invalid")
        await tokenStore.setProfileId("profile-b")

        do {
            _ = try await http.requestData(
                method: "GET",
                path: "/api/v2/settings/contract/capabilities",
                requestIdentity: captured
            )
            XCTFail("a captured server/profile request must fail rather than follow the new session")
        } catch HTTPError.requestIdentityChanged {
            // Expected: no URL request was built or sent.
        }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testConcurrentScopedUnauthorizedResponsesShareOneRotatingRefresh() async throws {
        routeConcurrentScopedRefresh()
        let suiteName = "settings-refresh-single-flight-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        let tokenStore = TokenStore(
            keychain: SharedKeychain(
                service: "SettingValuesRefreshSingleFlightTests.\(UUID().uuidString)",
                accessGroup: nil
            ),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        let identity = HTTPRequestIdentity(
            serverId: "server-a",
            serverURL: "http://settings-test.invalid",
            profileId: "profile-a",
            clientFamily: "mobile"
        )
        await tokenStore.switchActiveServer(serverId: identity.serverId)
        await tokenStore.setServerUrl(identity.serverURL)
        await tokenStore.setProfileId(identity.profileId)
        await tokenStore.saveTokens(accessToken: "fake", refreshToken: "dummy")

        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokenStore)
        async let first = http.requestData(
            method: "GET",
            path: "/api/v2/settings/contract/capabilities",
            requestIdentity: identity
        )
        async let second = http.requestData(
            method: "GET",
            path: "/api/v2/settings/contract/capabilities",
            requestIdentity: identity
        )

        let (firstResponse, secondResponse) = try await (first, second)

        XCTAssertEqual(firstResponse.statusCode, 200)
        XCTAssertEqual(secondResponse.statusCode, 200)
        XCTAssertEqual(requestCount(SettingsWire.refresh), 1)
        XCTAssertEqual(requestCount(SettingsWire.capabilities), 4)
        let accessToken = await tokenStore.getAccessToken()
        let refreshToken = await tokenStore.getRefreshToken()
        XCTAssertEqual(accessToken, "placeholder")
        XCTAssertEqual(refreshToken, "redacted")
    }

    func testScopedAndOrdinaryUnauthorizedResponsesShareAccountRefreshFlight() async throws {
        routeMixedRefreshFlight(refresh: .json(SettingsWire.rotatedTokens))
        let suiteName = "settings-refresh-mixed-flight-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        let tokenStore = TokenStore(
            keychain: SharedKeychain(
                service: "SettingValuesMixedRefreshTests.\(UUID().uuidString)",
                accessGroup: nil
            ),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        let identity = HTTPRequestIdentity(
            serverId: "server-a",
            serverURL: "http://settings-test.invalid",
            profileId: "profile-a",
            clientFamily: "mobile"
        )
        await tokenStore.switchActiveServer(serverId: identity.serverId)
        await tokenStore.setServerUrl(identity.serverURL)
        await tokenStore.setProfileId(identity.profileId)
        await tokenStore.saveTokens(accessToken: "fake", refreshToken: "dummy")

        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokenStore)
        let sessionExpiredCount = LockedCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .siloSessionExpired,
            object: nil,
            queue: nil
        ) { _ in
            sessionExpiredCount.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        async let scoped = http.requestData(
            method: "GET",
            path: "/api/v2/settings/contract/capabilities",
            headers: ["X-Test-Refresh-Flow": "scoped"],
            requestIdentity: identity
        )
        async let ordinary = http.requestData(
            method: "GET",
            path: "/api/v2/settings/contract/capabilities",
            headers: ["X-Test-Refresh-Flow": "ordinary"]
        )

        let (scopedResponse, ordinaryResponse) = try await (scoped, ordinary)

        XCTAssertEqual(scopedResponse.statusCode, 200)
        XCTAssertEqual(ordinaryResponse.statusCode, 200)
        XCTAssertEqual(requestCount(SettingsWire.refresh), 1)
        XCTAssertEqual(requestCount(SettingsWire.capabilities), 4)
        let accessToken = await tokenStore.getAccessToken()
        let refreshToken = await tokenStore.getRefreshToken()
        XCTAssertEqual(accessToken, "placeholder")
        XCTAssertEqual(refreshToken, "redacted")
        XCTAssertEqual(sessionExpiredCount.value, 0)
    }

    func testFailedScopedRefreshExpiresOrdinaryJoinerWithoutAnonymousRetry() async throws {
        let release = StubURLProtocol.Gate()
        routeMixedRefreshFlight(refresh: .json(SettingsWire.invalidToken, status: 401), heldBy: release)
        let suiteName = "settings-refresh-mixed-failure-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        let tokenStore = TokenStore(
            keychain: SharedKeychain(
                service: "SettingValuesMixedRefreshFailureTests.\(UUID().uuidString)",
                accessGroup: nil
            ),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        let identity = HTTPRequestIdentity(
            serverId: "server-a",
            serverURL: "http://settings-test.invalid",
            profileId: "profile-a",
            clientFamily: "mobile"
        )
        await tokenStore.switchActiveServer(serverId: identity.serverId)
        await tokenStore.setServerUrl(identity.serverURL)
        await tokenStore.setProfileId(identity.profileId)
        await tokenStore.saveTokens(accessToken: "fake", refreshToken: "dummy")

        let joined = expectation(description: "ordinary 401 joined the scoped refresh")
        joined.assertForOverFulfill = false
        let http = HTTPClient(
            session: stub.makeSession(),
            tokenStore: tokenStore,
            refreshFlightJoinObserver: { kind in
                if case .ordinary = kind {
                    joined.fulfill()
                }
            }
        )
        let sessionExpiredCount = LockedCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .siloSessionExpired,
            object: nil,
            queue: nil
        ) { _ in
            sessionExpiredCount.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        async let scoped: HTTPRawResponse = http.requestData(
            method: "GET",
            path: "/api/v2/settings/contract/capabilities",
            headers: ["X-Test-Refresh-Flow": "scoped"],
            requestIdentity: identity
        )
        async let ordinary: HTTPRawResponse = http.requestData(
            method: "GET",
            path: "/api/v2/settings/contract/capabilities",
            headers: ["X-Test-Refresh-Flow": "ordinary"]
        )

        await fulfillment(of: [joined], timeout: 2)
        await release.open()

        do {
            _ = try await ordinary
            XCTFail("The ordinary joiner must fail when the shared refresh is rejected")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.statusCode, 401)
        }
        do {
            _ = try await scoped
            XCTFail("The scoped owner must fail when its refresh is rejected")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.statusCode, 401)
        }

        XCTAssertEqual(requestCount(SettingsWire.refresh), 1)
        XCTAssertEqual(requestCount(SettingsWire.capabilities), 2)
        let accessToken = await tokenStore.getAccessToken()
        let refreshToken = await tokenStore.getRefreshToken()
        XCTAssertNil(accessToken)
        XCTAssertNil(refreshToken)
        XCTAssertEqual(sessionExpiredCount.value, 1)
    }

    func testTransientScopedRefreshFailurePreservesCredentialsWithoutExpiryAndCanRetry() async throws {
        let harness = try await makeRefreshHarness(testName: "TransientRefresh")
        let sessionExpiredCount = LockedCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .siloSessionExpired,
            object: nil,
            queue: nil
        ) { _ in
            sessionExpiredCount.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        for status in [429, 503] {
            stub.reset()
            routeMixedRefreshFlight(refresh: .json(SettingsWire.temporarilyUnavailable, status: status))
            async let scoped: HTTPRawResponse = harness.http.requestData(
                method: "GET",
                path: "/api/v2/settings/contract/capabilities",
                headers: ["X-Test-Refresh-Flow": "scoped"],
                requestIdentity: harness.identity
            )
            async let ordinary: HTTPRawResponse = harness.http.requestData(
                method: "GET",
                path: "/api/v2/settings/contract/capabilities",
                headers: ["X-Test-Refresh-Flow": "ordinary"]
            )

            do {
                _ = try await ordinary
                XCTFail("The ordinary joiner must keep the original 401 after refresh HTTP \(status)")
            } catch {
                XCTAssertEqual((error as? HTTPError)?.statusCode, 401)
            }
            do {
                _ = try await scoped
                XCTFail("The scoped owner must keep the original 401 after refresh HTTP \(status)")
            } catch {
                XCTAssertEqual((error as? HTTPError)?.statusCode, 401)
            }

            XCTAssertEqual(requestCount(SettingsWire.refresh), 1)
            XCTAssertEqual(requestCount(SettingsWire.capabilities), 2)
            let accessToken = await harness.tokenStore.getAccessToken()
            let refreshToken = await harness.tokenStore.getRefreshToken()
            XCTAssertEqual(accessToken, "fake", "HTTP \(status) must preserve the access token")
            XCTAssertEqual(refreshToken, "dummy", "HTTP \(status) must preserve the refresh token")
            XCTAssertEqual(sessionExpiredCount.value, 0)
        }

        // A later 401 wave must be able to submit the preserved refresh token
        // and rotate the account credentials normally.
        stub.reset()
        routeMixedRefreshFlight(refresh: .json(SettingsWire.rotatedTokens))
        let retried = try await harness.http.requestData(
            method: "GET",
            path: "/api/v2/settings/contract/capabilities",
            headers: ["X-Test-Refresh-Flow": "scoped"],
            requestIdentity: harness.identity
        )
        XCTAssertEqual(retried.statusCode, 200)
        let accessToken = await harness.tokenStore.getAccessToken()
        let refreshToken = await harness.tokenStore.getRefreshToken()
        XCTAssertEqual(accessToken, "placeholder")
        XCTAssertEqual(refreshToken, "redacted")
        XCTAssertEqual(sessionExpiredCount.value, 0)
    }

    func testMalformedSuccessfulScopedRefreshDoesNotMarkServerUnreachable() async throws {
        routeMixedRefreshFlight(refresh: .json(SettingsWire.malformedTokens))
        let harness = try await makeRefreshHarness(testName: "MalformedRefresh")
        let sessionExpiredCount = LockedCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .siloSessionExpired,
            object: nil,
            queue: nil
        ) { _ in
            sessionExpiredCount.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        await MainActor.run {
            ConnectionMonitor.shared.noteServerResponded()
        }

        async let scoped: HTTPRawResponse = harness.http.requestData(
            method: "GET",
            path: "/api/v2/settings/contract/capabilities",
            headers: ["X-Test-Refresh-Flow": "scoped"],
            requestIdentity: harness.identity
        )
        async let ordinary: HTTPRawResponse = harness.http.requestData(
            method: "GET",
            path: "/api/v2/settings/contract/capabilities",
            headers: ["X-Test-Refresh-Flow": "ordinary"]
        )

        do {
            _ = try await ordinary
            XCTFail("The ordinary joiner must keep the original 401 when refresh decoding fails")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.statusCode, 401)
        }
        do {
            _ = try await scoped
            XCTFail("The scoped owner must keep the original 401 when refresh decoding fails")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.statusCode, 401)
        }

        let markedUnreachable = await MainActor.run {
            if case .unreachable = ConnectionMonitor.shared.serverStatus {
                return true
            }
            return false
        }
        XCTAssertFalse(markedUnreachable, "a malformed HTTP 200 is not a transport failure")
        let accessToken = await harness.tokenStore.getAccessToken()
        let refreshToken = await harness.tokenStore.getRefreshToken()
        XCTAssertEqual(accessToken, "fake")
        XCTAssertEqual(refreshToken, "dummy")
        XCTAssertEqual(sessionExpiredCount.value, 0)
    }

    func testRefreshFailureClassifierMatchesAndroid() {
        for status in [400, 401, 403] {
            XCTAssertTrue(
                HTTPClient.shouldInvalidateSessionAfterRefreshFailure(status),
                "HTTP \(status) is a terminal refresh rejection"
            )
        }
        for status in [408, 429, 500, 502, 503, 504] {
            XCTAssertFalse(
                HTTPClient.shouldInvalidateSessionAfterRefreshFailure(status),
                "HTTP \(status) must remain retryable"
            )
        }
    }

    func testOrdinaryUnauthorizedResponseCannotRefreshAccountSelectedAfterRequestWasSent() async throws {
        let release = routeHeldOrdinaryUnauthorized()
        let harness = try await makeRefreshHarness(testName: "UnauthorizedServerSwitch")

        let requestTask = Task {
            try await harness.http.requestData(
                method: "GET",
                path: "/api/v2/settings/contract/capabilities"
            )
        }
        do {
            try await stub.waitForRequest(
                timeout: .seconds(2),
                where: StubURLProtocol.method("GET", path: SettingsWire.capabilities)
            )
        } catch {
            await release.open()
            return XCTFail("ordinary request did not reach the delayed 401")
        }

        // Keep the same origin so only the captured server-account ID can
        // prevent B's token from being treated as a successful refresh of A.
        await harness.tokenStore.switchActiveServer(serverId: "server-b")
        await harness.tokenStore.setServerUrl(harness.identity.serverURL)
        await harness.tokenStore.setProfileId("profile-b")
        await harness.tokenStore.saveTokens(
            accessToken: "example",
            refreshToken: "sample"
        )
        await release.open()

        do {
            _ = try await requestTask.value
            XCTFail("the server-A 401 must not refresh or retry under server B")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.statusCode, 401)
        }
        let accessToken = await harness.tokenStore.getAccessToken()
        let refreshToken = await harness.tokenStore.getRefreshToken()
        XCTAssertEqual(accessToken, "example")
        XCTAssertEqual(refreshToken, "sample")
        XCTAssertEqual(requestCount(SettingsWire.refresh), 0)
        XCTAssertEqual(requestCount(SettingsWire.capabilities), 1)
    }

    func testOrdinaryUnauthorizedResponseCannotRefreshSameServerSessionInstalledAfterLogout() async throws {
        let release = routeHeldOrdinaryUnauthorized()
        let harness = try await makeRefreshHarness(testName: "UnauthorizedSameServerRelogin")

        let requestTask = Task {
            try await harness.http.requestData(
                method: "GET",
                path: "/api/v2/settings/contract/capabilities"
            )
        }
        do {
            try await stub.waitForRequest(
                timeout: .seconds(2),
                where: StubURLProtocol.method("GET", path: SettingsWire.capabilities)
            )
        } catch {
            await release.open()
            return XCTFail("ordinary request did not reach the delayed 401")
        }

        await harness.tokenStore.clearTokens()
        await harness.tokenStore.saveTokens(
            accessToken: "placeholder",
            refreshToken: "redacted"
        )
        await harness.tokenStore.setProfileId(harness.identity.profileId)
        await release.open()

        do {
            _ = try await requestTask.value
            XCTFail("the previous login epoch must not refresh or retry as a same-server replacement")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.statusCode, 401)
        }
        let accessToken = await harness.tokenStore.getAccessToken()
        let refreshToken = await harness.tokenStore.getRefreshToken()
        XCTAssertEqual(accessToken, "placeholder")
        XCTAssertEqual(refreshToken, "redacted")
        XCTAssertEqual(requestCount(SettingsWire.refresh), 0)
        XCTAssertEqual(requestCount(SettingsWire.capabilities), 1)
    }

    func testScopedUnauthorizedResponseCannotRefreshSameServerSessionInstalledAfterLogout() async throws {
        let release = routeHeldOrdinaryUnauthorized()
        let harness = try await makeRefreshHarness(testName: "ScopedUnauthorizedSameServerRelogin")

        let requestTask = Task {
            try await harness.http.requestData(
                method: "GET",
                path: "/api/v2/settings/contract/capabilities",
                requestIdentity: harness.identity
            )
        }
        do {
            try await stub.waitForRequest(
                timeout: .seconds(2),
                where: StubURLProtocol.method("GET", path: SettingsWire.capabilities)
            )
        } catch {
            await release.open()
            return XCTFail("scoped request did not reach the delayed 401")
        }

        await harness.tokenStore.clearTokens()
        await harness.tokenStore.saveTokens(
            accessToken: "placeholder",
            refreshToken: "redacted"
        )
        await harness.tokenStore.setProfileId(harness.identity.profileId)
        await release.open()

        do {
            _ = try await requestTask.value
            XCTFail("the scoped request must not refresh or retry as a same-server replacement epoch")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.statusCode, 401)
        }
        let accessToken = await harness.tokenStore.getAccessToken()
        let refreshToken = await harness.tokenStore.getRefreshToken()
        XCTAssertEqual(accessToken, "placeholder")
        XCTAssertEqual(refreshToken, "redacted")
        XCTAssertEqual(requestCount(SettingsWire.refresh), 0)
        XCTAssertEqual(requestCount(SettingsWire.capabilities), 1)
    }

    func testOrdinaryUnauthorizedResponseCannotRetryAfterProfileSwitch() async throws {
        let release = routeHeldOrdinaryUnauthorized()
        let harness = try await makeRefreshHarness(testName: "UnauthorizedProfileSwitch")
        await harness.tokenStore.setProfileToken("decoy-token")

        let requestTask = Task {
            try await harness.http.requestData(
                method: "GET",
                path: "/api/v2/settings/contract/capabilities"
            )
        }
        do {
            try await stub.waitForRequest(
                timeout: .seconds(2),
                where: StubURLProtocol.method("GET", path: SettingsWire.capabilities)
            )
        } catch {
            await release.open()
            return XCTFail("ordinary request did not reach the delayed 401")
        }

        await harness.tokenStore.setProfileId("profile-b")
        await harness.tokenStore.setProfileToken("gateway-token")
        await release.open()

        do {
            _ = try await requestTask.value
            XCTFail("the profile-A request must not refresh or retry as profile B")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.statusCode, 401)
        }
        XCTAssertEqual(requestCount(SettingsWire.refresh), 0)
        XCTAssertEqual(requestCount(SettingsWire.capabilities), 1)
        XCTAssertEqual(stub.requests.last?.header("X-Profile-Id"), "profile-a")
        XCTAssertEqual(stub.requests.last?.header("X-Profile-Token"), "decoy-token")
    }

    func testOrdinaryUnauthorizedResponseCannotCrossFromPersistentIntoTemporaryCredentials() async throws {
        let release = routeHeldOrdinaryUnauthorized()
        let harness = try await makeRefreshHarness(testName: "PersistentToTemporary")
        await harness.tokenStore.setProfileToken("test-auth-token")

        let requestTask = Task {
            try await harness.http.requestData(
                method: "GET",
                path: "/api/v2/settings/contract/capabilities"
            )
        }
        do {
            try await stub.waitForRequest(
                timeout: .seconds(2),
                where: StubURLProtocol.method("GET", path: SettingsWire.capabilities)
            )
        } catch {
            await release.open()
            return XCTFail("persistent request did not reach the delayed 401")
        }

        let temporary = TemporaryAuthScope(
            serverId: harness.identity.serverId,
            serverURL: harness.identity.serverURL,
            accessToken: "example",
            refreshToken: "sample",
            profileId: harness.identity.profileId,
            profileToken: "test-auth-token",
            controllerDeviceId: "controller",
            expiresAt: Date().addingTimeInterval(60)
        )
        await harness.tokenStore.beginTemporaryScope(temporary)
        await release.open()

        do {
            _ = try await requestTask.value
            XCTFail("a persistent 401 must not consume the same-account temporary overlay")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.statusCode, 401)
        }
        let current = await harness.tokenStore.getTemporaryScope()
        XCTAssertEqual(current?.credentialGenerationID, temporary.credentialGenerationID)
        XCTAssertEqual(current?.accessToken, "example")
        XCTAssertEqual(current?.refreshToken, "sample")
        XCTAssertEqual(requestCount(SettingsWire.refresh), 0)
        XCTAssertEqual(requestCount(SettingsWire.capabilities), 1)
    }

    func testOrdinaryUnauthorizedResponseCannotCrossFromTemporaryIntoPersistentCredentials() async throws {
        let release = routeHeldOrdinaryUnauthorized()
        let harness = try await makeRefreshHarness(testName: "TemporaryToPersistent")
        await harness.tokenStore.setProfileToken("test-auth-token")
        let temporary = TemporaryAuthScope(
            serverId: harness.identity.serverId,
            serverURL: harness.identity.serverURL,
            accessToken: "example",
            refreshToken: "sample",
            profileId: harness.identity.profileId,
            profileToken: "test-auth-token",
            controllerDeviceId: "controller",
            expiresAt: Date().addingTimeInterval(60)
        )
        await harness.tokenStore.beginTemporaryScope(temporary)

        let requestTask = Task {
            try await harness.http.requestData(
                method: "GET",
                path: "/api/v2/settings/contract/capabilities"
            )
        }
        do {
            try await stub.waitForRequest(
                timeout: .seconds(2),
                where: StubURLProtocol.method("GET", path: SettingsWire.capabilities)
            )
        } catch {
            await release.open()
            return XCTFail("temporary request did not reach the delayed 401")
        }

        _ = await harness.tokenStore.endTemporaryScope()
        await release.open()

        do {
            _ = try await requestTask.value
            XCTFail("a temporary 401 must not fall through to the persistent account")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.statusCode, 401)
        }
        let accessToken = await harness.tokenStore.getAccessToken()
        let refreshToken = await harness.tokenStore.getRefreshToken()
        XCTAssertEqual(accessToken, "fake")
        XCTAssertEqual(refreshToken, "dummy")
        XCTAssertEqual(requestCount(SettingsWire.refresh), 0)
        XCTAssertEqual(requestCount(SettingsWire.capabilities), 1)
    }

    func testRejectedTemporaryGenerationRefreshesAndExpiresOnlyOnce() async throws {
        routeRejectedRefresh()
        let harness = try await makeRefreshHarness(testName: "RejectedTemporaryGeneration")
        let temporary = TemporaryAuthScope(
            serverId: harness.identity.serverId,
            serverURL: harness.identity.serverURL,
            accessToken: "example",
            refreshToken: "sample",
            profileId: harness.identity.profileId,
            profileToken: "decoy-token",
            controllerDeviceId: "controller",
            expiresAt: Date().addingTimeInterval(60)
        )
        await harness.tokenStore.beginTemporaryScope(temporary)
        let expiryCount = LockedCounter()
        let expiryEvents = LockedSessionExpiryEvents()
        let observer = NotificationCenter.default.addObserver(
            forName: .temporaryRemoteAuthExpired,
            object: nil,
            queue: nil
        ) { notification in
            expiryCount.increment()
            if let event = notification.object as? SessionExpiryEvent {
                expiryEvents.append(event)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        for wave in 1...2 {
            do {
                _ = try await harness.http.requestData(
                    method: "GET",
                    path: "/api/v2/settings/contract/capabilities"
                )
                XCTFail("temporary 401 wave \(wave) must remain unauthorized")
            } catch {
                XCTAssertEqual((error as? HTTPError)?.statusCode, 401)
            }
        }

        XCTAssertEqual(requestCount(SettingsWire.refresh), 1)
        XCTAssertEqual(requestCount(SettingsWire.capabilities), 2)
        XCTAssertEqual(expiryCount.value, 1)
        let current = await harness.tokenStore.getTemporaryScope()
        XCTAssertEqual(current?.credentialGenerationID, temporary.credentialGenerationID)
        XCTAssertEqual(current?.accessToken, "example")
        XCTAssertEqual(current?.refreshToken, "sample")
        XCTAssertEqual(expiryEvents.values, [SessionExpiryEvent(
            account: RefreshAccountIdentity(
                serverId: temporary.serverId,
                serverURL: temporary.serverURL,
                credentialGenerationID: temporary.credentialGenerationID
            ),
            disposition: .temporarySessionExpired
        )])
    }

    func testRejectedTemporaryScopedRefreshPostsTemporaryExpiryNotification() async throws {
        routeRejectedRefresh()
        let harness = try await makeRefreshHarness(testName: "RejectedTemporaryScopedGeneration")
        let temporary = TemporaryAuthScope(
            serverId: harness.identity.serverId,
            serverURL: harness.identity.serverURL,
            accessToken: "example",
            refreshToken: "sample",
            profileId: harness.identity.profileId,
            profileToken: "decoy-token",
            controllerDeviceId: "controller",
            expiresAt: Date().addingTimeInterval(60)
        )
        await harness.tokenStore.beginTemporaryScope(temporary)
        let temporaryExpiryCount = LockedCounter()
        let persistentExpiryCount = LockedCounter()
        let expiryEvents = LockedSessionExpiryEvents()
        let temporaryObserver = NotificationCenter.default.addObserver(
            forName: .temporaryRemoteAuthExpired,
            object: nil,
            queue: nil
        ) { notification in
            temporaryExpiryCount.increment()
            if let event = notification.object as? SessionExpiryEvent {
                expiryEvents.append(event)
            }
        }
        let persistentObserver = NotificationCenter.default.addObserver(
            forName: .siloSessionExpired,
            object: nil,
            queue: nil
        ) { _ in
            persistentExpiryCount.increment()
        }
        defer {
            NotificationCenter.default.removeObserver(temporaryObserver)
            NotificationCenter.default.removeObserver(persistentObserver)
        }

        do {
            _ = try await harness.http.requestData(
                method: "GET",
                path: "/api/v2/settings/contract/capabilities",
                requestIdentity: harness.identity
            )
            XCTFail("the scoped temporary request must remain unauthorized")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.statusCode, 401)
        }

        XCTAssertEqual(requestCount(SettingsWire.refresh), 1)
        XCTAssertEqual(requestCount(SettingsWire.capabilities), 1)
        XCTAssertEqual(temporaryExpiryCount.value, 1)
        XCTAssertEqual(persistentExpiryCount.value, 0)
        XCTAssertEqual(expiryEvents.values, [SessionExpiryEvent(
            account: RefreshAccountIdentity(
                serverId: temporary.serverId,
                serverURL: temporary.serverURL,
                credentialGenerationID: temporary.credentialGenerationID
            ),
            disposition: .temporarySessionExpired
        )])
    }

    func testSuccessfulTemporaryScopedRefreshRotatesOnlyTemporaryGeneration() async throws {
        routeMixedRefreshFlight(refresh: .json(SettingsWire.rotatedTokens))
        let harness = try await makeRefreshHarness(testName: "SuccessfulTemporaryScopedGeneration")
        let temporary = TemporaryAuthScope(
            serverId: harness.identity.serverId,
            serverURL: harness.identity.serverURL,
            accessToken: "example",
            refreshToken: "sample",
            profileId: harness.identity.profileId,
            profileToken: "decoy-token",
            controllerDeviceId: "controller",
            expiresAt: Date().addingTimeInterval(60)
        )
        await harness.tokenStore.beginTemporaryScope(temporary)

        let response = try await harness.http.requestData(
            method: "GET",
            path: "/api/v2/settings/contract/capabilities",
            headers: ["X-Test-Refresh-Flow": "scoped"],
            requestIdentity: harness.identity
        )

        XCTAssertEqual(response.statusCode, 200)
        let activeScope = await harness.tokenStore.getTemporaryScope()
        XCTAssertEqual(activeScope?.credentialGenerationID, temporary.credentialGenerationID)
        XCTAssertEqual(activeScope?.accessToken, "placeholder")
        XCTAssertEqual(activeScope?.refreshToken, "redacted")
        _ = await harness.tokenStore.endTemporaryScope(
            expectedGenerationID: temporary.credentialGenerationID
        )
        let persistentAccess = await harness.tokenStore.getAccessToken()
        let persistentRefresh = await harness.tokenStore.getRefreshToken()
        XCTAssertEqual(persistentAccess, "fake")
        XCTAssertEqual(persistentRefresh, "dummy")
        XCTAssertEqual(requestCount(SettingsWire.refresh), 1)
        XCTAssertEqual(requestCount(SettingsWire.capabilities), 2)
    }

    func testPersistentExpiryEventIsRejectedAfterSameServerSessionReplacement() async throws {
        routeSettingsServer()
        let harness = try await makeRefreshHarness(testName: "PersistentExpiryEpoch")
        let accountValue = await harness.tokenStore.refreshAccountIdentity()
        let account = try XCTUnwrap(accountValue)
        let capturedValue = await harness.tokenStore.captureRefreshCredential(expected: account)
        let captured = try XCTUnwrap(capturedValue)
        let dispositionValue = await harness.tokenStore.invalidateRejectedRefresh(captured)
        let disposition = try XCTUnwrap(dispositionValue)
        let event = SessionExpiryEvent(account: account, disposition: disposition)

        XCTAssertEqual(disposition, .persistentSessionCleared)
        let consumableBeforeReplacement = await harness.tokenStore.shouldConsumeSessionExpiryEvent(event)
        XCTAssertTrue(consumableBeforeReplacement)

        await harness.tokenStore.saveTokens(
            accessToken: "placeholder",
            refreshToken: "redacted"
        )
        await harness.tokenStore.setProfileId(harness.identity.profileId)

        let consumableAfterReplacement = await harness.tokenStore.shouldConsumeSessionExpiryEvent(event)
        XCTAssertFalse(
            consumableAfterReplacement,
            "a queued rejection from the prior epoch must not sign out a same-server replacement"
        )
    }

    func testTemporaryExpiryTeardownCannotRemoveReplacementAfterConsumerValidation() async throws {
        routeSettingsServer()
        let harness = try await makeRefreshHarness(testName: "TemporaryExpiryReplacement")
        let rejected = TemporaryAuthScope(
            serverId: harness.identity.serverId,
            serverURL: harness.identity.serverURL,
            accessToken: "fake",
            refreshToken: "dummy",
            profileId: harness.identity.profileId,
            profileToken: "gateway-token",
            controllerDeviceId: "controller-a",
            expiresAt: Date().addingTimeInterval(60)
        )
        await harness.tokenStore.beginTemporaryScope(rejected)
        let accountValue = await harness.tokenStore.refreshAccountIdentity()
        let account = try XCTUnwrap(accountValue)
        let capturedValue = await harness.tokenStore.captureRefreshCredential(expected: account)
        let captured = try XCTUnwrap(capturedValue)
        let dispositionValue = await harness.tokenStore.invalidateRejectedRefresh(captured)
        let disposition = try XCTUnwrap(dispositionValue)
        let event = SessionExpiryEvent(account: account, disposition: disposition)

        XCTAssertEqual(disposition, .temporarySessionExpired)
        let consumableBeforeReplacement = await harness.tokenStore.shouldConsumeSessionExpiryEvent(event)
        XCTAssertTrue(consumableBeforeReplacement)

        // Model replacement after ContentView consumed the event but before
        // player cleanup completed and the TV identity manager reached its
        // destructive scope-removal step.
        let replacement = TemporaryAuthScope(
            serverId: rejected.serverId,
            serverURL: rejected.serverURL,
            accessToken: "placeholder",
            refreshToken: "redacted",
            profileId: rejected.profileId,
            profileToken: "test-token-placeholder",
            controllerDeviceId: "controller-b",
            expiresAt: Date().addingTimeInterval(120)
        )
        await harness.tokenStore.beginTemporaryScope(replacement)

        let endResult = await harness.tokenStore.endTemporaryScope(
            expectedGenerationID: rejected.credentialGenerationID
        )
        XCTAssertEqual(
            endResult,
            .differentGeneration(
                activeGenerationID: replacement.credentialGenerationID
            )
        )
        let currentScope = await harness.tokenStore.getTemporaryScope()
        let consumableAfterReplacement = await harness.tokenStore.shouldConsumeSessionExpiryEvent(event)
        XCTAssertEqual(currentScope, replacement)
        XCTAssertFalse(consumableAfterReplacement)
    }

    func testTemporaryScopeTeardownDistinguishesAbsenceFromReplacementGeneration() async throws {
        routeSettingsServer()
        let harness = try await makeRefreshHarness(testName: "TemporaryScopeEndResult")
        let ending = TemporaryAuthScope(
            serverId: harness.identity.serverId,
            serverURL: harness.identity.serverURL,
            accessToken: "ending-access",
            refreshToken: "ending-refresh",
            profileId: harness.identity.profileId,
            profileToken: "ending-profile",
            controllerDeviceId: "controller-a",
            expiresAt: Date().addingTimeInterval(60)
        )
        await harness.tokenStore.beginTemporaryScope(ending)

        await harness.tokenStore.clearTokens()
        let absentResult = await harness.tokenStore.endTemporaryScope(
            expectedGenerationID: ending.credentialGenerationID
        )
        XCTAssertEqual(absentResult, .alreadyAbsent)

        let replacement = TemporaryAuthScope(
            serverId: ending.serverId,
            serverURL: ending.serverURL,
            accessToken: "replacement-access",
            refreshToken: "replacement-refresh",
            profileId: ending.profileId,
            profileToken: "replacement-profile",
            controllerDeviceId: "controller-b",
            expiresAt: Date().addingTimeInterval(120)
        )
        await harness.tokenStore.beginTemporaryScope(replacement)

        let replacementResult = await harness.tokenStore.endTemporaryScope(
            expectedGenerationID: ending.credentialGenerationID
        )
        let currentScope = await harness.tokenStore.getTemporaryScope()
        XCTAssertEqual(
            replacementResult,
            .differentGeneration(
                activeGenerationID: replacement.credentialGenerationID
            )
        )
        XCTAssertEqual(currentScope, replacement)
    }

    func testRemotePlaybackEndPolicyAcceptsExpectedGenerationWhenScopeIsAlreadyAbsent() {
        let endingGenerationID = UUID()
        let replacementGenerationID = UUID()

        XCTAssertEqual(
            RemotePlaybackIdentityEndPolicy.endingGenerationID(
                activeIdentityGenerationID: endingGenerationID,
                scopeGenerationID: nil,
                expectedGenerationID: endingGenerationID
            ),
            endingGenerationID,
            "delayed cleanup must clear a matching identity after its scope was already removed"
        )
        XCTAssertNil(
            RemotePlaybackIdentityEndPolicy.endingGenerationID(
                activeIdentityGenerationID: endingGenerationID,
                scopeGenerationID: replacementGenerationID,
                expectedGenerationID: endingGenerationID
            ),
            "a replacement scope must remain protected"
        )
        XCTAssertNil(
            RemotePlaybackIdentityEndPolicy.endingGenerationID(
                activeIdentityGenerationID: replacementGenerationID,
                scopeGenerationID: nil,
                expectedGenerationID: endingGenerationID
            ),
            "a replacement manager identity must remain protected"
        )
    }

    func testSignOutAuthorizationAllowsIncompleteLocalStateAndRefusesTemporaryOwner() {
        let account = RefreshAccountIdentity(
            serverId: "server-a",
            serverURL: "http://settings-test.invalid",
            credentialGenerationID: UUID()
        )
        let persistentAuth = CapturedOrdinaryRequestAuth(
            account: account,
            credentialOwner: .persistentServer(serverId: account.serverId),
            accessToken: "persistent-access",
            profileId: "profile-a",
            profileToken: "persistent-profile"
        )
        let temporaryAuth = CapturedOrdinaryRequestAuth(
            account: account,
            credentialOwner: .temporary,
            accessToken: "temporary-access",
            profileId: "profile-a",
            profileToken: "temporary-profile"
        )

        XCTAssertEqual(
            AuthService.signOutAuthorization(
                activeServerId: account.serverId,
                capturedAuth: persistentAuth
            ),
            .allowed(account: account)
        )
        XCTAssertEqual(
            AuthService.signOutAuthorization(
                activeServerId: account.serverId,
                capturedAuth: nil
            ),
            .allowed(account: nil),
            "an incomplete URL/defaults mirror must not strand local credentials"
        )
        XCTAssertEqual(
            AuthService.signOutAuthorization(
                activeServerId: account.serverId,
                capturedAuth: temporaryAuth
            ),
            .refused,
            "the temporary identity owner must be torn down before persistent sign-out"
        )
        XCTAssertEqual(
            AuthService.signOutAuthorization(
                activeServerId: "server-b",
                capturedAuth: persistentAuth
            ),
            .refused,
            "a stale capture must not clear another active server"
        )
    }

    func testReplacementCancellationWaitsForOldEndBeforeStartingNewGenerationRequest() async throws {
        routeSettingsServer()
        let harness = try await makeRefreshHarness(testName: "SerializedIdentityCancellation")
        let barrier = SerializedCancellationPassBarrier()
        let http = HTTPClient(
            session: stub.makeSession(),
            tokenStore: harness.tokenStore,
            cancellationPassBarrier: { await barrier.enter() }
        )

        // Model an old end already enumerating URLSession work when a
        // replacement activation begins its own cancellation pass.
        let oldEnd = Task { await http.cancelInFlightRequests() }
        guard await waitForCancellationPass(barrier, count: 1) else {
            return XCTFail("old-generation cancellation pass did not start")
        }
        let replacement = Task {
            await http.cancelInFlightRequests()
            return try await http.requestData(
                method: "GET",
                path: "/api/v2/settings/contract/capabilities"
            )
        }

        try? await Task.sleep(for: .milliseconds(50))
        let overlappingPassCount = await barrier.entryCount
        XCTAssertEqual(
            overlappingPassCount,
            1,
            "replacement cancellation must queue instead of overlapping the old enumeration"
        )
        XCTAssertEqual(
            requestCount(SettingsWire.capabilities),
            0,
            "replacement work must not start while an old cancellation can still enumerate it"
        )

        await barrier.release(pass: 1)
        await oldEnd.value
        guard await waitForCancellationPass(barrier, count: 2) else {
            return XCTFail("replacement cancellation pass did not start after the old pass")
        }
        XCTAssertEqual(requestCount(SettingsWire.capabilities), 0)
        await barrier.release(pass: 2)

        let response = try await replacement.value
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(requestCount(SettingsWire.capabilities), 1)
    }

    func testScopedRefreshCannotRetryAsSameServerReplacementInstalledAfterRefresh() async throws {
        routeMixedRefreshFlight(refresh: .json(SettingsWire.rotatedTokens))
        let harness = try await makeRefreshHarness(testName: "ScopedPostRefreshReplacement")
        let barrier = SerializedCancellationPassBarrier()
        let http = HTTPClient(
            session: stub.makeSession(),
            tokenStore: harness.tokenStore,
            scopedRefreshRetryBarrier: { await barrier.enter() }
        )

        let request = Task {
            try await http.requestData(
                method: "GET",
                path: "/api/v2/settings/contract/capabilities",
                headers: ["X-Test-Refresh-Flow": "scoped"],
                requestIdentity: harness.identity
            )
        }
        guard await waitForCancellationPass(barrier, count: 1) else {
            return XCTFail("scoped request did not reach its post-refresh retry boundary")
        }
        await harness.tokenStore.clearTokens()
        await harness.tokenStore.saveTokens(
            accessToken: "placeholder",
            refreshToken: "redacted"
        )
        await harness.tokenStore.setProfileId(harness.identity.profileId)
        await barrier.release(pass: 1)

        do {
            _ = try await request.value
            XCTFail("the prior epoch must not retry under a same-server replacement")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.statusCode, 401)
        }
        let replacementAccess = await harness.tokenStore.getAccessToken()
        let replacementRefresh = await harness.tokenStore.getRefreshToken()
        XCTAssertEqual(replacementAccess, "placeholder")
        XCTAssertEqual(replacementRefresh, "redacted")
        XCTAssertEqual(requestCount(SettingsWire.refresh), 1)
        XCTAssertEqual(requestCount(SettingsWire.capabilities), 1)
    }

    func testCancelledTemporaryReplacementRestoresPriorOwnerGeneration() async throws {
        routeSettingsServer()
        let harness = try await makeRefreshHarness(testName: "TemporaryActivationRollback")
        let previous = TemporaryAuthScope(
            serverId: harness.identity.serverId,
            serverURL: harness.identity.serverURL,
            accessToken: "fake",
            refreshToken: "dummy",
            profileId: harness.identity.profileId,
            profileToken: "decoy-token",
            controllerDeviceId: "controller-a",
            expiresAt: Date().addingTimeInterval(60)
        )
        let replacement = TemporaryAuthScope(
            serverId: previous.serverId,
            serverURL: previous.serverURL,
            accessToken: "placeholder",
            refreshToken: "redacted",
            profileId: previous.profileId,
            profileToken: "test-token-placeholder",
            controllerDeviceId: "controller-b",
            expiresAt: Date().addingTimeInterval(120)
        )
        await harness.tokenStore.beginTemporaryScope(previous)
        let barrier = SerializedCancellationPassBarrier()

        let activation = Task {
            let displaced = await harness.tokenStore.beginTemporaryScope(replacement)
            await barrier.enter()
            guard !Task.isCancelled else {
                return await harness.tokenStore.restoreTemporaryScope(
                    displaced,
                    replacingGenerationID: replacement.credentialGenerationID
                )
            }
            return false
        }
        guard await waitForCancellationPass(barrier, count: 1) else {
            return XCTFail("replacement was not installed before cancellation")
        }
        activation.cancel()
        await barrier.release(pass: 1)
        let restored = await activation.value
        let restoredScope = await harness.tokenStore.getTemporaryScope()
        let restoredAccount = await harness.tokenStore.refreshAccountIdentity()
        XCTAssertTrue(restored)
        XCTAssertEqual(restoredScope, previous)
        XCTAssertEqual(
            restoredAccount?.credentialGenerationID,
            previous.credentialGenerationID,
            "TokenStore must remain aligned with the manager's prior active generation"
        )
    }

    func testRequestStartingBetweenCancellationSessionSnapshotsIsRejected() async throws {
        routeSettingsServer()
        let harness = try await makeRefreshHarness(testName: "CancellationSnapshotGate")
        let barrier = SerializedCancellationPassBarrier()
        let http = HTTPClient(
            session: stub.makeSession(),
            tokenStore: harness.tokenStore,
            cancellationSessionBarrier: { index in
                if index == 1 { await barrier.enter() }
            }
        )

        let cancellation = Task { await http.cancelInFlightRequests() }
        guard await waitForCancellationPass(barrier, count: 1) else {
            return XCTFail("cancellation did not pause between session snapshots")
        }
        do {
            _ = try await http.requestData(
                method: "GET",
                path: "/api/v2/settings/contract/capabilities"
            )
            XCTFail("dispatch must remain closed between cancellation snapshots")
        } catch HTTPError.requestIdentityChanged {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(requestCount(SettingsWire.capabilities), 0)
        await barrier.release(pass: 1)
        await cancellation.value
    }

    func testPublishedServerHydrationWaitsUntilCancellationAndTransitionAreOpen() async throws {
        routeSettingsServer()
        let harness = try await makeRefreshHarness(testName: "PublishedServerHydrationGate")
        let cancellationBarrier = SerializedCancellationPassBarrier()
        let http = HTTPClient(
            session: stub.makeSession(),
            tokenStore: harness.tokenStore,
            cancellationPassBarrier: { await cancellationBarrier.enter() }
        )
        guard let lease = await http.beginIdentityTransition() else {
            return XCTFail("identity transition was unexpectedly cancelled")
        }

        let cancellation = Task { await http.cancelInFlightRequests() }
        guard await waitForCancellationPass(cancellationBarrier, count: 1) else {
            await http.endIdentityTransition(lease)
            return XCTFail("cancellation pass did not reach its barrier")
        }

        // Mirrors ServerRegistry publishing `activeServerId` before releasing
        // the transition lease, which starts ContentView's keyed hydration.
        let activeServerPublications = LockedCounter()
        let hydrationStarts = LockedCounter()
        activeServerPublications.increment()
        let hydration = Task {
            guard await http.waitForRequestDispatchOpen() else { return false }
            guard !Task.isCancelled else { return false }
            hydrationStarts.increment()
            return true
        }
        guard await waitForRequestDispatchWaiter(http) else {
            await cancellationBarrier.release(pass: 1)
            await cancellation.value
            await http.endIdentityTransition(lease)
            return XCTFail("published-server hydration did not wait for dispatch")
        }
        XCTAssertEqual(activeServerPublications.value, 1)
        XCTAssertEqual(hydrationStarts.value, 0)

        await cancellationBarrier.release(pass: 1)
        await cancellation.value
        XCTAssertEqual(
            hydrationStarts.value,
            0,
            "finishing cancellation alone must not bypass the published switch lease"
        )

        await http.endIdentityTransition(lease)
        let hydrationCompleted = await hydration.value
        XCTAssertTrue(hydrationCompleted)
        XCTAssertEqual(hydrationStarts.value, 1)
    }

    func testCancelledDispatchOpenWaiterPerformsNoHydrationWork() async throws {
        routeSettingsServer()
        let harness = try await makeRefreshHarness(testName: "CancelledHydrationWaiter")
        guard let lease = await harness.http.beginIdentityTransition() else {
            return XCTFail("identity transition was unexpectedly cancelled")
        }

        let hydrationStarts = LockedCounter()
        let hydration = Task {
            guard await harness.http.waitForRequestDispatchOpen() else { return false }
            guard !Task.isCancelled else { return false }
            hydrationStarts.increment()
            return true
        }
        guard await waitForRequestDispatchWaiter(harness.http) else {
            await harness.http.endIdentityTransition(lease)
            return XCTFail("hydration did not queue behind the transition")
        }

        hydration.cancel()
        let hydrationCompleted = await hydration.value
        let pendingWaiters = await harness.http.pendingRequestDispatchWaiterCount()
        XCTAssertFalse(hydrationCompleted)
        XCTAssertEqual(hydrationStarts.value, 0)
        XCTAssertEqual(pendingWaiters, 0)

        await harness.http.endIdentityTransition(lease)
        XCTAssertEqual(hydrationStarts.value, 0)
    }

    func testRequestCaptureCannotSurviveCompletedIdentityRetarget() async throws {
        routeSettingsServer()
        let harness = try await makeRefreshHarness(testName: "CaptureDuringRetarget")
        let barrier = SerializedCancellationPassBarrier()
        let http = HTTPClient(
            session: stub.makeSession(),
            tokenStore: harness.tokenStore,
            requestCaptureBarrier: { await barrier.enter() }
        )

        let request = Task {
            try await http.requestData(
                method: "GET",
                path: "/api/v2/settings/contract/capabilities"
            )
        }
        guard await waitForCancellationPass(barrier, count: 1) else {
            return XCTFail("request did not pause before credential capture")
        }
        guard let lease = await http.beginIdentityTransition() else {
            return XCTFail("identity transition was unexpectedly cancelled")
        }
        await http.cancelInFlightRequests()
        await harness.tokenStore.setServerUrl("http://replacement.invalid")
        await harness.tokenStore.switchActiveServer(serverId: "server-b")
        await harness.tokenStore.setProfileId("profile-b")
        await harness.tokenStore.saveTokens(accessToken: "example", refreshToken: "sample")
        await http.endIdentityTransition(lease)
        await barrier.release(pass: 1)

        do {
            _ = try await request.value
            XCTFail("a pre-retarget dispatch revision must not send after the gate reopens")
        } catch HTTPError.requestIdentityChanged {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testCompletedResponseIsRejectedWhenIdentityTransitionsBeforeDelivery() async throws {
        routeSettingsServer()
        let harness = try await makeRefreshHarness(testName: "ResponseDuringTransition")
        let barrier = SerializedCancellationPassBarrier()
        let http = HTTPClient(
            session: stub.makeSession(),
            tokenStore: harness.tokenStore,
            responseReceivedBarrier: { await barrier.enter() }
        )

        let request = Task {
            try await http.requestData(
                method: "GET",
                path: "/api/v2/settings/contract/capabilities"
            )
        }
        guard await waitForCancellationPass(barrier, count: 1) else {
            return XCTFail("request did not pause after URLSession completed")
        }
        guard let lease = await http.beginIdentityTransition() else {
            return XCTFail("identity transition was unexpectedly cancelled")
        }
        await http.cancelInFlightRequests()
        await http.endIdentityTransition(lease)
        await barrier.release(pass: 1)

        do {
            _ = try await request.value
            XCTFail("a completed old-generation response must fail closed")
        } catch HTTPError.requestIdentityChanged {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(requestCount(SettingsWire.capabilities), 1)
    }

    func testCandidateProbeDoesNotChangeActiveServerReachability() async throws {
        routeSettingsServer()
        let harness = try await makeRefreshHarness(testName: "CandidateReachabilityIsolation")
        await MainActor.run { ConnectionMonitor.shared.noteServerUnreachable() }

        let health: HealthStatus = try await harness.http.getUnauthenticated(
            serverURL: harness.identity.serverURL,
            path: ConnectionMonitor.healthPath
        )
        XCTAssertEqual(health.status, "ok")
        let activeStillUnreachable = await MainActor.run {
            if case .unreachable = ConnectionMonitor.shared.serverStatus { return true }
            return false
        }
        XCTAssertTrue(
            activeStillUnreachable,
            "a candidate response must not mark the unrelated active server healthy"
        )
        await MainActor.run { ConnectionMonitor.shared.noteServerResponded() }
    }

    func testCancelledQueuedSessionInstallNeverAcquiresLeaseOrWritesTokens() async throws {
        routeSettingsServer()
        let harness = try await makeRefreshHarness(testName: "CancelledQueuedInstall")
        guard let blockingLease = await harness.http.beginIdentityTransition() else {
            return XCTFail("blocking transition was unexpectedly cancelled")
        }

        let queuedInstall = Task {
            guard let lease = await harness.http.beginIdentityTransition() else {
                return false
            }
            guard !Task.isCancelled else {
                await harness.http.endIdentityTransition(lease)
                return false
            }
            await harness.tokenStore.saveTokens(
                accessToken: "placeholder",
                refreshToken: "redacted"
            )
            await harness.http.endIdentityTransition(lease)
            return true
        }
        guard await waitForIdentityTransitionWaiter(harness.http) else {
            await harness.http.endIdentityTransition(blockingLease)
            return XCTFail("session install did not queue behind the active transition")
        }
        queuedInstall.cancel()
        let installCommitted = await queuedInstall.value
        XCTAssertFalse(installCommitted)
        let accessBeforeRelease = await harness.tokenStore.getAccessToken()
        let refreshBeforeRelease = await harness.tokenStore.getRefreshToken()
        XCTAssertEqual(accessBeforeRelease, "fake")
        XCTAssertEqual(refreshBeforeRelease, "dummy")

        await harness.http.endIdentityTransition(blockingLease)
        guard let nextLease = await harness.http.beginIdentityTransition() else {
            return XCTFail("queue did not progress after removing the cancelled waiter")
        }
        await harness.http.endIdentityTransition(nextLease)
    }

    func testAccountBoundLogoutCannotDispatchAfterServerSwitch() async throws {
        routeSettingsServer()
        let harness = try await makeRefreshHarness(testName: "BoundLogoutServerSwitch")
        let accountValue = await harness.tokenStore.refreshAccountIdentity()
        let account = try XCTUnwrap(accountValue)
        let barrier = SerializedCancellationPassBarrier()
        let http = HTTPClient(
            session: stub.makeSession(),
            tokenStore: harness.tokenStore,
            requestCaptureBarrier: { await barrier.enter() }
        )

        let api = APIv2Client(http: http, tokenStore: harness.tokenStore, isUpdateRequired: { false })
        let logout = Task {
            try await api.logout(expectedAccount: account)
        }
        guard await waitForCancellationPass(barrier, count: 1) else {
            return XCTFail("logout did not pause before its bound account capture")
        }
        guard let lease = await http.beginIdentityTransition() else {
            return XCTFail("server switch transition was unexpectedly cancelled")
        }
        await http.cancelInFlightRequests()
        await harness.tokenStore.setServerUrl("http://replacement.invalid")
        await harness.tokenStore.switchActiveServer(serverId: "server-b")
        await harness.tokenStore.setProfileId("profile-b")
        await harness.tokenStore.saveTokens(accessToken: "example", refreshToken: "sample")
        await http.endIdentityTransition(lease)
        await barrier.release(pass: 1)

        do {
            try await logout.value
            XCTFail("logout bound to server A must not dispatch under server B")
        } catch HTTPError.requestIdentityChanged {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(requestCount(SettingsWire.logout), 0)
        let currentAccess = await harness.tokenStore.getAccessToken()
        XCTAssertEqual(currentAccess, "example")
    }

    func testOrdinaryRefreshLateSuccessCannotWriteAcrossServerSwitch() async throws {
        let held = routeHeldOrdinaryRefresh()
        let harness = try await makeRefreshHarness(testName: "RefreshServerSwitch")
        let sessionExpiredCount = LockedCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .siloSessionExpired,
            object: nil,
            queue: nil
        ) { _ in
            sessionExpiredCount.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let requestTask = Task {
            try await harness.http.requestData(
                method: "GET",
                path: "/api/v2/settings/contract/capabilities"
            )
        }
        do {
            try await stub.waitForRequest(
                timeout: .seconds(2),
                where: StubURLProtocol.method("POST", path: SettingsWire.refresh)
            )
        } catch {
            await held.release(status: 503)
            return XCTFail("ordinary refresh did not reach the delayed response")
        }

        await harness.tokenStore.switchActiveServer(serverId: "server-b")
        await harness.tokenStore.setServerUrl("http://settings-test.invalid/server-b")
        await harness.tokenStore.setProfileId("profile-b")
        await harness.tokenStore.saveTokens(
            accessToken: "example",
            refreshToken: "sample"
        )
        await held.release(status: 200)

        do {
            _ = try await requestTask.value
            XCTFail("the server-A request must keep its original 401 after switching to server B")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.statusCode, 401)
        }
        let serverBAccess = await harness.tokenStore.getAccessToken()
        let serverBRefresh = await harness.tokenStore.getRefreshToken()
        XCTAssertEqual(serverBAccess, "example")
        XCTAssertEqual(serverBRefresh, "sample")
        XCTAssertEqual(sessionExpiredCount.value, 0)
        XCTAssertEqual(requestCount(SettingsWire.refresh), 1)
        XCTAssertEqual(requestCount(SettingsWire.capabilities), 1)
    }

    func testOrdinaryRefreshLateSuccessCannotRestoreSignedOutSession() async throws {
        let held = routeHeldOrdinaryRefresh()
        let harness = try await makeRefreshHarness(testName: "RefreshSignOut")
        let sessionExpiredCount = LockedCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .siloSessionExpired,
            object: nil,
            queue: nil
        ) { _ in
            sessionExpiredCount.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let requestTask = Task {
            try await harness.http.requestData(
                method: "GET",
                path: "/api/v2/settings/contract/capabilities"
            )
        }
        do {
            try await stub.waitForRequest(
                timeout: .seconds(2),
                where: StubURLProtocol.method("POST", path: SettingsWire.refresh)
            )
        } catch {
            await held.release(status: 503)
            return XCTFail("ordinary refresh did not reach the delayed response")
        }

        await harness.tokenStore.clearTokens()
        await held.release(status: 200)

        do {
            _ = try await requestTask.value
            XCTFail("a late refresh response must not sign the user back in")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.statusCode, 401)
        }
        let accessToken = await harness.tokenStore.getAccessToken()
        let refreshToken = await harness.tokenStore.getRefreshToken()
        XCTAssertNil(accessToken)
        XCTAssertNil(refreshToken)
        XCTAssertEqual(sessionExpiredCount.value, 0)
    }

    func testOrdinaryRejectedRefreshCannotClearNewerCredentials() async throws {
        let held = routeHeldOrdinaryRefresh()
        let harness = try await makeRefreshHarness(testName: "RefreshNewerToken")
        let sessionExpiredCount = LockedCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .siloSessionExpired,
            object: nil,
            queue: nil
        ) { _ in
            sessionExpiredCount.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let requestTask = Task {
            try await harness.http.requestData(
                method: "GET",
                path: "/api/v2/settings/contract/capabilities"
            )
        }
        do {
            try await stub.waitForRequest(
                timeout: .seconds(2),
                where: StubURLProtocol.method("POST", path: SettingsWire.refresh)
            )
        } catch {
            await held.release(status: 503)
            return XCTFail("ordinary refresh did not reach the delayed response")
        }

        await harness.tokenStore.saveTokens(
            accessToken: "placeholder",
            refreshToken: "redacted"
        )
        await held.release(status: 403)

        do {
            _ = try await requestTask.value
            XCTFail("the rejected request must not retry as a replacement login epoch")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.statusCode, 401)
        }
        let accessToken = await harness.tokenStore.getAccessToken()
        let refreshToken = await harness.tokenStore.getRefreshToken()
        XCTAssertEqual(accessToken, "placeholder")
        XCTAssertEqual(refreshToken, "redacted")
        XCTAssertEqual(sessionExpiredCount.value, 0)
        XCTAssertEqual(requestCount(SettingsWire.refresh), 1)
        XCTAssertEqual(requestCount(SettingsWire.capabilities), 1)
    }

    func testScopedRefreshPersistsServerAccountRotationAcrossProfileChange() async throws {
        let suiteName = "settings-refresh-profile-switch-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        let keychain = SharedKeychain(
            service: "SettingValuesRefreshProfileTests.\(UUID().uuidString)",
            accessGroup: nil
        )
        let tokenStore = TokenStore(
            keychain: keychain,
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        let identity = HTTPRequestIdentity(
            serverId: "server-a",
            serverURL: "http://settings-test.invalid",
            profileId: "profile-a",
            clientFamily: "mobile"
        )

        await tokenStore.switchActiveServer(serverId: identity.serverId)
        await tokenStore.setServerUrl(identity.serverURL)
        await tokenStore.setProfileId(identity.profileId)
        await tokenStore.saveTokens(accessToken: "fake", refreshToken: "dummy")
        await tokenStore.setProfileToken("example")

        // The account refresh began under profile A, but profile B became
        // active before the server returned its rotated account credentials.
        await tokenStore.setProfileId("profile-b")
        await tokenStore.setProfileToken("sample")
        let stored = await tokenStore.saveRefreshedTokens(
            "placeholder",
            "redacted",
            replacing: "dummy",
            expected: identity,
            credentialOwner: .persistentServer(serverId: identity.serverId)
        )

        XCTAssertTrue(stored)
        let currentAccess = await tokenStore.getAccessToken()
        let currentRefresh = await tokenStore.getRefreshToken()
        let currentProfileId = await tokenStore.getProfileId()
        let currentProfileValue = await tokenStore.getProfileToken()
        XCTAssertEqual(currentAccess, "placeholder")
        XCTAssertEqual(currentRefresh, "redacted")
        XCTAssertEqual(currentProfileId, "profile-b")
        XCTAssertEqual(currentProfileValue, "sample")
    }

    func testScopedRefreshRejectsChangedServerAccountAndTemporaryScope() async throws {
        let suiteName = "settings-refresh-account-boundary-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        let keychain = SharedKeychain(
            service: "SettingValuesRefreshBoundaryTests.\(UUID().uuidString)",
            accessGroup: nil
        )
        let tokenStore = TokenStore(
            keychain: keychain,
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        let identity = HTTPRequestIdentity(
            serverId: "server-a",
            serverURL: "http://settings-test.invalid",
            profileId: "profile-a",
            clientFamily: "mobile"
        )

        await tokenStore.switchActiveServer(serverId: identity.serverId)
        await tokenStore.setServerUrl(identity.serverURL)
        await tokenStore.setProfileId(identity.profileId)
        await tokenStore.saveTokens(accessToken: "fake", refreshToken: "dummy")

        let originalAccountValue = await tokenStore.refreshAccountIdentity()
        let originalAccount = try XCTUnwrap(originalAccountValue)
        let originalRefreshValue = await tokenStore.captureRefreshCredential(expected: originalAccount)
        let originalRefresh = try XCTUnwrap(originalRefreshValue)

        await tokenStore.setServerUrl("http://changed-url.invalid")
        let wrongURLStored = await tokenStore.saveRefreshedTokens(
            "example",
            "sample",
            replacing: "dummy",
            expected: identity,
            credentialOwner: .persistentServer(serverId: identity.serverId)
        )
        let refreshAfterWrongURL = await tokenStore.getRefreshToken()
        XCTAssertFalse(wrongURLStored)
        XCTAssertNil(refreshAfterWrongURL, "Canonical credentials cannot authorize a retargeted origin")

        await tokenStore.setServerUrl(identity.serverURL)
        // Returning to the origin restores the stored session, but under a new
        // credential generation: the refresh captured before the retarget must
        // not rotate it.
        let staleGenerationRotated = await tokenStore.saveRefreshedTokens(
            "placeholder",
            "redacted",
            replacing: originalRefresh
        )
        XCTAssertFalse(staleGenerationRotated)
        let afterReturnValue = await tokenStore.refreshAccountIdentity()
        let afterReturn = try XCTUnwrap(afterReturnValue)
        let afterReturnCredentialValue = await tokenStore.captureRefreshCredential(expected: afterReturn)
        let afterReturnCredential = try XCTUnwrap(afterReturnCredentialValue)
        let rotated = await tokenStore.saveRefreshedTokens(
            "placeholder",
            "redacted",
            replacing: afterReturnCredential
        )
        XCTAssertTrue(rotated)
        let staleStored = await tokenStore.saveRefreshedTokens(
            "not-a-real",
            "changeme",
            replacing: "dummy",
            expected: identity,
            credentialOwner: .persistentServer(serverId: identity.serverId)
        )
        let refreshAfterStale = await tokenStore.getRefreshToken()
        XCTAssertFalse(staleStored)
        XCTAssertEqual(refreshAfterStale, "redacted")
        let staleDisposition = await tokenStore.invalidateRejectedRefresh(originalRefresh)
        let refreshAfterStaleClear = await tokenStore.getRefreshToken()
        XCTAssertNil(staleDisposition)
        XCTAssertEqual(refreshAfterStaleClear, "redacted")

        let temporary = TemporaryAuthScope(
            serverId: identity.serverId,
            serverURL: identity.serverURL,
            accessToken: "test-auth-token",
            // Match the persistent value so credential provenance, rather
            // than value inequality, is what prevents the write.
            refreshToken: "redacted",
            profileId: "temporary-profile",
            profileToken: "secret-token",
            controllerDeviceId: "controller",
            expiresAt: Date().addingTimeInterval(60)
        )
        await tokenStore.beginTemporaryScope(temporary)
        let temporaryIdentity = HTTPRequestIdentity(
            serverId: identity.serverId,
            serverURL: identity.serverURL,
            profileId: temporary.profileId,
            clientFamily: identity.clientFamily
        )
        let capturedTemporary = try await tokenStore.captureRequestAuth(expected: temporaryIdentity)
        _ = await tokenStore.endTemporaryScope()
        let temporaryStored = await tokenStore.saveRefreshedTokens(
            "test-token-placeholder",
            "token-oversized",
            replacing: "redacted",
            expected: temporaryIdentity,
            credentialOwner: capturedTemporary.credentialOwner
        )
        let refreshAfterTemporary = await tokenStore.getRefreshToken()
        XCTAssertFalse(temporaryStored)
        XCTAssertEqual(capturedTemporary.credentialOwner, .temporary)
        XCTAssertEqual(
            refreshAfterTemporary,
            "redacted",
            "credentials captured from a temporary scope must never redirect into persistent storage"
        )

        let serverAAccountValue = await tokenStore.refreshAccountIdentity()
        let serverAAccount = try XCTUnwrap(serverAAccountValue)
        let serverARefreshValue = await tokenStore.captureRefreshCredential(expected: serverAAccount)
        let serverARefresh = try XCTUnwrap(serverARefreshValue)

        await tokenStore.switchActiveServer(serverId: "server-b")
        await tokenStore.setServerUrl("http://server-b.invalid")
        await tokenStore.setProfileId("profile-b")
        await tokenStore.saveTokens(accessToken: "gateway-token", refreshToken: "decoy-token")
        let crossServerStored = await tokenStore.saveRefreshedTokens(
            "clawrouter-e2e-secret",
            "very-long-browser-token-0123456789",
            replacing: "redacted",
            expected: identity,
            credentialOwner: .persistentServer(serverId: identity.serverId)
        )
        let crossServerDisposition = await tokenStore.invalidateRejectedRefresh(serverARefresh)
        let serverBAccess = await tokenStore.getAccessToken()
        let serverBRefresh = await tokenStore.getRefreshToken()
        XCTAssertFalse(crossServerStored)
        XCTAssertNil(crossServerDisposition)
        XCTAssertEqual(serverBAccess, "gateway-token")
        XCTAssertEqual(serverBRefresh, "decoy-token")
    }

    func testGetEffectiveValuesSendsRepeatedQueryParams() async throws {
        routeSettingsServer()
        let api = await makeStubbedAPI()

        let response = try await api.getEffectiveValues(
            keys: [.playbackSubtitleLanguage, .playbackAutoPlayNext],
            libraryIds: [7, 9],
            seriesIds: ["s-101"]
        )
        XCTAssertEqual(response.revision, SettingKey.revision)
        XCTAssertEqual(response.value(for: .playbackAutoPlayNext)?.value, .bool(true))

        let recorded = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(recorded.method, "GET")
        XCTAssertEqual(recorded.path, "/api/v2/settings/values/effective")
        XCTAssertEqual(recorded.queryItems, [
            URLQueryItem(name: "keys", value: "playback.subtitle_language"),
            URLQueryItem(name: "keys", value: "playback.auto_play_next"),
            URLQueryItem(name: "library_ids", value: "7"),
            URLQueryItem(name: "library_ids", value: "9"),
            URLQueryItem(name: "series_ids", value: "s-101"),
        ])
        XCTAssertEqual(recorded.header("X-Profile-Id"), Self.stubProfileId)
        XCTAssertEqual(recorded.header("X-Silo-Client-Family"), AppleDeviceIdentity.current.clientFamily)
        XCTAssertEqual(recorded.header("X-Silo-Device-Id")?.isEmpty, false)
    }

    func testGetEffectiveValuesRejectsARevisionBelowTheMinimum() async throws {
        routeSettingsServer(manifestRevision: SettingKey.minimumServerRevision - 1)
        let api = await makeStubbedAPI()

        do {
            _ = try await api.getEffectiveValues(keys: [.playbackSubtitleLanguage])
            XCTFail("a client must not apply an effective response from an unsupported contract")
        } catch let error as SettingsAPIError {
            XCTAssertEqual(error, .serverUpgradeRequired)
        }
    }

    func testGetEffectiveValuesFromThePreviousRevisionServesOnlyKeysItKnows() async throws {
        routeSettingsServer(manifestRevision: SettingKey.revision - 1)
        let api = await makeStubbedAPI()

        let response = try await api.getEffectiveValues(keys: [.playbackSubtitleLanguage])
        XCTAssertEqual(response.revision, SettingKey.revision - 1)

        let newest = SettingKey.allCases.filter { $0.introducedIn == SettingKey.revision }
        XCTAssertFalse(newest.isEmpty)
        do {
            _ = try await api.getEffectiveValues(keys: [.playbackSubtitleLanguage] + newest)
            XCTFail("a resolution for keys the server does not know is only the default")
        } catch let error as SettingsAPIError {
            XCTAssertEqual(error, .serverUpgradeRequired)
        }
    }

    func testGetEffectiveValuesReportsUpgradeRequiredOnAV1OnlyServer() async throws {
        stub.route(StubURLProtocol.any) { _ in .text("404 page not found\n", status: 404) }
        let api = await makeStubbedAPI()

        do {
            _ = try await api.getEffectiveValues(keys: [.playbackSubtitleLanguage])
            XCTFail("a v1-only server has no effective values to read")
        } catch let error as SettingsAPIError {
            XCTAssertEqual(error, .serverUpgradeRequired)
        }
    }

    func testGetEffectiveValuesMapsAKeyTheServerLacksToUnknownSetting() async throws {
        stub.route(StubURLProtocol.method("GET", path: SettingsWire.effective)) { _ in
            .text(SettingsWire.unknownKeyProblem, status: 422, contentType: "application/problem+json")
        }
        routeSettingsServer()
        let api = await makeStubbedAPI()

        do {
            _ = try await api.getEffectiveValues(keys: [.playbackSubtitleLanguage])
            XCTFail("a key missing from the server's contract must fail")
        } catch let error as SettingsAPIError {
            guard case .unknownSetting = error else {
                return XCTFail("expected unknownSetting, got \(error)")
            }
        }
    }

    func testGetEffectiveValuesRefusesRowsForAnotherProfileOrRepeatedKeys() async throws {
        let api = await makeStubbedAPI()
        let cases = [
            ("foreign profile row", SettingsWire.foreignProfileRow(revision: SettingKey.revision)),
            ("duplicate keys", SettingsWire.duplicateKeys(revision: SettingKey.revision)),
        ]
        for (label, body) in cases {
            stub.reset()
            stub.route(StubURLProtocol.method("GET", path: SettingsWire.effective)) { _ in .json(body) }
            routeSettingsServer()
            do {
                _ = try await api.getEffectiveValues(keys: [.playbackAutoPlayNext])
                XCTFail("\(label) must not be applied")
            } catch let error as SettingsAPIError {
                guard case .transport = error else {
                    return XCTFail("expected a refused response for \(label), got \(error)")
                }
            }
        }
    }

    func testGetEffectiveValuesOmitsEmptyParams() async throws {
        routeSettingsServer()
        let api = await makeStubbedAPI()

        _ = try await api.getEffectiveValues()

        let recorded = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(recorded.queryItems, [], "no keys means every remote definition, not keys=")
        XCTAssertNil(recorded.query["profile_id"], "the household-parent override is never sent")
    }

    func testProfileScopedCallWithoutAProfileFailsLocally() async throws {
        routeSettingsServer()
        let api = await makeStubbedAPI(profileId: nil)

        do {
            _ = try await api.getEffectiveValues(keys: [.playbackAutoPlayNext])
            XCTFail("a values call with no profile must not reach the server")
        } catch let error as SettingsAPIError {
            XCTAssertEqual(error, .profileRequired)
        }
        XCTAssertTrue(stub.requests.isEmpty, "the request must not be sent at all")
    }

    // MARK: - Harness

    static let stubProfileId = "profile-under-test"

    /// A SiloAPI whose HTTPClient talks to this test's `stub`, with a
    /// TokenStore isolated to this test.
    private func makeStubbedAPI(profileId: String? = SettingValuesAPITests.stubProfileId) async -> SiloAPI {
        let suiteName = "settings-values-tests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        let tokenStore = TokenStore(
            keychain: SharedKeychain(service: "SettingValuesAPITests.\(UUID().uuidString)", accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await tokenStore.switchActiveServer(serverId: "server-a")
        await tokenStore.setServerUrl("http://settings-test.invalid")
        await tokenStore.setProfileId(profileId)

        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokenStore)
        return SiloAPI(http: http, tokenStore: tokenStore)
    }

    private func makeRefreshHarness(testName: String) async throws -> (
        tokenStore: TokenStore,
        identity: HTTPRequestIdentity,
        http: HTTPClient
    ) {
        let suiteName = "settings-refresh-\(testName)-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        let tokenStore = TokenStore(
            keychain: SharedKeychain(
                service: "SettingValues\(testName)Tests.\(UUID().uuidString)",
                accessGroup: nil
            ),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        let identity = HTTPRequestIdentity(
            serverId: "server-a",
            serverURL: "http://settings-test.invalid",
            profileId: "profile-a",
            clientFamily: "mobile"
        )
        await tokenStore.switchActiveServer(serverId: identity.serverId)
        await tokenStore.setServerUrl(identity.serverURL)
        await tokenStore.setProfileId(identity.profileId)
        await tokenStore.saveTokens(accessToken: "fake", refreshToken: "dummy")

        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokenStore)
        return (tokenStore, identity, http)
    }

    /// How many requests this test sent to `path`, on any host.
    private func requestCount(_ path: String) -> Int {
        stub.requests.filter { $0.path == path }.count
    }

    private func waitForCancellationPass(
        _ barrier: SerializedCancellationPassBarrier,
        count: Int
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await barrier.entryCount >= count {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func waitForIdentityTransitionWaiter(_ http: HTTPClient) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await http.pendingIdentityTransitionCount() > 0 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func waitForRequestDispatchWaiter(_ http: HTTPClient) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await http.pendingRequestDispatchWaiterCount() > 0 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
    // MARK: - Server scenarios

    // Each installer adds routes to this test's `stub`. Routes are matched in
    // insertion order, so an installer called after a test's own override
    // only answers what the override does not. Reply closures capture only
    // Sendable locals, never `self`.

    /// A server that speaks the canonical settings API at `manifestRevision`.
    private func routeSettingsServer(manifestRevision: Int = SettingKey.revision) {
        stub.route(StubURLProtocol.method("GET", path: ConnectionMonitor.healthPath)) { _ in
            .json(SettingsWire.health)
        }
        stub.route(StubURLProtocol.method("GET", path: SettingsWire.capabilities)) { _ in
            .json(SettingsWire.capabilitiesBody(manifestRevision: manifestRevision))
        }
        stub.route(StubURLProtocol.method("GET", path: SettingsWire.effective)) { _ in
            .json(SettingsWire.effectiveBody(revision: manifestRevision))
        }
    }

    /// Two expired scoped requests race one rotating account refresh. Both
    /// initial 401s are held until the second arrives, so the regression
    /// always exercises two already-sent requests joining the same refresh
    /// flight.
    private func routeConcurrentScopedRefresh() {
        let arrivals = LockedCounter()
        let bothSent = StubURLProtocol.Gate()
        let capabilities = StubURLProtocol.method("GET", path: SettingsWire.capabilities)
        let rotated: StubURLProtocol.Matcher = {
            capabilities($0) && $0.header("Authorization") == "Bearer placeholder"
        }
        stub.route(StubURLProtocol.method("POST", path: SettingsWire.refresh)) { _ in
            .json(SettingsWire.rotatedTokens)
        }
        stub.route(rotated) { _ in
            .json(SettingsWire.capabilitiesBody())
        }
        stub.route(capabilities) { _ in
            if arrivals.increment() >= 2 {
                await bothSent.open()
            }
            await bothSent.wait()
            return .json(SettingsWire.unauthorized, status: 401)
        }
    }

    /// A scoped request (`X-Test-Refresh-Flow: scoped`) owns the account
    /// refresh while an ordinary 401 joins it. The ordinary 401 is held until
    /// the refresh starts. The refresh answers `refresh` once `release` opens
    /// or, with no gate, after 100 ms, long enough for the ordinary 401 to
    /// reach HTTPClient's shared account slot.
    private func routeMixedRefreshFlight(
        refresh: StubURLProtocol.Response,
        heldBy release: StubURLProtocol.Gate? = nil
    ) {
        let refreshStarted = StubURLProtocol.Gate()
        let capabilities = StubURLProtocol.method("GET", path: SettingsWire.capabilities)
        let rotated: StubURLProtocol.Matcher = {
            capabilities($0) && $0.header("Authorization") == "Bearer placeholder"
        }
        let scoped: StubURLProtocol.Matcher = {
            capabilities($0) && $0.header("X-Test-Refresh-Flow") == "scoped"
        }
        stub.route(rotated) { _ in
            .json(SettingsWire.capabilitiesBody())
        }
        stub.route(scoped) { _ in
            .json(SettingsWire.unauthorized, status: 401)
        }
        stub.route(capabilities) { _ in
            await refreshStarted.wait()
            return .json(SettingsWire.unauthorized, status: 401)
        }
        stub.route(StubURLProtocol.method("POST", path: SettingsWire.refresh)) { _ in
            await refreshStarted.open()
            if let release {
                await release.wait()
            } else {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return refresh
        }
    }

    /// An ordinary request's refresh waits for the test to release it through
    /// the returned `HeldResponse`.
    private func routeHeldOrdinaryRefresh() -> HeldResponse {
        let held = HeldResponse()
        let capabilities = StubURLProtocol.method("GET", path: SettingsWire.capabilities)
        let refreshed: StubURLProtocol.Matcher = {
            capabilities($0)
                && ["Bearer placeholder", "Bearer newer-access"].contains($0.header("Authorization"))
        }
        stub.route(refreshed) { _ in
            .json(SettingsWire.capabilitiesBody())
        }
        stub.route(capabilities) { _ in
            .json(SettingsWire.unauthorized, status: 401)
        }
        stub.route(StubURLProtocol.method("POST", path: SettingsWire.refresh)) { _ in
            await held.response()
        }
        return held
    }

    /// An ordinary request's initial 401 waits, across a server or credential
    /// switch, until the test opens the returned gate. Only the first such
    /// request is held; every test using this sends exactly one.
    private func routeHeldOrdinaryUnauthorized() -> StubURLProtocol.Gate {
        let release = StubURLProtocol.Gate()
        let capabilities = StubURLProtocol.method("GET", path: SettingsWire.capabilities)
        let expired: StubURLProtocol.Matcher = {
            capabilities($0) && $0.header("Authorization") != "Bearer placeholder"
        }
        stub.expect(expired) { _ in
            await release.wait()
            return .json(SettingsWire.unauthorized, status: 401)
        }
        stub.route(capabilities) { _ in
            .json(SettingsWire.capabilitiesBody())
        }
        stub.route(StubURLProtocol.method("POST", path: SettingsWire.refresh)) { _ in
            .json(SettingsWire.rotatedTokens)
        }
        return release
    }

    /// A temporary credential generation is terminally rejected.
    private func routeRejectedRefresh() {
        stub.route(StubURLProtocol.method("GET", path: SettingsWire.capabilities)) { _ in
            .json(SettingsWire.unauthorized, status: 401)
        }
        stub.route(StubURLProtocol.method("POST", path: SettingsWire.refresh)) { _ in
            .json(SettingsWire.invalidToken, status: 401)
        }
    }
}

/// Wire paths and bodies for the settings server scenarios.
private enum SettingsWire {
    static let capabilities = "/api/v2/settings/contract/capabilities"
    static let effective = "/api/v2/settings/values/effective"
    static let refresh = "/api/v2/auth/refresh"
    static let logout = "/api/v2/auth/logout"

    static let rotatedTokens = #"{"access_token":"placeholder","refresh_token":"redacted","expires_in":3600}"#
    static let unauthorized = #"{"error":"unauthorized"}"#
    static let invalidToken = #"{"error":"invalid_token"}"#
    static let temporarilyUnavailable = #"{"error":"temporarily_unavailable"}"#
    /// HTTP 200 refresh body with no refresh token.
    static let malformedTokens = #"{"access_token":"placeholder"}"#
    static let health = #"{"status":"ok","server_name":"Candidate"}"#

    /// The effective read names a key the server's contract lacks.
    static let unknownKeyProblem = """
    {"type":"https://siloserver.org/docs/api/v2/problems/validation_failed","title":"Validation failed",
     "status":422,"detail":"The request did not pass validation; see errors.",
     "errors":[{"location":"query.keys","code":"invalid",
                "detail":"No setting named no.such exists in this server's contract"}]}
    """

    /// A v2 `SettingsContractCapabilities` document.
    static func capabilitiesBody(
        manifestRevision: Int = SettingKey.revision,
        state: String = "available",
        allowed: Bool = true
    ) -> String {
        """
        {"revision":"36e767e32d6613323df470594b9c9106","state":"\(state)","allowed":\(allowed),
         "api_version":1,"manifest_revision":\(manifestRevision),"contract_etag":"\\"etag\\"",
         "definition_count":48,
         "scopes":["account","profile","profile_client","profile_device","profile_library","profile_series"],
         "client_families":["tv","mobile","tablet","desktop","web"],
         "supports_batched_effective":true,"supports_idempotent_writes":true,
         "supports_atomic_shortcuts":true}
        """
    }

    static func internalErrorProblem(status: Int) -> String {
        """
        {"type":"https://siloserver.org/docs/api/v2/problems/internal_error","title":"Internal error",
         "status":\(status),"detail":"An unexpected error occurred."}
        """
    }

    static func effectiveBody(revision: Int) -> String {
        """
        {"items":[{"key":"playback.auto_play_next","value":true,"source":"default","definition_revision":3}],
         "revision":\(revision)}
        """
    }

    /// An effective response with a row for another profile.
    static func foreignProfileRow(revision: Int) -> String {
        """
        {"items":[{"key":"playback.auto_play_next","value":false,"source":"profile","scope":"profile",
                   "profile_id":"someone-else","definition_revision":3}],
         "revision":\(revision)}
        """
    }

    /// An effective response with the same key twice.
    static func duplicateKeys(revision: Int) -> String {
        """
        {"items":[{"key":"playback.auto_play_next","value":true,"source":"default","definition_revision":3},
                  {"key":"playback.auto_play_next","value":false,"source":"default","definition_revision":3}],
         "revision":\(revision)}
        """
    }
}

/// A refresh reply held until the test releases it with a status: 2xx
/// answers rotated tokens, anything else `{"error":"invalid_token"}`. The
/// first release wins.
private final class HeldResponse: @unchecked Sendable {
    private let gate = StubURLProtocol.Gate()
    private let lock = NSLock()
    private var released: StubURLProtocol.Response?

    func release(status: Int) async {
        let body = (200..<300).contains(status) ? SettingsWire.rotatedTokens : SettingsWire.invalidToken
        lock.withLock {
            if released == nil {
                released = .json(body, status: status)
            }
        }
        await gate.open()
    }

    /// Waits for `release(status:)`. A waiter whose request was cancelled
    /// first resumes early; the stub drops a cancelled reply, so the 599
    /// fallback is never delivered.
    func response() async -> StubURLProtocol.Response {
        await gate.wait()
        return lock.withLock { released } ?? .status(599)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Returns the new count, so a caller can act on the value it produced.
    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class LockedSessionExpiryEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SessionExpiryEvent] = []

    func append(_ event: SessionExpiryEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var values: [SessionExpiryEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private actor SerializedCancellationPassBarrier {
    private(set) var entryCount = 0
    private var releases: [Int: CheckedContinuation<Void, Never>] = [:]

    func enter() async {
        entryCount += 1
        let pass = entryCount
        await withCheckedContinuation { continuation in
            releases[pass] = continuation
        }
    }

    func release(pass: Int) {
        releases.removeValue(forKey: pass)?.resume()
    }
}
