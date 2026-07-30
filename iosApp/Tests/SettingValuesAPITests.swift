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
               "scope":"profile_series","profile_id":"p1","series_id":"s-101"},
              {"key":"playback.auto_play_next","value":true,"source":"default"}
            ],"revision":1}
            """.utf8))

        XCTAssertEqual(response.revision, 1)
        let series = try XCTUnwrap(response.value(for: .playbackSubtitleLanguage))
        XCTAssertEqual(series.source, .scope(.profileSeries))
        XCTAssertEqual(series.value, .string("ja"))
        XCTAssertEqual(series.storedAt, .profileSeries(seriesId: "s-101"))

        let fromDefault = try XCTUnwrap(response.value(for: .playbackAutoPlayNext))
        XCTAssertEqual(fromDefault.source, .contractDefault)
        XCTAssertEqual(fromDefault.value, .bool(true))
        XCTAssertNil(fromDefault.storedAt, "a contract default has no row to reset")
        XCTAssertFalse(fromDefault.constrained)
        XCTAssertNil(fromDefault.storedValue)
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
        XCTAssertEqual(capabilities.revision, 1)
        XCTAssertTrue(capabilities.supportsIdempotentWrites)
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
        XCTAssertEqual(response.revision, 1)

        let recorded = try XCTUnwrap(SettingsStubProtocol.state().lastRequest)
        XCTAssertEqual(recorded.query["keys"], "playback.subtitle_language,playback.auto_play_next")
        XCTAssertEqual(recorded.query["library_ids"], "7,9")
        XCTAssertEqual(recorded.query["series_ids"], "s-101")
        XCTAssertEqual(recorded.header("X-Profile-Id"), Self.stubProfileId)
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

    /// A ContinuumAPI whose HTTPClient talks to SettingsStubProtocol, with a
    /// TokenStore isolated to this test.
    private func makeStubbedAPI(profileId: String? = SettingValuesAPITests.stubProfileId) async -> ContinuumAPI {
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
        return ContinuumAPI(http: http, tokenStore: tokenStore)
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
        /// A write whose mutation id the server already applied.
        case idempotentReplay
        /// A delete addressing a scope with no stored value.
        case nothingStored
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
    }

    private static let lock = NSLock()
    private static var current = State()

    static func reset(mode: Mode) {
        lock.lock()
        current = State(mode: mode)
        lock.unlock()
    }

    static func state() -> State {
        lock.lock()
        defer { lock.unlock() }
        return current
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
            body: Self.requestBody(of: request)
        )
        Self.mutate { $0.lastRequest = recorded }

        let mode = Self.state().mode
        if mode == .serverTooOld {
            // The chi router's own 404: plain text, no Silo error envelope.
            respond(status: 404, body: "404 page not found\n", contentType: "text/plain", headers: [:])
            return
        }

        switch (recorded.method, recorded.path) {
        case ("GET", "/api/v1/settings/contract/capabilities"):
            respond(status: 200, body: """
            {"api_version":1,"revision":1,"contract_etag":"\\"etag\\"","definition_count":48,
             "scopes":["account","profile","profile_device","profile_library","profile_series"],
             "supports_batched_effective":true,"supports_idempotent_writes":true}
            """)
        case ("GET", "/api/v1/settings/values/effective"):
            respond(status: 200, body: """
            {"settings":[{"key":"playback.auto_play_next","value":true,"source":"default"}],
             "revision":1}
            """)
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

    private static func lowercasedHeaders(_ headers: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        for (name, value) in headers {
            normalized[name.lowercased()] = value
        }
        return normalized
    }

    /// URLSession surfaces outgoing bodies to URLProtocol as a stream, not
    /// `httpBody`; drain it.
    private static func requestBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private func respond(
        status: Int,
        body: String,
        contentType: String = "application/json",
        headers: [String: String] = [:]
    ) {
        guard let url = request.url, let client else { return }
        var allHeaders = headers
        allHeaders["Content-Type"] = contentType
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: allHeaders
        )!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty {
            client.urlProtocol(self, didLoad: Data(body.utf8))
        }
        client.urlProtocolDidFinishLoading(self)
    }
}
