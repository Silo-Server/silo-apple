//
//  ImageSizeCapabilityTests.swift
//  SiloTests
//
//  Decoding + query-injection tests for image-size selection. The payload
//  is the vendored server fixture for `GET /api/v2/images/capabilities`,
//  decoded with the production decoder, and the gating matrix covers the
//  query entries the networking layer merges into image-bearing requests:
//  per-slot widths on servers that take them, one size on older servers.
//
//  The `platformPrefersLargeImages` flag is passed explicitly rather
//  than read from `#if os(tvOS)`: the test target is hosted by the iOS
//  app, so the tvOS branch is otherwise unreachable from a test.
//

import XCTest
import Foundation
@testable import Silo

final class ImageSizeCapabilityTests: XCTestCase {

    private static let fixture = "get_image_capabilities_ok"

    private func decodedCapability() throws -> ImageSizeCapabilityResponse {
        try APIv2FixtureTestSupport.decode(ImageSizeCapabilityResponse.self, named: Self.fixture, bundleClass: Self.self)
    }

    private func capability(
        state: String = "available",
        param: String = "image_size",
        sizes: [String] = ["small", "medium", "large", "original"],
        slotWidthParams: [String: String]? = nil
    ) -> ImageSizeCapabilityResponse {
        ImageSizeCapabilityResponse(
            param: param, sizes: sizes, widths: [:], originalMaxWidthPx: 3840, state: state,
            slotWidthParams: slotWidthParams
        )
    }

    /// The Apple TV home row: medium cards under a full-screen hero.
    private let shelves = ArtworkSlotWidths(imageSize: "medium", backdrop: 1344, logo: 880)

    /// The still width an episode rail asks for at 2×: 360 pt cards on
    /// tvOS, 240 pt elsewhere.
    #if os(tvOS)
    private let episodeStillWidth = "720"
    #else
    private let episodeStillWidth = "480"
    #endif

    /// The pre-slot server: same document without `slot_width_params`.
    private func legacyCapability() throws -> ImageSizeCapabilityResponse {
        var capability = try decodedCapability()
        capability.slotWidthParams = nil
        return capability
    }

    // MARK: - Decoding

    func testCapabilityDecodesServerFixture() throws {
        let capability = try decodedCapability()
        XCTAssertEqual(capability.state, "available")
        XCTAssertEqual(capability.param, "image_size")
        XCTAssertEqual(capability.sizes, ["small", "medium", "large", "original"])
        XCTAssertEqual(capability.originalMaxWidthPx, 3840)
        XCTAssertEqual(capability.widths["poster"]?["large"], 1000)
        XCTAssertEqual(capability.widths["logo"]?["large"], 1280)
        XCTAssertEqual(capability.widths["backdrop"]?["large"], 2560)
        XCTAssertEqual(capability.storageBackend, "local")
        XCTAssertEqual(capability.delivery, "server")
        XCTAssertEqual(capability.slotWidthParams, [
            "poster": "poster_width", "backdrop": "backdrop_width", "logo": "logo_width",
            "still": "still_width", "photo": "photo_width",
        ])
    }

    /// A server that predates per-slot widths sends no `slot_width_params`.
    func testCapabilityWithoutSlotWidthParamsDecodes() throws {
        let body = try APIv2FixtureTestSupport.mutatedBody(named: Self.fixture, bundleClass: Self.self) { object in
            object["slot_width_params"] = nil
        }
        let capability = try APIv2FixtureTestSupport.decoder.decode(ImageSizeCapabilityResponse.self, from: body)
        XCTAssertNil(capability.slotWidthParams)
    }

    /// Roles the client doesn't know about must not fail the decode —
    /// the server is free to add image roles without a client release.
    func testCapabilityDecodesUnknownImageRole() throws {
        let body = try APIv2FixtureTestSupport.mutatedBody(named: Self.fixture, bundleClass: Self.self) { object in
            var widths = object["widths"] as? [String: Any] ?? [:]
            widths["thumb"] = ["small": 120, "large": 480]
            object["widths"] = widths
        }
        let capability = try APIv2FixtureTestSupport.decoder.decode(ImageSizeCapabilityResponse.self, from: body)
        XCTAssertEqual(capability.widths["thumb"]?["large"], 480)
    }

