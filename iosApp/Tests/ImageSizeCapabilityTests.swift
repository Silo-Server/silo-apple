//
//  ImageSizeCapabilityTests.swift
//  SiloTests
//
//  Decoding + query-injection tests for image-size selection. The payload
//  is the vendored server fixture for `GET /api/v2/images/capabilities`,
//  decoded with the production decoder, and the gating matrix covers the
//  query entries the networking layer merges into image-bearing requests.
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
        sizes: [String] = ["small", "medium", "large", "original"]
    ) -> ImageSizeCapabilityResponse {
        ImageSizeCapabilityResponse(param: param, sizes: sizes, widths: [:], originalMaxWidthPx: 1920, state: state)
    }

    // MARK: - Decoding

    func testCapabilityDecodesServerFixture() throws {
        let capability = try decodedCapability()
        XCTAssertEqual(capability.state, "available")
        XCTAssertEqual(capability.param, "image_size")
        XCTAssertEqual(capability.sizes, ["small", "medium", "large", "original"])
        XCTAssertEqual(capability.originalMaxWidthPx, 1920)
        XCTAssertEqual(capability.widths["poster"]?["large"], 780)
        XCTAssertEqual(capability.widths["logo"]?["large"], 1280)
        XCTAssertEqual(capability.widths["backdrop"]?["large"], 1920)
        XCTAssertEqual(capability.storageBackend, "local")
        XCTAssertEqual(capability.delivery, "server")
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
        let entries = ImageSizeCapability.queryEntries(
            capability: try decodedCapability(),
            platformPrefersLargeImages: true
        )
        XCTAssertEqual(entries, ["image_size": "large"])
    }

    /// iOS and macOS must keep sending byte-identical requests.
    func testQueryEntriesEmptyOffTV() throws {
        let entries = ImageSizeCapability.queryEntries(
            capability: try decodedCapability(),
            platformPrefersLargeImages: false
        )
        XCTAssertTrue(entries.isEmpty)
    }

    /// Older server: the probe 404s, the capability stays nil, and the
    /// client sends nothing rather than risking a 400.
    func testQueryEntriesEmptyWithoutCapability() {
        let entries = ImageSizeCapability.queryEntries(
            capability: nil,
            platformPrefersLargeImages: true
        )
        XCTAssertTrue(entries.isEmpty)
    }

    /// Only an available capability turns the parameter on; every other
    /// server state, including one this client doesn't know, is "off".
    func testQueryEntriesEmptyUnlessCapabilityIsAvailable() {
        for state in ["disabled", "not_configured", "unsupported", "future_state"] {
            XCTAssertTrue(
                ImageSizeCapability.queryEntries(
                    capability: capability(state: state),
                    platformPrefersLargeImages: true
                ).isEmpty,
                state
            )
        }
    }

    /// A server that doesn't advertise `large` gets no parameter at all,
    /// because an unadvertised value is a 400.
    func testQueryEntriesEmptyWhenLargeNotAdvertised() {
        XCTAssertTrue(
            ImageSizeCapability.queryEntries(
                capability: capability(sizes: ["small", "medium"]),
                platformPrefersLargeImages: true
            ).isEmpty
        )
    }

    /// The parameter name comes from the payload, not a hardcoded string.
    func testQueryEntriesUseServerSuppliedParamName() {
        XCTAssertEqual(
            ImageSizeCapability.queryEntries(
                capability: capability(param: "img_size", sizes: ["large"]),
                platformPrefersLargeImages: true
            ),
            ["img_size": "large"]
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
        XCTAssertTrue(capability.requestQuery.isEmpty)
        XCTAssertFalse(capability.isAvailable)
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
        XCTAssertEqual(capability.requestQuery, ["image_size": "large"])
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
        XCTAssertTrue(capability.requestQuery.isEmpty)

        await capability.refresh()
        await capability.refresh()

        let callCount = await stub.callCount
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(capability.requestQuery, ["image_size": "large"])
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
        XCTAssertTrue(capability.requestQuery.isEmpty)
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
        XCTAssertEqual(capability.requestQuery, ["image_size": "large"])
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
