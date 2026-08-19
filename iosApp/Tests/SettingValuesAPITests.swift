import XCTest
@testable import Silo

/// Contract tests for the canonical settings API client.
///
/// The three things that can silently break it: the heterogeneous value
/// representation losing a type on the way through, a key-coding strategy
/// reaching a field or an object key it must not touch, and a server too old
/// to serve the routes at all being reported as a generic failure.
final class SettingValuesAPITests: XCTestCase {

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
            {"settings":[
              {"key":"playback.subtitle_language","value":"ja","source":"profile_series",
               "scope":"profile_series","profile_id":"p1","series_id":"s-101",
               "suggested_values":["en","ja","pt-BR"]},
              {"key":"playback.auto_play_next","value":true,"source":"default"}
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
        // /api/v1 is additive: a newer server may resolve keys and scopes this
        // build has never heard of, and one unfamiliar row must not take the
        // whole settings screen down with it.
        let response = try SettingsWireCoding.makeDecoder()
            .decode(EffectiveSettingValuesResponse.self, from: Data("""
            {"settings":[
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

    func testCapabilitiesDecodeAndCompareAgainstTheGeneratedRevision() throws {
        let capabilities = try SettingsWireCoding.makeDecoder()
            .decode(SettingsContractCapabilities.self, from: Data("""
            {"api_version":1,"revision":1,"contract_etag":"\\"abc123\\"","definition_count":48,
             "scopes":["account","profile","profile_device","profile_library","profile_series"],
             "supports_batched_effective":true,"supports_idempotent_writes":true}
            """.utf8))

        XCTAssertEqual(capabilities.apiVersion, 1)
        XCTAssertEqual(capabilities.revision, 1)
        XCTAssertEqual(capabilities.contractEtag, "\"abc123\"")
        XCTAssertEqual(capabilities.definitionCount, 48)
        XCTAssertTrue(capabilities.supportsBatchedEffective)
        XCTAssertTrue(capabilities.supportsIdempotentWrites)
        XCTAssertFalse(
            capabilities.supportsAtomicShortcuts,
            "a missing revision-5 feature flag must decode fail-closed"
        )
        XCTAssertEqual(capabilities.contractIsAheadOfServer, SettingKey.revision > 1)
    }

    // MARK: - Error mapping

    func testBare404MapsToServerUpgradeRequired() {
        // The router's own 404: the route does not exist, so the server
        // predates the canonical settings API entirely.
        XCTAssertEqual(
            SettingsAPIError.from(HTTPError.http(statusCode: 404, body: nil)),
            .serverUpgradeRequired
        )
        XCTAssertEqual(
            SettingsAPIError.from(HTTPError.http(statusCode: 404, body: "404 page not found")),
            .serverUpgradeRequired
        )
    }

    func test404WithASiloEnvelopeIsNotAnUpgradePrompt() {
        // A contract-aware 404 means the key or the row is missing, which is a
        // normal answer — telling the user to upgrade their server for it
        // would be wrong.
        XCTAssertEqual(
            SettingsAPIError.from(
                HTTPError.http(
                    statusCode: 404,
                    body: #"{"error":"unknown_setting","message":"No setting named x exists"}"#
                ),
                key: "playback.nope"
            ),
            .unknownSetting(key: "playback.nope")
        )
        XCTAssertEqual(
            SettingsAPIError.from(
                HTTPError.http(
                    statusCode: 404,
                    body: #"{"error":"not_found","message":"No value is set at this scope"}"#
                )
            ),
            .noValueAtScope
        )
    }

    func test404WithAnUnrecognizedSiloEnvelopeIsNotAnUpgradePromptEither() {
        // The envelope is the signal, not the status: any Silo handler answered,
        // so the route exists and the server is not too old — even when this
        // build does not know the code yet. Telling the user to upgrade here
        // would be actively misleading.
        if case .server(let status, let code, _) = SettingsAPIError.from(
            HTTPError.http(
                statusCode: 404,
                body: #"{"error":"profile_not_found","message":"No such profile"}"#
            )
        ) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(code, "profile_not_found")
        } else {
            XCTFail("an enveloped 404 must not map to .serverUpgradeRequired")
        }
    }

    func testMutationIdConflictIsItsOwnCase() {
        // Reusing an id for different content must not look like a generic
        // 409 — a caller that retries with a fresh id would double-apply.
        XCTAssertEqual(
            SettingsAPIError.from(
                HTTPError.http(
                    statusCode: 409,
                    body: #"{"error":"mutation_id_conflict","message":"This mutation id was used for a different write"}"#
                )
            ),
            .mutationIdConflict
        )
    }

    func testContractErrorsMapToNamedCases() {
        XCTAssertEqual(
            SettingsAPIError.from(
                HTTPError.http(
                    statusCode: 400,
                    body: #"{"error":"scope_not_allowed","message":"x cannot be set at profile_series"}"#
                ),
                key: "playback.preferred_quality",
                scope: .profileSeries
            ),
            .scopeNotAllowed(key: "playback.preferred_quality", scope: .profileSeries)
        )
        XCTAssertEqual(
            SettingsAPIError.from(
                HTTPError.http(
                    statusCode: 400,
                    body: #"{"error":"client_local_setting","message":"device-local"}"#
                ),
                key: "downloads.wifi_only"
            ),
            .clientLocalSetting(key: "downloads.wifi_only")
        )
        if case .invalidValue = SettingsAPIError.from(
            HTTPError.http(statusCode: 400, body: #"{"error":"invalid_value","message":"not in enum"}"#)
        ) {} else {
            XCTFail("invalid_value must map to .invalidValue")
        }
        if case .server(let status, let code, _) = SettingsAPIError.from(
            HTTPError.http(statusCode: 500, body: #"{"error":"internal_error","message":"boom"}"#)
        ) {
            XCTAssertEqual(status, 500)
            XCTAssertEqual(code, "internal_error")
        } else {
            XCTFail("an unrecognized failure must stay a generic server error")
        }
    }

    // MARK: - Requests over the wire

    func testGetContractCapabilitiesReportsUpgradeRequiredOnABare404() async throws {
        SettingsStubProtocol.reset(mode: .serverTooOld)
        let api = await makeStubbedAPI()

        let result = await api.getContractCapabilities()
        XCTAssertEqual(result, .serverUpgradeRequired)
        XCTAssertNil(result.capabilities)
    }

    func testGetContractCapabilitiesReturnsCapabilitiesOnACurrentServer() async throws {
        SettingsStubProtocol.reset(mode: .normal)
        let api = await makeStubbedAPI()

        guard case .available(let capabilities) = await api.getContractCapabilities() else {
            return XCTFail("a current server must report capabilities")
        }
        XCTAssertEqual(capabilities.revision, SettingKey.revision)
        XCTAssertTrue(capabilities.supportsIdempotentWrites)
        XCTAssertTrue(capabilities.supportsAtomicShortcuts)
    }

    func testGetContractCapabilitiesRequiresTheServersRevisionToBeCurrent() async throws {
        SettingsStubProtocol.reset(mode: .olderContractRevision)
        let api = await makeStubbedAPI()

        let result = await api.getContractCapabilities()
        XCTAssertEqual(result, .serverUpgradeRequired)
    }

    func testPutValueSendsScopeIdentityMutationIdAndProfileHeader() async throws {
        SettingsStubProtocol.reset(mode: .normal)
        let api = await makeStubbedAPI()
        let mutationId = newSettingMutationId()

        let receipt = try await api.putValue(
            key: .playbackSubtitleAppearance,
            scope: .profileDevice,
            value: ["fontSize": "large", "backgroundOpacity": 75],
            mutationId: mutationId
        )

        XCTAssertFalse(receipt.isIdempotentReplay)
        XCTAssertEqual(receipt.value.settingKey, .playbackSubtitleAppearance)

        let recorded = try XCTUnwrap(SettingsStubProtocol.state().lastRequest)
        XCTAssertEqual(recorded.method, "PUT")
        XCTAssertEqual(recorded.path, "/api/v1/settings/values/playback.subtitle_appearance")
        XCTAssertEqual(recorded.query["scope"], "profile_device")
        XCTAssertEqual(recorded.header("X-Silo-Mutation-Id"), mutationId)
        // The trap this guards: scope=profile_device is rejected without the
        // profile header, which the client previously never sent.
        XCTAssertEqual(recorded.header("X-Profile-Id"), Self.stubProfileId)
        XCTAssertEqual(recorded.header("X-Silo-Device-Id")?.isEmpty, false)
        XCTAssertEqual(
            recorded.header("X-Silo-Client-Family"),
            AppleDeviceIdentity.current.clientFamily
        )
        // And the body must carry the value's keys verbatim.
        let body = String(data: recorded.body ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"fontSize\""), "body must keep camelCase value keys: \(body)")
        XCTAssertFalse(body.contains("font_size"))
    }

    func testPutValueExplicitProfileOverridesTheCurrentSessionHeader() async throws {
        SettingsStubProtocol.reset(mode: .normal)
        let api = await makeStubbedAPI(profileId: "new-session-profile")

        _ = try await api.putValue(
            key: .playerHdrEnabled,
            scope: .profileDevice,
            value: false,
            mutationId: newSettingMutationId(),
            profileId: "profile-captured-with-write"
        )

        let recorded = try XCTUnwrap(SettingsStubProtocol.state().lastRequest)
        XCTAssertEqual(
            recorded.header("X-Profile-Id"),
            "profile-captured-with-write",
            "the queued profile must override a newer session header"
        )
    }

    func testCapturedSettingsRequestRefusesToFollowANewActiveIdentity() async throws {
        SettingsStubProtocol.reset(mode: .normal)
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
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsStubProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: config), tokenStore: tokenStore)
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
                path: "/api/v1/settings/contract/capabilities",
                requestIdentity: captured
            )
            XCTFail("a captured server/profile request must fail rather than follow the new session")
        } catch HTTPError.requestIdentityChanged {
            // Expected: no URL request was built or sent.
        }
        XCTAssertNil(SettingsStubProtocol.state().lastRequest)
    }

    func testConcurrentScopedUnauthorizedResponsesShareOneRotatingRefresh() async throws {
        SettingsStubProtocol.reset(mode: .concurrentScopedRefresh)
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

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsStubProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: config), tokenStore: tokenStore)
        async let first = http.requestData(
            method: "GET",
            path: "/api/v1/settings/contract/capabilities",
            requestIdentity: identity
        )
        async let second = http.requestData(
            method: "GET",
            path: "/api/v1/settings/contract/capabilities",
            requestIdentity: identity
        )

        let (firstResponse, secondResponse) = try await (first, second)

        XCTAssertEqual(firstResponse.statusCode, 200)
        XCTAssertEqual(secondResponse.statusCode, 200)
        let state = SettingsStubProtocol.state()
        XCTAssertEqual(state.requestCounts["/api/v1/auth/refresh"], 1)
        XCTAssertEqual(state.requestCounts["/api/v1/settings/contract/capabilities"], 4)
        let accessToken = await tokenStore.getAccessToken()
        let refreshToken = await tokenStore.getRefreshToken()
        XCTAssertEqual(accessToken, "placeholder")
        XCTAssertEqual(refreshToken, "redacted")
    }

    func testScopedAndOrdinaryUnauthorizedResponsesShareAccountRefreshFlight() async throws {
        SettingsStubProtocol.reset(mode: .mixedRefreshScopedWins)
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

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsStubProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: config), tokenStore: tokenStore)
        let sessionExpiredCount = observeSessionExpiry()

        async let scoped = http.requestData(
            method: "GET",
            path: "/api/v1/settings/contract/capabilities",
            headers: ["X-Test-Refresh-Flow": "scoped"],
            requestIdentity: identity
        )
        async let ordinary = http.requestData(
            method: "GET",
            path: "/api/v1/settings/contract/capabilities",
            headers: ["X-Test-Refresh-Flow": "ordinary"]
        )

        let (scopedResponse, ordinaryResponse) = try await (scoped, ordinary)

        XCTAssertEqual(scopedResponse.statusCode, 200)
        XCTAssertEqual(ordinaryResponse.statusCode, 200)
        let state = SettingsStubProtocol.state()
        XCTAssertEqual(state.requestCounts["/api/v1/auth/refresh"], 1)
        XCTAssertEqual(state.requestCounts["/api/v1/settings/contract/capabilities"], 4)
        let accessToken = await tokenStore.getAccessToken()
        let refreshToken = await tokenStore.getRefreshToken()
        XCTAssertEqual(accessToken, "placeholder")
        XCTAssertEqual(refreshToken, "redacted")
        XCTAssertEqual(sessionExpiredCount.value, 0)
    }

    func testFailedScopedRefreshExpiresOrdinaryJoinerWithoutAnonymousRetry() async throws {
        SettingsStubProtocol.reset(mode: .mixedRefreshScopedFailure)
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

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsStubProtocol.self]
        let ordinaryJoinCount = LockedCounter()
        let http = HTTPClient(
            session: URLSession(configuration: config),
            tokenStore: tokenStore,
            refreshFlightJoinObserver: { kind in
                if case .ordinary = kind {
                    ordinaryJoinCount.increment()
                }
            }
        )
        let sessionExpiredCount = observeSessionExpiry()

        async let scoped: HTTPRawResponse = http.requestData(
            method: "GET",
            path: "/api/v1/settings/contract/capabilities",
            headers: ["X-Test-Refresh-Flow": "scoped"],
            requestIdentity: identity
        )
        async let ordinary: HTTPRawResponse = http.requestData(
            method: "GET",
            path: "/api/v1/settings/contract/capabilities",
            headers: ["X-Test-Refresh-Flow": "ordinary"]
        )

        defer { SettingsStubProtocol.releaseMixedRefresh() }
        guard await waitUntil({ ordinaryJoinCount.value >= 1 }) else {
            return XCTFail("the ordinary 401 never joined the scoped-owned refresh flight")
        }
        SettingsStubProtocol.releaseMixedRefresh()

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

        let state = SettingsStubProtocol.state()
        XCTAssertEqual(state.requestCounts["/api/v1/auth/refresh"], 1)
        XCTAssertEqual(state.requestCounts["/api/v1/settings/contract/capabilities"], 2)
        let accessToken = await tokenStore.getAccessToken()
        let refreshToken = await tokenStore.getRefreshToken()
        XCTAssertNil(accessToken)
        XCTAssertNil(refreshToken)
        XCTAssertEqual(sessionExpiredCount.value, 1)
    }

    func testTransientScopedRefreshFailurePreservesCredentialsWithoutExpiryAndCanRetry() async throws {
        let harness = try await makeRefreshHarness(testName: "TransientRefresh")
        let sessionExpiredCount = observeSessionExpiry()

        for status in [429, 503] {
            SettingsStubProtocol.reset(mode: .mixedRefreshScopedTransientFailure(status: status))
            async let scoped: HTTPRawResponse = harness.http.requestData(
                method: "GET",
                path: "/api/v1/settings/contract/capabilities",
                headers: ["X-Test-Refresh-Flow": "scoped"],
                requestIdentity: harness.identity
            )
            async let ordinary: HTTPRawResponse = harness.http.requestData(
                method: "GET",
                path: "/api/v1/settings/contract/capabilities",
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

            let state = SettingsStubProtocol.state()
            XCTAssertEqual(state.requestCounts["/api/v1/auth/refresh"], 1)
            XCTAssertEqual(state.requestCounts["/api/v1/settings/contract/capabilities"], 2)
            let accessToken = await harness.tokenStore.getAccessToken()
            let refreshToken = await harness.tokenStore.getRefreshToken()
            XCTAssertEqual(accessToken, "fake", "HTTP \(status) must preserve the access token")
            XCTAssertEqual(refreshToken, "dummy", "HTTP \(status) must preserve the refresh token")
            XCTAssertEqual(sessionExpiredCount.value, 0)
        }

        // A later 401 wave must be able to submit the preserved refresh token
        // and rotate the account credentials normally.
        SettingsStubProtocol.reset(mode: .mixedRefreshScopedWins)
        let retried = try await harness.http.requestData(
            method: "GET",
            path: "/api/v1/settings/contract/capabilities",
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
        SettingsStubProtocol.reset(mode: .mixedRefreshScopedMalformedSuccess)
        let harness = try await makeRefreshHarness(testName: "MalformedRefresh")
        let sessionExpiredCount = observeSessionExpiry()
        await MainActor.run {
            ConnectionMonitor.shared.noteServerResponded()
        }

        async let scoped: HTTPRawResponse = harness.http.requestData(
            method: "GET",
            path: "/api/v1/settings/contract/capabilities",
            headers: ["X-Test-Refresh-Flow": "scoped"],
            requestIdentity: harness.identity
        )
        async let ordinary: HTTPRawResponse = harness.http.requestData(
            method: "GET",
            path: "/api/v1/settings/contract/capabilities",
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
        SettingsStubProtocol.reset(mode: .ordinaryUnauthorizedDelayed)
        let harness = try await makeRefreshHarness(testName: "UnauthorizedServerSwitch")

        let requestTask = Task {
            try await harness.http.requestData(
                method: "GET",
                path: "/api/v1/settings/contract/capabilities"
            )
        }
        guard await waitUntil({ SettingsStubProtocol.hasPendingOrdinaryUnauthorized() }) else {
            SettingsStubProtocol.releaseOrdinaryUnauthorized()
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
        SettingsStubProtocol.releaseOrdinaryUnauthorized()

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
        let state = SettingsStubProtocol.state()
        XCTAssertEqual(state.requestCounts["/api/v1/auth/refresh"] ?? 0, 0)
        XCTAssertEqual(state.requestCounts["/api/v1/settings/contract/capabilities"], 1)
    }

    func testOrdinaryUnauthorizedResponseCannotRefreshSameServerSessionInstalledAfterLogout() async throws {
        SettingsStubProtocol.reset(mode: .ordinaryUnauthorizedDelayed)
        let harness = try await makeRefreshHarness(testName: "UnauthorizedSameServerRelogin")

        let requestTask = Task {
            try await harness.http.requestData(
                method: "GET",
                path: "/api/v1/settings/contract/capabilities"
            )
        }
        guard await waitUntil({ SettingsStubProtocol.hasPendingOrdinaryUnauthorized() }) else {
            SettingsStubProtocol.releaseOrdinaryUnauthorized()
            return XCTFail("ordinary request did not reach the delayed 401")
        }

        await harness.tokenStore.clearTokens()
        await harness.tokenStore.saveTokens(
            accessToken: "placeholder",
            refreshToken: "redacted"
        )
        await harness.tokenStore.setProfileId(harness.identity.profileId)
        SettingsStubProtocol.releaseOrdinaryUnauthorized()

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
        let state = SettingsStubProtocol.state()
        XCTAssertEqual(state.requestCounts["/api/v1/auth/refresh"] ?? 0, 0)
        XCTAssertEqual(state.requestCounts["/api/v1/settings/contract/capabilities"], 1)
    }

    func testScopedUnauthorizedResponseCannotRefreshSameServerSessionInstalledAfterLogout() async throws {
        SettingsStubProtocol.reset(mode: .ordinaryUnauthorizedDelayed)
        let harness = try await makeRefreshHarness(testName: "ScopedUnauthorizedSameServerRelogin")

        let requestTask = Task {
            try await harness.http.requestData(
                method: "GET",
                path: "/api/v1/settings/contract/capabilities",
                requestIdentity: harness.identity
            )
        }
        guard await waitUntil({ SettingsStubProtocol.hasPendingOrdinaryUnauthorized() }) else {
            SettingsStubProtocol.releaseOrdinaryUnauthorized()
            return XCTFail("scoped request did not reach the delayed 401")
        }

        await harness.tokenStore.clearTokens()
        await harness.tokenStore.saveTokens(
            accessToken: "placeholder",
            refreshToken: "redacted"
        )
        await harness.tokenStore.setProfileId(harness.identity.profileId)
        SettingsStubProtocol.releaseOrdinaryUnauthorized()

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
        let state = SettingsStubProtocol.state()
        XCTAssertEqual(state.requestCounts["/api/v1/auth/refresh"] ?? 0, 0)
        XCTAssertEqual(state.requestCounts["/api/v1/settings/contract/capabilities"], 1)
    }

    func testOrdinaryUnauthorizedResponseCannotRetryAfterProfileSwitch() async throws {
        SettingsStubProtocol.reset(mode: .ordinaryUnauthorizedDelayed)
        let harness = try await makeRefreshHarness(testName: "UnauthorizedProfileSwitch")
        await harness.tokenStore.setProfileToken("decoy-token")

        let requestTask = Task {
            try await harness.http.requestData(
                method: "GET",
                path: "/api/v1/settings/contract/capabilities"
            )
        }
        guard await waitUntil({ SettingsStubProtocol.hasPendingOrdinaryUnauthorized() }) else {
            SettingsStubProtocol.releaseOrdinaryUnauthorized()
            return XCTFail("ordinary request did not reach the delayed 401")
        }

        await harness.tokenStore.setProfileId("profile-b")
        await harness.tokenStore.setProfileToken("gateway-token")
        SettingsStubProtocol.releaseOrdinaryUnauthorized()

        do {
            _ = try await requestTask.value
            XCTFail("the profile-A request must not refresh or retry as profile B")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.statusCode, 401)
        }
        let state = SettingsStubProtocol.state()
        XCTAssertEqual(state.requestCounts["/api/v1/auth/refresh"] ?? 0, 0)
        XCTAssertEqual(state.requestCounts["/api/v1/settings/contract/capabilities"], 1)
        XCTAssertEqual(state.lastRequest?.header("X-Profile-Id"), "profile-a")
        XCTAssertEqual(state.lastRequest?.header("X-Profile-Token"), "decoy-token")
    }

    func testOrdinaryUnauthorizedResponseCannotCrossFromPersistentIntoTemporaryCredentials() async throws {
        SettingsStubProtocol.reset(mode: .ordinaryUnauthorizedDelayed)
        let harness = try await makeRefreshHarness(testName: "PersistentToTemporary")
        await harness.tokenStore.setProfileToken("test-auth-token")

        let requestTask = Task {
            try await harness.http.requestData(
                method: "GET",
                path: "/api/v1/settings/contract/capabilities"
            )
        }
        guard await waitUntil({ SettingsStubProtocol.hasPendingOrdinaryUnauthorized() }) else {
            SettingsStubProtocol.releaseOrdinaryUnauthorized()
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
        SettingsStubProtocol.releaseOrdinaryUnauthorized()

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
        let state = SettingsStubProtocol.state()
        XCTAssertEqual(state.requestCounts["/api/v1/auth/refresh"] ?? 0, 0)
        XCTAssertEqual(state.requestCounts["/api/v1/settings/contract/capabilities"], 1)
    }

    func testOrdinaryUnauthorizedResponseCannotCrossFromTemporaryIntoPersistentCredentials() async throws {
        SettingsStubProtocol.reset(mode: .ordinaryUnauthorizedDelayed)
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
                path: "/api/v1/settings/contract/capabilities"
            )
        }
        guard await waitUntil({ SettingsStubProtocol.hasPendingOrdinaryUnauthorized() }) else {
            SettingsStubProtocol.releaseOrdinaryUnauthorized()
            return XCTFail("temporary request did not reach the delayed 401")
        }

        _ = await harness.tokenStore.endTemporaryScope()
        SettingsStubProtocol.releaseOrdinaryUnauthorized()

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
        let state = SettingsStubProtocol.state()
        XCTAssertEqual(state.requestCounts["/api/v1/auth/refresh"] ?? 0, 0)
        XCTAssertEqual(state.requestCounts["/api/v1/settings/contract/capabilities"], 1)
    }

    func testTemporaryScopedRefreshCommitNeverReachesPersistentKeychainStorage() async throws {
        let suiteName = "settings-refresh-TemporaryOwnerBoundary-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        // Held directly (rather than going through makeRefreshHarness) so the
        // raw stored slots can be asserted on below.
        let backend = InMemoryKeychainBackend()
        let service = "SettingValuesTemporaryOwnerBoundaryTests.\(UUID().uuidString)"
        let keychain = SharedKeychain(service: service, accessGroup: nil, backend: backend)
        let tokenStore = TokenStore(
            keychain: keychain,
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await tokenStore.switchActiveServer(serverId: "server-a")
        await tokenStore.setServerUrl("http://settings-test.invalid")
        await tokenStore.setProfileId("profile-a")
        await tokenStore.saveTokens(accessToken: "fake", refreshToken: "dummy")

        XCTAssertEqual(
            backend.value(service: service, accessGroup: nil, account: TokenStore.accessTokenKey(for: "server-a")),
            "fake"
        )
        XCTAssertEqual(
            backend.value(service: service, accessGroup: nil, account: TokenStore.refreshTokenKey(for: "server-a")),
            "dummy"
        )

        // Scenario A: scope active — a temporary-owner commit mutates only
        // the scope, never the persistent keychain slots.
        let temporary = TemporaryAuthScope(
            serverId: "server-a",
            serverURL: "http://settings-test.invalid",
            accessToken: "example",
            // Match the persistent value so credential provenance, rather
            // than value inequality, is what prevents the write.
            refreshToken: "dummy",
            profileId: "temporary-profile",
            profileToken: "secret-token",
            controllerDeviceId: "controller",
            expiresAt: Date().addingTimeInterval(60)
        )
        await tokenStore.beginTemporaryScope(temporary)

        let expectedIdentity = await tokenStore.refreshAccountIdentity()
        let expected = try XCTUnwrap(expectedIdentity)
        let capturedCredential = await tokenStore.captureRefreshCredential(expected: expected)
        let captured = try XCTUnwrap(capturedCredential)
        XCTAssertEqual(captured.owner, .temporary)

        let stored = await tokenStore.saveRefreshedTokens(
            "rotated-access",
            "rotated-refresh",
            replacing: captured
        )
        XCTAssertTrue(stored)

        let scopeAfterCommit = await tokenStore.getTemporaryScope()
        XCTAssertEqual(scopeAfterCommit?.accessToken, "rotated-access")
        XCTAssertEqual(scopeAfterCommit?.refreshToken, "rotated-refresh")

        XCTAssertEqual(
            backend.value(service: service, accessGroup: nil, account: TokenStore.accessTokenKey(for: "server-a")),
            "fake"
        )
        XCTAssertEqual(
            backend.value(service: service, accessGroup: nil, account: TokenStore.refreshTokenKey(for: "server-a")),
            "dummy"
        )

        _ = await tokenStore.endTemporaryScope()
        let accessAfterEnd = await tokenStore.getAccessToken()
        let refreshAfterEnd = await tokenStore.getRefreshToken()
        XCTAssertEqual(accessAfterEnd, "fake")
        XCTAssertEqual(refreshAfterEnd, "dummy")

        // Scenario B: the scope ends between capture and save, so the commit
        // must be refused outright rather than falling through to the
        // persistent account.
        let temporary2 = TemporaryAuthScope(
            serverId: "server-a",
            serverURL: "http://settings-test.invalid",
            accessToken: "example",
            // Same value-collision trap as above.
            refreshToken: "dummy",
            profileId: "temporary-profile",
            profileToken: "secret-token",
            controllerDeviceId: "controller",
            expiresAt: Date().addingTimeInterval(60)
        )
        await tokenStore.beginTemporaryScope(temporary2)

        let expectedIdentity2 = await tokenStore.refreshAccountIdentity()
        let expected2 = try XCTUnwrap(expectedIdentity2)
        let capturedCredential2 = await tokenStore.captureRefreshCredential(expected: expected2)
        let captured2 = try XCTUnwrap(capturedCredential2)
        XCTAssertEqual(captured2.owner, .temporary)

        _ = await tokenStore.endTemporaryScope()

        // With the captured refresh token equal to the persistent one, only
        // the captured owner/generation — not value inequality — prevents
        // this from redirecting into the persistent slot.
        let storedLate = await tokenStore.saveRefreshedTokens(
            "intruder-access",
            "intruder-refresh",
            replacing: captured2
        )
        XCTAssertFalse(storedLate)

        let accessAfterLate = await tokenStore.getAccessToken()
        let refreshAfterLate = await tokenStore.getRefreshToken()
        XCTAssertEqual(accessAfterLate, "fake")
        XCTAssertEqual(refreshAfterLate, "dummy")
        let scopeAfterLate = await tokenStore.getTemporaryScope()
        XCTAssertNil(scopeAfterLate)
        XCTAssertEqual(
            backend.value(service: service, accessGroup: nil, account: TokenStore.accessTokenKey(for: "server-a")),
            "fake"
        )
        XCTAssertEqual(
            backend.value(service: service, accessGroup: nil, account: TokenStore.refreshTokenKey(for: "server-a")),
            "dummy",
            "credentials captured from a temporary scope must never redirect into persistent storage"
        )
    }

    func testRejectedTemporaryGenerationRefreshesAndExpiresOnlyOnce() async throws {
        SettingsStubProtocol.reset(mode: .temporaryRefreshRejected)
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
                    path: "/api/v1/settings/contract/capabilities"
                )
                XCTFail("temporary 401 wave \(wave) must remain unauthorized")
            } catch {
                XCTAssertEqual((error as? HTTPError)?.statusCode, 401)
            }
        }

        let state = SettingsStubProtocol.state()
        XCTAssertEqual(state.requestCounts["/api/v1/auth/refresh"], 1)
        XCTAssertEqual(state.requestCounts["/api/v1/settings/contract/capabilities"], 2)
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
        SettingsStubProtocol.reset(mode: .temporaryRefreshRejected)
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
                path: "/api/v1/settings/contract/capabilities",
                requestIdentity: harness.identity
            )
            XCTFail("the scoped temporary request must remain unauthorized")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.statusCode, 401)
        }

        let state = SettingsStubProtocol.state()
        XCTAssertEqual(state.requestCounts["/api/v1/auth/refresh"], 1)
        XCTAssertEqual(state.requestCounts["/api/v1/settings/contract/capabilities"], 1)
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
        SettingsStubProtocol.reset(mode: .mixedRefreshScopedWins)
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
            path: "/api/v1/settings/contract/capabilities",
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
        let state = SettingsStubProtocol.state()
        XCTAssertEqual(state.requestCounts["/api/v1/auth/refresh"], 1)
        XCTAssertEqual(state.requestCounts["/api/v1/settings/contract/capabilities"], 2)
    }

    func testPersistentExpiryEventIsRejectedAfterSameServerSessionReplacement() async throws {
        SettingsStubProtocol.reset(mode: .normal)
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
        SettingsStubProtocol.reset(mode: .normal)
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
        SettingsStubProtocol.reset(mode: .normal)
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
        SettingsStubProtocol.reset(mode: .normal)
        let harness = try await makeRefreshHarness(testName: "SerializedIdentityCancellation")
        let barrier = SerializedCancellationPassBarrier()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsStubProtocol.self]
        let http = HTTPClient(
            session: URLSession(configuration: config),
            tokenStore: harness.tokenStore,
            cancellationPassBarrier: { await barrier.enter() }
        )

        // Model an old end already enumerating URLSession work when a
        // replacement activation begins its own cancellation pass.
        let oldEnd = Task { await http.cancelInFlightRequests() }
        guard await waitUntil({ await barrier.entryCount >= 1 }) else {
            return XCTFail("old-generation cancellation pass did not start")
        }
        let replacement = Task {
            await http.cancelInFlightRequests()
            return try await http.requestData(
                method: "GET",
                path: "/api/v1/settings/contract/capabilities"
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
            SettingsStubProtocol.state().requestCounts["/api/v1/settings/contract/capabilities"] ?? 0,
            0,
            "replacement work must not start while an old cancellation can still enumerate it"
        )

        await barrier.release(pass: 1)
        await oldEnd.value
        guard await waitUntil({ await barrier.entryCount >= 2 }) else {
            return XCTFail("replacement cancellation pass did not start after the old pass")
        }
        XCTAssertEqual(
            SettingsStubProtocol.state().requestCounts["/api/v1/settings/contract/capabilities"] ?? 0,
            0
        )
        await barrier.release(pass: 2)

        let response = try await replacement.value
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(
            SettingsStubProtocol.state().requestCounts["/api/v1/settings/contract/capabilities"],
            1
        )
    }

    func testScopedRefreshCannotRetryAsSameServerReplacementInstalledAfterRefresh() async throws {
        SettingsStubProtocol.reset(mode: .mixedRefreshScopedWins)
        let harness = try await makeRefreshHarness(testName: "ScopedPostRefreshReplacement")
        let barrier = SerializedCancellationPassBarrier()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsStubProtocol.self]
        let http = HTTPClient(
            session: URLSession(configuration: config),
            tokenStore: harness.tokenStore,
            scopedRefreshRetryBarrier: { await barrier.enter() }
        )

        let request = Task {
            try await http.requestData(
                method: "GET",
                path: "/api/v1/settings/contract/capabilities",
                headers: ["X-Test-Refresh-Flow": "scoped"],
                requestIdentity: harness.identity
            )
        }
        guard await waitUntil({ await barrier.entryCount >= 1 }) else {
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
        let state = SettingsStubProtocol.state()
        XCTAssertEqual(state.requestCounts["/api/v1/auth/refresh"], 1)
        XCTAssertEqual(state.requestCounts["/api/v1/settings/contract/capabilities"], 1)
    }

    func testCancelledTemporaryReplacementRestoresPriorOwnerGeneration() async throws {
        SettingsStubProtocol.reset(mode: .normal)
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
        guard await waitUntil({ await barrier.entryCount >= 1 }) else {
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
        SettingsStubProtocol.reset(mode: .normal)
        let harness = try await makeRefreshHarness(testName: "CancellationSnapshotGate")
        let barrier = SerializedCancellationPassBarrier()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsStubProtocol.self]
        let http = HTTPClient(
            session: URLSession(configuration: config),
            tokenStore: harness.tokenStore,
            cancellationSessionBarrier: { index in
                if index == 1 { await barrier.enter() }
            }
        )

        let cancellation = Task { await http.cancelInFlightRequests() }
        guard await waitUntil({ await barrier.entryCount >= 1 }) else {
            return XCTFail("cancellation did not pause between session snapshots")
        }
        do {
            _ = try await http.requestData(
                method: "GET",
                path: "/api/v1/settings/contract/capabilities"
            )
            XCTFail("dispatch must remain closed between cancellation snapshots")
        } catch HTTPError.requestIdentityChanged {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(
            SettingsStubProtocol.state().requestCounts["/api/v1/settings/contract/capabilities"] ?? 0,
            0
        )
        await barrier.release(pass: 1)
        await cancellation.value
    }

    func testPublishedServerHydrationWaitsUntilCancellationAndTransitionAreOpen() async throws {
        SettingsStubProtocol.reset(mode: .normal)
        let harness = try await makeRefreshHarness(testName: "PublishedServerHydrationGate")
        let cancellationBarrier = SerializedCancellationPassBarrier()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsStubProtocol.self]
        let http = HTTPClient(
            session: URLSession(configuration: config),
            tokenStore: harness.tokenStore,
            cancellationPassBarrier: { await cancellationBarrier.enter() }
        )
        guard let lease = await http.beginIdentityTransition() else {
            return XCTFail("identity transition was unexpectedly cancelled")
        }

        let cancellation = Task { await http.cancelInFlightRequests() }
        guard await waitUntil({ await cancellationBarrier.entryCount >= 1 }) else {
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
        guard await waitUntil({ await http.pendingRequestDispatchWaiterCount() > 0 }) else {
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
        SettingsStubProtocol.reset(mode: .normal)
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
        guard await waitUntil({ await harness.http.pendingRequestDispatchWaiterCount() > 0 }) else {
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
        SettingsStubProtocol.reset(mode: .normal)
        let harness = try await makeRefreshHarness(testName: "CaptureDuringRetarget")
        let barrier = SerializedCancellationPassBarrier()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsStubProtocol.self]
        let http = HTTPClient(
            session: URLSession(configuration: config),
            tokenStore: harness.tokenStore,
            requestCaptureBarrier: { await barrier.enter() }
        )

        let request = Task {
            try await http.requestData(
                method: "GET",
                path: "/api/v1/settings/contract/capabilities"
            )
        }
        guard await waitUntil({ await barrier.entryCount >= 1 }) else {
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
        XCTAssertNil(SettingsStubProtocol.state().lastRequest)
    }

    func testCompletedResponseIsRejectedWhenIdentityTransitionsBeforeDelivery() async throws {
        SettingsStubProtocol.reset(mode: .normal)
        let harness = try await makeRefreshHarness(testName: "ResponseDuringTransition")
        let barrier = SerializedCancellationPassBarrier()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsStubProtocol.self]
        let http = HTTPClient(
            session: URLSession(configuration: config),
            tokenStore: harness.tokenStore,
            responseReceivedBarrier: { await barrier.enter() }
        )

        let request = Task {
            try await http.requestData(
                method: "GET",
                path: "/api/v1/settings/contract/capabilities"
            )
        }
        guard await waitUntil({ await barrier.entryCount >= 1 }) else {
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
        XCTAssertEqual(
            SettingsStubProtocol.state().requestCounts["/api/v1/settings/contract/capabilities"],
            1
        )
    }

    func testCandidateProbeDoesNotChangeActiveServerReachability() async throws {
        SettingsStubProtocol.reset(mode: .normal)
        let harness = try await makeRefreshHarness(testName: "CandidateReachabilityIsolation")
        await MainActor.run { ConnectionMonitor.shared.noteServerUnreachable() }

        let health: HealthStatus = try await harness.http.getUnauthenticated(
            serverURL: harness.identity.serverURL,
            path: "/api/v1/health"
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
        SettingsStubProtocol.reset(mode: .normal)
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
        guard await waitUntil({ await harness.http.pendingIdentityTransitionCount() > 0 }) else {
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
        SettingsStubProtocol.reset(mode: .normal)
        let harness = try await makeRefreshHarness(testName: "BoundLogoutServerSwitch")
        let accountValue = await harness.tokenStore.refreshAccountIdentity()
        let account = try XCTUnwrap(accountValue)
        let barrier = SerializedCancellationPassBarrier()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsStubProtocol.self]
        let http = HTTPClient(
            session: URLSession(configuration: config),
            tokenStore: harness.tokenStore,
            requestCaptureBarrier: { await barrier.enter() }
        )

        let logout = Task {
            try await http.postVoid(
                "/api/v1/auth/logout",
                expectedAccount: account
            )
        }
        guard await waitUntil({ await barrier.entryCount >= 1 }) else {
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
        XCTAssertEqual(SettingsStubProtocol.state().requestCounts["/api/v1/auth/logout"] ?? 0, 0)
        let currentAccess = await harness.tokenStore.getAccessToken()
        XCTAssertEqual(currentAccess, "example")
    }

    func testOrdinaryRefreshLateSuccessCannotWriteAcrossServerSwitch() async throws {
        SettingsStubProtocol.reset(mode: .ordinaryRefreshDelayed)
        let harness = try await makeRefreshHarness(testName: "RefreshServerSwitch")
        let sessionExpiredCount = observeSessionExpiry()

        let requestTask = Task {
            try await harness.http.requestData(
                method: "GET",
                path: "/api/v1/settings/contract/capabilities"
            )
        }
        guard await waitUntil({ SettingsStubProtocol.hasPendingOrdinaryRefresh() }) else {
            SettingsStubProtocol.releaseOrdinaryRefresh(status: 503)
            return XCTFail("ordinary refresh did not reach the delayed response")
        }

        await harness.tokenStore.switchActiveServer(serverId: "server-b")
        await harness.tokenStore.setServerUrl("http://settings-test.invalid/server-b")
        await harness.tokenStore.setProfileId("profile-b")
        await harness.tokenStore.saveTokens(
            accessToken: "example",
            refreshToken: "sample"
        )
        SettingsStubProtocol.releaseOrdinaryRefresh(status: 200)

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
        let state = SettingsStubProtocol.state()
        XCTAssertEqual(state.requestCounts["/api/v1/auth/refresh"], 1)
        XCTAssertEqual(state.requestCounts["/api/v1/settings/contract/capabilities"], 1)
    }

    func testOrdinaryRefreshLateSuccessCannotRestoreSignedOutSession() async throws {
        SettingsStubProtocol.reset(mode: .ordinaryRefreshDelayed)
        let harness = try await makeRefreshHarness(testName: "RefreshSignOut")
        let sessionExpiredCount = observeSessionExpiry()

        let requestTask = Task {
            try await harness.http.requestData(
                method: "GET",
                path: "/api/v1/settings/contract/capabilities"
            )
        }
        guard await waitUntil({ SettingsStubProtocol.hasPendingOrdinaryRefresh() }) else {
            SettingsStubProtocol.releaseOrdinaryRefresh(status: 503)
            return XCTFail("ordinary refresh did not reach the delayed response")
        }

        await harness.tokenStore.clearTokens()
        SettingsStubProtocol.releaseOrdinaryRefresh(status: 200)

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
        SettingsStubProtocol.reset(mode: .ordinaryRefreshDelayed)
        let harness = try await makeRefreshHarness(testName: "RefreshNewerToken")
        let sessionExpiredCount = observeSessionExpiry()

        let requestTask = Task {
            try await harness.http.requestData(
                method: "GET",
                path: "/api/v1/settings/contract/capabilities"
            )
        }
        guard await waitUntil({ SettingsStubProtocol.hasPendingOrdinaryRefresh() }) else {
            SettingsStubProtocol.releaseOrdinaryRefresh(status: 503)
            return XCTFail("ordinary refresh did not reach the delayed response")
        }

        await harness.tokenStore.saveTokens(
            accessToken: "placeholder",
            refreshToken: "redacted"
        )
        SettingsStubProtocol.releaseOrdinaryRefresh(status: 403)

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
        let state = SettingsStubProtocol.state()
        XCTAssertEqual(state.requestCounts["/api/v1/auth/refresh"], 1)
        XCTAssertEqual(state.requestCounts["/api/v1/settings/contract/capabilities"], 1)
    }

    func testPutNavigationShortcutItemSendsAtomicBodyMutationAndProfileHeaders() async throws {
        SettingsStubProtocol.reset(mode: .normal)
        let api = await makeStubbedAPI()
        let mutationId = newSettingMutationId()
        let item = PrimaryMenuItem.section(
            libraryId: 7,
            sectionId: "recently-added",
            label: "Recently Added"
        )

        let receipt = try await api.putNavigationShortcutItem(
            item,
            present: true,
            mutationId: mutationId
        )

        XCTAssertEqual(receipt.value.settingKey, .navShortcuts)
        XCTAssertEqual(
            try receipt.value.value.decoded(as: NavigationShortcutsPreference.self),
            NavigationShortcutsPreference(items: [item])
        )

        let recorded = try XCTUnwrap(SettingsStubProtocol.state().lastRequest)
        XCTAssertEqual(recorded.method, "PUT")
        XCTAssertEqual(recorded.path, "/api/v1/settings/values/nav.shortcuts/item")
        XCTAssertTrue(recorded.query.isEmpty)
        XCTAssertEqual(recorded.header("X-Silo-Mutation-Id"), mutationId)
        XCTAssertEqual(recorded.header("X-Profile-Id"), Self.stubProfileId)

        let body = try XCTUnwrap(recorded.body)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["present"] as? Bool, true)
        let encodedItem = try XCTUnwrap(object["item"] as? [String: Any])
        XCTAssertEqual(encodedItem["type"] as? String, "section")
        XCTAssertEqual(encodedItem["library_id"] as? Int, 7)
        XCTAssertEqual(encodedItem["section_id"] as? String, "recently-added")
        XCTAssertEqual(encodedItem["label"] as? String, "Recently Added")
    }

    func testPutNavigationShortcutItemRejectsBuiltinsBeforeSending() async throws {
        SettingsStubProtocol.reset(mode: .normal)
        let api = await makeStubbedAPI()

        do {
            _ = try await api.putNavigationShortcutItem(
                .builtin(.home),
                present: true,
                mutationId: newSettingMutationId()
            )
            XCTFail("built-in destinations are not valid nav.shortcuts items")
        } catch let error as SettingsAPIError {
            guard case .invalidValue = error else {
                return XCTFail("expected a local invalid-value error, got \(error)")
            }
        }

        XCTAssertNil(SettingsStubProtocol.state().lastRequest)
    }

    func testPutValueSurfacesAnIdempotentReplay() async throws {
        SettingsStubProtocol.reset(mode: .idempotentReplay)
        let api = await makeStubbedAPI()

        let receipt = try await api.putValue(
            key: .playbackPreferredQuality,
            scope: .profile,
            value: "2160p",
            mutationId: "11111111-1111-1111-1111-111111111111"
        )
        XCTAssertTrue(receipt.isIdempotentReplay, "a replayed receipt must be distinguishable")
        XCTAssertEqual(receipt.value.value, .string("2160p"))
    }

    func testPutValueRejectsABlankMutationIdBeforeSendingARequest() async throws {
        SettingsStubProtocol.reset(mode: .normal)
        let api = await makeStubbedAPI()

        do {
            _ = try await api.putValue(
                key: .playbackPreferredQuality,
                scope: .profile,
                value: "1080p",
                mutationId: "  \n\t"
            )
            XCTFail("a blank mutation id must not silently disable idempotency")
        } catch let error as SettingsAPIError {
            guard case .invalidValue = error else {
                return XCTFail("expected a local invalid-value error, got \(error)")
            }
        }

        XCTAssertNil(
            SettingsStubProtocol.state().lastRequest,
            "local mutation-id validation must run before any network activity"
        )
    }

    func testGetEffectiveValuesSendsBatchedQueryParams() async throws {
        SettingsStubProtocol.reset(mode: .normal)
        let api = await makeStubbedAPI()

        let response = try await api.getEffectiveValues(
            keys: [.playbackSubtitleLanguage, .playbackAutoPlayNext],
            libraryIds: [7, 9],
            seriesIds: ["s-101"]
        )
        XCTAssertEqual(response.revision, SettingKey.revision)

        let recorded = try XCTUnwrap(SettingsStubProtocol.state().lastRequest)
        XCTAssertEqual(recorded.query["keys"], "playback.subtitle_language,playback.auto_play_next")
        XCTAssertEqual(recorded.query["library_ids"], "7,9")
        XCTAssertEqual(recorded.query["series_ids"], "s-101")
        XCTAssertEqual(recorded.header("X-Profile-Id"), Self.stubProfileId)
    }

    func testGetEffectiveValuesRejectsAnOlderContractRevision() async throws {
        SettingsStubProtocol.reset(mode: .olderContractRevision)
        let api = await makeStubbedAPI()

        do {
            _ = try await api.getEffectiveValues(keys: [.playbackSubtitleLanguage])
            XCTFail("a client must not apply an effective response from an older contract")
        } catch let error as SettingsAPIError {
            XCTAssertEqual(error, .serverUpgradeRequired)
        }
    }

    func testGetEffectiveValuesOmitsEmptyParams() async throws {
        SettingsStubProtocol.reset(mode: .normal)
        let api = await makeStubbedAPI()

        _ = try await api.getEffectiveValues()

        let recorded = try XCTUnwrap(SettingsStubProtocol.state().lastRequest)
        XCTAssertNil(recorded.query["keys"], "no keys means every remote definition, not keys=")
        XCTAssertNil(recorded.query["library_ids"])
        XCTAssertNil(recorded.query["series_ids"])
    }

    func testDeleteValueSendsTheScopeAndMapsAMissingRow() async throws {
        SettingsStubProtocol.reset(mode: .normal)
        let api = await makeStubbedAPI()

        try await api.deleteValue(key: .playbackSubtitleLanguage, scope: .profileLibrary(libraryId: 7))
        let recorded = try XCTUnwrap(SettingsStubProtocol.state().lastRequest)
        XCTAssertEqual(recorded.method, "DELETE")
        XCTAssertEqual(recorded.query["scope"], "profile_library")
        XCTAssertEqual(recorded.query["library_id"], "7")

        SettingsStubProtocol.reset(mode: .nothingStored)
        do {
            try await api.deleteValue(key: .playbackSubtitleLanguage, scope: .profile)
            XCTFail("clearing an unset scope must surface as .noValueAtScope")
        } catch let error as SettingsAPIError {
            XCTAssertEqual(error, .noValueAtScope)
        }
    }

    func testProfileScopedCallWithoutAProfileFailsLocally() async throws {
        SettingsStubProtocol.reset(mode: .normal)
        let api = await makeStubbedAPI(profileId: nil)

        do {
            _ = try await api.getEffectiveValues(keys: [.playbackAutoPlayNext])
            XCTFail("a values call with no profile must not reach the server")
        } catch let error as SettingsAPIError {
            XCTAssertEqual(error, .profileRequired)
        }
        XCTAssertNil(SettingsStubProtocol.state().lastRequest, "the request must not be sent at all")
    }

    // MARK: - Harness

    static let stubProfileId = "profile-under-test"

    /// A SiloAPI whose HTTPClient talks to SettingsStubProtocol, with a
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
        await tokenStore.setServerUrl("http://settings-test.invalid")
        await tokenStore.setProfileId(profileId)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsStubProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: config), tokenStore: tokenStore)
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
        // Memory-backed: the unsigned simulator test host cannot reach the
        // Keychain, and these cases are about credential *routing*, not about
        // `SecItem`. Without it a profile proof never lands and the request
        // headers under assertion go out empty.
        let tokenStore = TokenStore(
            keychain: SharedKeychain(
                service: "SettingValues\(testName)Tests.\(UUID().uuidString)",
                accessGroup: nil,
                backend: InMemoryKeychainBackend()
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

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsStubProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: config), tokenStore: tokenStore)
        return (tokenStore, identity, http)
    }

    private func observeSessionExpiry() -> LockedCounter {
        let sessionExpiredCount = LockedCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .siloSessionExpired,
            object: nil,
            queue: nil
        ) { _ in
            sessionExpiredCount.increment()
        }
        addTeardownBlock { NotificationCenter.default.removeObserver(observer) }
        return sessionExpiredCount
    }
}

/// In-process stub for the canonical settings endpoints. State is static
/// because URLSession instantiates the protocol itself; `reset` scopes it per
/// test.
final class SettingsStubProtocol: URLProtocol {
    enum Mode: Equatable {
        /// A server that speaks the canonical settings API.
        case normal
        /// A server predating it: the router 404s with no Silo envelope.
        case serverTooOld
        /// A server with the canonical routes but an older manifest revision.
        case olderContractRevision
        /// A write whose mutation id the server already applied.
        case idempotentReplay
        /// A delete addressing a scope with no stored value.
        case nothingStored
        /// Two expired scoped requests race one rotating account refresh.
        case concurrentScopedRefresh
        /// A scoped request owns refresh while an ordinary 401 joins it.
        case mixedRefreshScopedWins
        /// A scoped-owned refresh rejects while an ordinary 401 joins it.
        case mixedRefreshScopedFailure
        /// A scoped-owned refresh receives a retryable 429 or 5xx response.
        case mixedRefreshScopedTransientFailure(status: Int)
        /// A scoped-owned refresh receives HTTP 200 with an invalid token body.
        case mixedRefreshScopedMalformedSuccess
        /// An ordinary request's refresh waits for an explicit test release.
        case ordinaryRefreshDelayed
        /// An ordinary request's initial 401 waits across a server switch.
        case ordinaryUnauthorizedDelayed
        /// A temporary credential generation is terminally rejected.
        case temporaryRefreshRejected
    }

    struct RecordedRequest {
        let method: String
        let path: String
        let query: [String: String]
        /// Names are lowercased, because URLSession is free to normalize
        /// header casing and an assertion must not depend on it.
        let headers: [String: String]
        let body: Data?

        func header(_ name: String) -> String? {
            headers[name.lowercased()]
        }
    }

    struct State {
        var mode: Mode = .normal
        var lastRequest: RecordedRequest?
        var requestCounts: [String: Int] = [:]
    }

    private static let lock = NSLock()
    private static var current = State()
    private static var pendingConcurrentUnauthorized: [SettingsStubProtocol] = []
    private static var pendingMixedOrdinaryUnauthorized: SettingsStubProtocol?
    private static var pendingOrdinaryRefresh: SettingsStubProtocol?
    private static var pendingOrdinaryUnauthorized: SettingsStubProtocol?
    private static var pendingMixedRefresh: (
        request: SettingsStubProtocol,
        status: Int,
        body: String
    )?
    private static var mixedRefreshStarted = false
    private static var ordinaryUnauthorizedReleased = false

    static func reset(mode: Mode) {
        lock.lock()
        current = State(mode: mode)
        pendingConcurrentUnauthorized.removeAll()
        pendingMixedOrdinaryUnauthorized = nil
        pendingOrdinaryRefresh = nil
        pendingOrdinaryUnauthorized = nil
        pendingMixedRefresh = nil
        mixedRefreshStarted = false
        ordinaryUnauthorizedReleased = false
        lock.unlock()
    }

    static func state() -> State {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    static func hasPendingOrdinaryRefresh() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingOrdinaryRefresh != nil
    }

    static func releaseOrdinaryRefresh(status: Int) {
        let pending: SettingsStubProtocol?
        lock.lock()
        pending = pendingOrdinaryRefresh
        pendingOrdinaryRefresh = nil
        lock.unlock()

        let body: String
        if (200..<300).contains(status) {
            body = #"{"access_token":"placeholder","refresh_token":"redacted","expires_in":3600}"#
        } else {
            body = #"{"error":"invalid_token"}"#
        }
        pending?.respond(status: status, body: body)
    }

    static func hasPendingOrdinaryUnauthorized() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingOrdinaryUnauthorized != nil
    }

    static func releaseOrdinaryUnauthorized() {
        let pending: SettingsStubProtocol?
        lock.lock()
        pending = pendingOrdinaryUnauthorized
        pendingOrdinaryUnauthorized = nil
        ordinaryUnauthorizedReleased = true
        lock.unlock()
        pending?.respond(status: 401, body: #"{"error":"unauthorized"}"#)
    }

    static func releaseMixedRefresh() {
        let pending: (request: SettingsStubProtocol, status: Int, body: String)?
        lock.lock()
        pending = pendingMixedRefresh
        pendingMixedRefresh = nil
        lock.unlock()
        guard let pending else { return }
        pending.request.respond(status: pending.status, body: pending.body)
    }

    private static func mutate(_ apply: (inout State) -> Void) {
        lock.lock()
        apply(&current)
        lock.unlock()
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "settings-test.invalid"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "",
            path: components?.path ?? "",
            query: query,
            headers: Self.lowercasedHeaders(request.allHTTPHeaderFields ?? [:]),
            body: request.drainedHTTPBody
        )
        Self.mutate {
            $0.lastRequest = recorded
            $0.requestCounts[recorded.path, default: 0] += 1
        }

        let mode = Self.state().mode
        if mode == .ordinaryRefreshDelayed {
            handleOrdinaryDelayedRefresh(recorded)
            return
        }
        if mode == .ordinaryUnauthorizedDelayed {
            handleOrdinaryUnauthorizedDelayed(recorded)
            return
        }
        if mode == .temporaryRefreshRejected {
            switch (recorded.method, recorded.path) {
            case ("GET", "/api/v1/settings/contract/capabilities"):
                respond(status: 401, body: #"{"error":"unauthorized"}"#)
            case ("POST", "/api/v1/auth/refresh"):
                respond(status: 401, body: #"{"error":"invalid_token"}"#)
            default:
                respond(status: 404, body: #"{"error":"not_found"}"#)
            }
            return
        }
        if mode == .concurrentScopedRefresh {
            switch (recorded.method, recorded.path) {
            case ("POST", "/api/v1/auth/refresh"):
                respond(
                    status: 200,
                    body: #"{"access_token":"placeholder","refresh_token":"redacted","expires_in":3600}"#
                )
            case ("GET", "/api/v1/settings/contract/capabilities"):
                if recorded.header("Authorization") == "Bearer placeholder" {
                    respond(
                        status: 200,
                        body: """
                        {"api_version":1,"revision":\(SettingKey.revision),"contract_etag":"\\"etag\\"","definition_count":48,
                         "scopes":["account","profile","profile_device","profile_library","profile_series"],
                         "supports_batched_effective":true,"supports_idempotent_writes":true,
                         "supports_atomic_shortcuts":true}
                        """
                    )
                } else {
                    holdConcurrentUnauthorizedUntilBothExpiredRequestsArrive()
                }
            default:
                respond(status: 404, body: #"{"error":"not_found"}"#)
            }
            return
        }
        switch mode {
        case .mixedRefreshScopedWins:
            handleMixedRefreshScopedFlight(
                recorded,
                refreshStatus: 200,
                refreshBody: #"{"access_token":"placeholder","refresh_token":"redacted","expires_in":3600}"#
            )
            return
        case .mixedRefreshScopedFailure:
            handleMixedRefreshScopedFlight(
                recorded,
                refreshStatus: 401,
                refreshBody: #"{"error":"invalid_token"}"#,
                holdRefreshForExplicitRelease: true
            )
            return
        case .mixedRefreshScopedTransientFailure(let status):
            handleMixedRefreshScopedFlight(
                recorded,
                refreshStatus: status,
                refreshBody: #"{"error":"temporarily_unavailable"}"#
            )
            return
        case .mixedRefreshScopedMalformedSuccess:
            handleMixedRefreshScopedFlight(
                recorded,
                refreshStatus: 200,
                refreshBody: #"{"access_token":"placeholder"}"#
            )
            return
        default:
            break
        }
        if mode == .serverTooOld {
            // The chi router's own 404: plain text, no Silo error envelope.
            respond(status: 404, body: "404 page not found\n", contentType: "text/plain", headers: [:])
            return
        }
        let responseRevision = mode == .olderContractRevision
            ? SettingKey.revision - 1
            : SettingKey.revision

        switch (recorded.method, recorded.path) {
        case ("GET", "/api/v1/health"):
            respond(status: 200, body: #"{"status":"ok","server_name":"Candidate"}"#)
        case ("GET", "/api/v1/settings/contract/capabilities"):
            respond(status: 200, body: """
            {"api_version":1,"revision":\(responseRevision),"contract_etag":"\\"etag\\"","definition_count":48,
             "scopes":["account","profile","profile_device","profile_library","profile_series"],
             "supports_batched_effective":true,"supports_idempotent_writes":true,
             "supports_atomic_shortcuts":true}
            """)
        case ("GET", "/api/v1/settings/values/effective"):
            respond(status: 200, body: """
            {"settings":[{"key":"playback.auto_play_next","value":true,"source":"default"}],
             "revision":\(responseRevision)}
            """)
        case ("PUT", "/api/v1/settings/values/nav.shortcuts/item"):
            let value = Self.shortcutValueFromMutationBody(recorded.body) ?? #"{"items":[]}"#
            let replay = mode == .idempotentReplay
            respond(
                status: 200,
                body: """
                {"key":"nav.shortcuts","scope":"profile",
                 "value":\(value),"revision":\(replay ? 0 : 3)}
                """,
                contentType: "application/json",
                headers: replay ? ["X-Silo-Idempotent-Replay": "true"] : [:]
            )
        case ("PUT", let path) where path.hasPrefix("/api/v1/settings/values/"):
            let key = String(path.dropFirst("/api/v1/settings/values/".count))
            let value = Self.valueFromWriteBody(recorded.body) ?? "null"
            let replay = mode == .idempotentReplay
            respond(
                status: 200,
                body: """
                {"key":"\(key)","scope":"\(recorded.query["scope"] ?? "")",
                 "value":\(value),"revision":\(replay ? 0 : 3)}
                """,
                contentType: "application/json",
                headers: replay ? ["X-Silo-Idempotent-Replay": "true"] : [:]
            )
        case ("DELETE", let path) where path.hasPrefix("/api/v1/settings/values/"):
            if mode == .nothingStored {
                respond(status: 404, body: #"{"error":"not_found","message":"No value is set at this scope"}"#)
            } else {
                respond(status: 204, body: "")
            }
        default:
            respond(status: 404, body: #"{"error":"not_found","message":"unstubbed route"}"#)
        }
    }

    override func stopLoading() {}

    /// Release both initial 401s together so the regression deterministically
    /// exercises two already-sent requests joining the same refresh flight.
    /// Retaining the protocol instances avoids blocking URLSession's loader
    /// queue while waiting for the second request.
    private func holdConcurrentUnauthorizedUntilBothExpiredRequestsArrive() {
        let ready: [SettingsStubProtocol]
        Self.lock.lock()
        Self.pendingConcurrentUnauthorized.append(self)
        if Self.pendingConcurrentUnauthorized.count >= 2 {
            ready = Self.pendingConcurrentUnauthorized
            Self.pendingConcurrentUnauthorized.removeAll()
        } else {
            ready = []
        }
        Self.lock.unlock()

        for pending in ready {
            pending.respond(status: 401, body: #"{"error":"unauthorized"}"#)
        }
    }

    private func handleMixedRefreshScopedFlight(
        _ recorded: RecordedRequest,
        refreshStatus: Int,
        refreshBody: String,
        holdRefreshForExplicitRelease: Bool = false
    ) {
        switch (recorded.method, recorded.path) {
        case ("GET", "/api/v1/settings/contract/capabilities"):
            if recorded.header("Authorization") == "Bearer placeholder" {
                respond(
                    status: 200,
                    body: """
                    {"api_version":1,"revision":\(SettingKey.revision),"contract_etag":"\\"etag\\"","definition_count":48,
                     "scopes":["account","profile","profile_device","profile_library","profile_series"],
                     "supports_batched_effective":true,"supports_idempotent_writes":true,
                     "supports_atomic_shortcuts":true}
                    """
                )
                return
            }
            if recorded.header("X-Test-Refresh-Flow") == "scoped" {
                respond(status: 401, body: #"{"error":"unauthorized"}"#)
                return
            }

            let refreshAlreadyStarted: Bool
            Self.lock.lock()
            refreshAlreadyStarted = Self.mixedRefreshStarted
            if !refreshAlreadyStarted {
                Self.pendingMixedOrdinaryUnauthorized = self
            }
            Self.lock.unlock()
            if refreshAlreadyStarted {
                respond(status: 401, body: #"{"error":"unauthorized"}"#)
            }

        case ("POST", "/api/v1/auth/refresh"):
            let pendingOrdinary: SettingsStubProtocol?
            Self.lock.lock()
            Self.mixedRefreshStarted = true
            pendingOrdinary = Self.pendingMixedOrdinaryUnauthorized
            Self.pendingMixedOrdinaryUnauthorized = nil
            if holdRefreshForExplicitRelease {
                Self.pendingMixedRefresh = (self, refreshStatus, refreshBody)
            }
            Self.lock.unlock()
            pendingOrdinary?.respond(status: 401, body: #"{"error":"unauthorized"}"#)

            if !holdRefreshForExplicitRelease {
                // Keep the scoped-owned refresh in flight long enough for the
                // ordinary 401 to reach HTTPClient's shared account slot.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(100))
                    self?.respond(status: refreshStatus, body: refreshBody)
                }
            }

        default:
            respond(status: 404, body: #"{"error":"not_found"}"#)
        }
    }

    private func handleOrdinaryDelayedRefresh(_ recorded: RecordedRequest) {
        switch (recorded.method, recorded.path) {
        case ("GET", "/api/v1/settings/contract/capabilities"):
            if ["Bearer placeholder", "Bearer newer-access"].contains(
                recorded.header("Authorization")
            ) {
                respond(
                    status: 200,
                    body: """
                    {"api_version":1,"revision":\(SettingKey.revision),"contract_etag":"\\"etag\\"","definition_count":48,
                     "scopes":["account","profile","profile_device","profile_library","profile_series"],
                     "supports_batched_effective":true,"supports_idempotent_writes":true,
                     "supports_atomic_shortcuts":true}
                    """
                )
            } else {
                respond(status: 401, body: #"{"error":"unauthorized"}"#)
            }

        case ("POST", "/api/v1/auth/refresh"):
            Self.lock.lock()
            Self.pendingOrdinaryRefresh = self
            Self.lock.unlock()

        default:
            respond(status: 404, body: #"{"error":"not_found"}"#)
        }
    }

    private func handleOrdinaryUnauthorizedDelayed(_ recorded: RecordedRequest) {
        switch (recorded.method, recorded.path) {
        case ("GET", "/api/v1/settings/contract/capabilities"):
            let unauthorizedWasReleased: Bool
            Self.lock.lock()
            unauthorizedWasReleased = Self.ordinaryUnauthorizedReleased
            Self.lock.unlock()
            if unauthorizedWasReleased || recorded.header("Authorization") == "Bearer placeholder" {
                respond(
                    status: 200,
                    body: """
                    {"api_version":1,"revision":\(SettingKey.revision),"contract_etag":"\\"etag\\"","definition_count":48,
                     "scopes":["account","profile","profile_device","profile_library","profile_series"],
                     "supports_batched_effective":true,"supports_idempotent_writes":true,
                     "supports_atomic_shortcuts":true}
                    """
                )
            } else {
                Self.lock.lock()
                Self.pendingOrdinaryUnauthorized = self
                Self.lock.unlock()
            }

        case ("POST", "/api/v1/auth/refresh"):
            respond(
                status: 200,
                body: #"{"access_token":"placeholder","refresh_token":"redacted","expires_in":3600}"#
            )

        default:
            respond(status: 404, body: #"{"error":"not_found"}"#)
        }
    }

    /// Pull the raw `value` back out of a `{"value": …}` body without
    /// re-encoding it, so a test can assert the stub echoed exactly what the
    /// client sent.
    private static func valueFromWriteBody(_ body: Data?) -> String? {
        guard let body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let value = object["value"]
        else { return nil }
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .sortedKeys]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func shortcutValueFromMutationBody(_ body: Data?) -> String? {
        guard let body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let item = object["item"] as? [String: Any],
              let present = object["present"] as? Bool
        else { return nil }
        let value: [String: Any] = ["items": present ? [item] : []]
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func lowercasedHeaders(_ headers: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        for (name, value) in headers {
            normalized[name.lowercased()] = value
        }
        return normalized
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
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