    /// A v1-era document (`schema_version`, no capability `state`) is not a
    /// v2 answer. It fails the decode, so the probe stays empty and the
    /// client sends no parameter.
    func testLegacySchemaVersionDocumentIsNotACapability() throws {
        let body = try APIv2FixtureTestSupport.mutatedBody(named: Self.fixture, bundleClass: Self.self) { object in
            object["state"] = nil
            object["schema_version"] = 1
        }
        XCTAssertThrowsError(try APIv2FixtureTestSupport.decoder.decode(ImageSizeCapabilityResponse.self, from: body))
    }

    // MARK: - Query injection

    func testQueryEntriesAddLargeWhenSupportedOnTV() throws {
        let entries = ImageSizeSelection.queryEntries(capability: try decodedCapability(),
            prefersLargeImages: true
        )
        XCTAssertEqual(entries, ["image_size": "large"])
    }

    /// iOS and macOS must keep sending byte-identical requests.
    func testQueryEntriesEmptyOffTV() throws {
        let entries = ImageSizeSelection.queryEntries(capability: try decodedCapability(),
            prefersLargeImages: false
        )
        XCTAssertTrue(entries.isEmpty)
    }

    /// Older server: the probe 404s, the capability stays nil, and the
    /// client sends nothing rather than risking a 400.
    func testQueryEntriesEmptyWithoutCapability() {
        let entries = ImageSizeSelection.queryEntries(capability: nil,
            prefersLargeImages: true
        )
        XCTAssertTrue(entries.isEmpty)
    }

    /// Only an available capability turns the parameter on; every other
    /// server state, including one this client doesn't know, is "off".
    func testQueryEntriesEmptyUnlessCapabilityIsAvailable() {
        for state in ["disabled", "not_configured", "unsupported", "future_state"] {
            XCTAssertTrue(
                ImageSizeSelection.queryEntries(capability: capability(state: state),
                    prefersLargeImages: true
                ).isEmpty,
                state
            )
        }
    }

    /// A server that doesn't advertise `large` gets no parameter at all,
    /// because an unadvertised value is a 400.
    func testQueryEntriesEmptyWhenLargeNotAdvertised() {
        XCTAssertTrue(
            ImageSizeSelection.queryEntries(capability: capability(sizes: ["small", "medium"]),
                prefersLargeImages: true
            ).isEmpty
        )
    }

    /// The parameter name comes from the payload, not a hardcoded string.
    func testQueryEntriesUseServerSuppliedParamName() {
        XCTAssertEqual(
            ImageSizeSelection.queryEntries(capability: capability(param: "img_size", sizes: ["large"]),
                prefersLargeImages: true
            ),
            ["img_size": "large"]
        )
    }

    // MARK: - Per-slot widths

    /// Apple TV 4K (2×): the hero widths of the issue's table, in pixels.
    func testSlotWidthsAreDevicePixelsOnAppleTV4K() throws {
        let entries = ImageSizeSelection.queryEntries(
            capability: try decodedCapability(), slots: shelves, displayScale: 2, prefersLargeImages: true
        )
        XCTAssertEqual(entries, ["image_size": "medium", "backdrop_width": "2688", "logo_width": "1760"])
    }

    func testSlotWidthsFollowTheDisplayScale() throws {
        let capability = try decodedCapability()
        let episodes = ArtworkSlotWidths(still: 360)
        XCTAssertEqual(
            ImageSizeSelection.queryEntries(capability: capability, slots: episodes, displayScale: 1, prefersLargeImages: true),
            ["still_width": "360"]
        )
        XCTAssertEqual(
            ImageSizeSelection.queryEntries(capability: capability, slots: episodes, displayScale: 3, prefersLargeImages: false),
            ["still_width": "1080"]
        )
    }

    /// Fractional point widths round up so the rung is never too narrow, and
    /// nothing exceeds the server's 7680 limit.
    func testSlotWidthsRoundUpAndStayInRange() {
        XCTAssertEqual(ImageSizeSelection.pixelWidth(points: 240.2, displayScale: 3), 721)
        XCTAssertEqual(ImageSizeSelection.pixelWidth(points: 5000, displayScale: 2), 7680)
        XCTAssertNil(ImageSizeSelection.pixelWidth(points: 0, displayScale: 2))
        XCTAssertNil(ImageSizeSelection.pixelWidth(points: .infinity, displayScale: 2))
    }

    /// Parameter names come from the payload; a slot it does not name is
    /// left to `image_size`, and an unadvertised size is never sent.
    func testSlotWidthsUseServerSuppliedNamesOnly() {
        let entries = ImageSizeSelection.queryEntries(
            capability: capability(sizes: ["small", "large"], slotWidthParams: ["backdrop": "bd_w"]),
            slots: shelves, displayScale: 2, prefersLargeImages: true
        )
        XCTAssertEqual(entries, ["bd_w": "2688"])
    }

    /// A pre-slot server keeps today's requests: `large` from tvOS, nothing
    /// from iOS and macOS.
    func testServerWithoutSlotWidthsKeepsOneSizePerResponse() throws {
        let legacy = try legacyCapability()
        XCTAssertEqual(
            ImageSizeSelection.queryEntries(capability: legacy, slots: shelves, displayScale: 2, prefersLargeImages: true),
            ["image_size": "large"]
        )
        XCTAssertTrue(
            ImageSizeSelection.queryEntries(capability: legacy, slots: shelves, displayScale: 2, prefersLargeImages: false).isEmpty
        )
    }

    /// Reads that sent no size before per-slot widths, among them the
    /// recommendation reads that such a server rejects with `422` when given
    /// any size, send nothing to it; the rest keep `image_size=large` on tvOS.
    func testSlotWidthsOnlyReadsSendNothingToServersWithoutSlotWidths() async throws {
        let legacy = try legacyCapability()
        let capability = ImageSizeCapability(platformPrefersLargeImages: true) { legacy }
        await capability.refresh()

        XCTAssertEqual(capability.requestQuery(for: .home), ["image_size": "large"])
        XCTAssertTrue(capability.requestQuery(for: .shelves, slotWidthsOnly: true).isEmpty)
        XCTAssertTrue(capability.requestQuery(for: .similar, slotWidthsOnly: true).isEmpty)
    }

    func testSlotWidthsOnlyReadsGetWidthsWhenTheServerTakesThem() async throws {
        let response = try decodedCapability()
        let capability = ImageSizeCapability(platformPrefersLargeImages: true) { response }
        await capability.refresh()

        XCTAssertEqual(capability.requestQuery(for: .episodes, slotWidthsOnly: true), ["still_width": episodeStillWidth])
    }

    func testSlotWidthsNeedAnAvailableCapability() {
        XCTAssertTrue(
            ImageSizeSelection.queryEntries(capability: nil, slots: shelves, displayScale: 2, prefersLargeImages: true).isEmpty
        )
        XCTAssertTrue(
            ImageSizeSelection.queryEntries(
                capability: capability(state: "disabled", slotWidthParams: ["backdrop": "backdrop_width"]),
                slots: shelves, displayScale: 2, prefersLargeImages: true
            ).isEmpty
        )
    }

    // MARK: - Lifecycle

    /// `reset()` drops the probe so a later profile/server never inherits
    /// the previous one's capability.
    func testResetClearsCapability() {
        let capability = ImageSizeCapability()
        XCTAssertNil(capability.capability)
        capability.reset()
        XCTAssertNil(capability.capability)
        XCTAssertTrue(capability.requestQuery(for: .episodes).isEmpty)
    }

    /// iOS and macOS size their artwork too, so their first image request
    /// on an unknown server waits for the probe like tvOS's.
    func testImageRequestsOffTVProbeAndSendSlotWidths() async throws {
        let stub = ImageSizeCapabilityFetchStub(response: try decodedCapability())
        let capability = ImageSizeCapability(platformPrefersLargeImages: false) {
            try await stub.fetch()
        }

        let query = await capability.requestQueryForImageRequest(.episodes)

        XCTAssertEqual(query, ["still_width": episodeStillWidth])
        let callCount = await stub.callCount
        XCTAssertEqual(callCount, 1)
    }

    /// Watch detail draws no artwork, so on iOS and macOS playback never
    /// waits for the probe. tvOS still probes: an older server gets `large`.
    func testArtworkFreeReadsSkipTheProbeOffTV() async throws {
        let stub = ImageSizeCapabilityFetchStub(response: try legacyCapability())
        let offTV = ImageSizeCapability(platformPrefersLargeImages: false) { try await stub.fetch() }

        let query = await offTV.requestQueryForImageRequest(.watch)

        XCTAssertTrue(query.isEmpty)
        let callCount = await stub.callCount
        XCTAssertEqual(callCount, 0)

        let tvStub = ImageSizeCapabilityFetchStub(response: try legacyCapability())
        let tv = ImageSizeCapability(platformPrefersLargeImages: true) { try await tvStub.fetch() }
        let tvQuery = await tv.requestQueryForImageRequest(.watch)
        XCTAssertEqual(tvQuery, ["image_size": "large"])
    }

    func testRememberedCapabilityServesImageRequestsWithoutProbing() async throws {
        let stored = try decodedCapability()
        let memory = ImageSizeCapability.Memory(
            activeServerID: { "server-a" },
            load: { $0 == "server-a" ? stored : nil },
            save: { _, _ in }
        )
        let stub = ImageSizeCapabilityFetchStub(response: stored)
        let capability = ImageSizeCapability(platformPrefersLargeImages: true, memory: memory) {
            try await stub.fetch()
        }

        let query = await capability.requestQueryForImageRequest(.episodes)

        XCTAssertEqual(query, ["still_width": episodeStillWidth])
        let callCount = await stub.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testSuccessfulProbeIsRememberedForItsServer() async throws {
        let response = try decodedCapability()
        let saved = SavedCapabilities()
        let memory = ImageSizeCapability.Memory(
            activeServerID: { "server-b" },
            load: { _ in nil },
            save: { serverID, value in saved.record(serverID, value) }
        )
        let capability = ImageSizeCapability(platformPrefersLargeImages: true, memory: memory) {
            response
        }

        await capability.refresh()

        XCTAssertEqual(saved.values["server-b"], response)
    }

    func testSuccessfulRefreshIsCachedForSession() async throws {
        let response = try decodedCapability()
        let stub = ImageSizeCapabilityFetchStub(response: response)
        let capability = ImageSizeCapability(platformPrefersLargeImages: true) {
            try await stub.fetch()
        }

        await capability.refresh()
        await capability.refresh()

        let callCount = await stub.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(capability.requestQuery(for: .episodes), ["still_width": episodeStillWidth])
    }

    func testFailedRefreshRetriesAndThenCachesSuccess() async throws {
        let response = try decodedCapability()
        let stub = ImageSizeCapabilityFetchStub(
            response: response,
            failuresBeforeSuccess: 1
        )
        let capability = ImageSizeCapability(platformPrefersLargeImages: true) {
            try await stub.fetch()
        }

        await capability.refresh()
        XCTAssertTrue(capability.requestQuery(for: .episodes).isEmpty)

        await capability.refresh()
        await capability.refresh()

        let callCount = await stub.callCount
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(capability.requestQuery(for: .episodes)["still_width"], episodeStillWidth)
    }

    func testRequestProbesCacheFailuresUntilLifecycleRefreshOrReset() async throws {
        let stub = ImageSizeCapabilityFetchStub(response: try decodedCapability(), failuresBeforeSuccess: 2)
        let capability = ImageSizeCapability(platformPrefersLargeImages: false) { try await stub.fetch() }
        await capability.refresh(retryFailed: false)
        await capability.refresh(retryFailed: false)
        var count = await stub.callCount
        XCTAssertEqual(count, 1)
        XCTAssertNil(capability.capability)
        await capability.refresh() // A foreground event may retry.
        await capability.refresh(retryFailed: false)
        count = await stub.callCount
        XCTAssertEqual(count, 2)
        capability.reset() // A different server must get its own probe.
        await capability.refresh(retryFailed: false)
        count = await stub.callCount
        XCTAssertEqual(count, 3)
        XCTAssertNotNil(capability.capability)
        XCTAssertEqual(capability.requestQuery(for: .episodes)["still_width"], episodeStillWidth)
    }

    func testResetRequiresCapabilityProbeForNewIdentity() async throws {
        let response = try decodedCapability()
        let stub = ImageSizeCapabilityFetchStub(response: response)
        let capability = ImageSizeCapability(platformPrefersLargeImages: true) {
            try await stub.fetch()
        }

        await capability.refresh()
        capability.reset()
        await capability.refresh()

        let callCount = await stub.callCount
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(capability.requestQuery(for: .episodes)["still_width"], episodeStillWidth)
    }
}

private actor ImageSizeCapabilityFetchStub {
    private(set) var callCount = 0
    private let response: ImageSizeCapabilityResponse
    private let failuresBeforeSuccess: Int

    init(
        response: ImageSizeCapabilityResponse,
        failuresBeforeSuccess: Int = 0
    ) {
        self.response = response
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func fetch() throws -> ImageSizeCapabilityResponse {
        callCount += 1
        if callCount <= failuresBeforeSuccess {
            throw URLError(.cannotConnectToHost)
        }
        return response
    }
}

private final class SavedCapabilities: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: ImageSizeCapabilityResponse] = [:]

    var values: [String: ImageSizeCapabilityResponse] { lock.withLock { storage } }

    func record(_ serverID: String, _ value: ImageSizeCapabilityResponse) {
        lock.withLock { storage[serverID] = value }
    }
}
