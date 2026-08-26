//
//  ImageSizeCapabilityTests.swift
//  SiloTests
//
//  Wire-decoding + query-injection tests for image-size selection.
//  Decodes raw snake_case JSON exactly as `HTTPClient` does
//  (`.convertFromSnakeCase`), and covers the gating matrix for the
//  query entries the networking layer merges into image-bearing
//  requests.
//
//  The `platformPrefersLargeImages` flag is passed explicitly rather
//  than read from `#if os(tvOS)`: the test target is hosted by the iOS
//  app, so the tvOS branch is otherwise unreachable from a test.
//

import XCTest
import Foundation
@testable import Silo

final class ImageSizeCapabilityTests: XCTestCase {

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    /// The capability payload as the server documents it.
    private let capabilityJSON = """
    {
      "schema_version": 1,
      "param": "image_size",
      "sizes": ["small", "medium", "large", "original"],
      "widths": {
        "poster": {"small": 300, "medium": 500, "large": 780},
        "still": {"small": 300, "medium": 500, "large": 780},
        "logo": {"small": 300, "medium": 500, "large": 1280},
        "backdrop": {"small": 300, "medium": 780, "large": 1920}
      },
      "original_max_width_px": 1920,
      "textless_poster": {
        "endpoint": "/api/v1/catalog/items/{id}/images/textless-poster",
        "supported_types": ["movie", "series"]
      }
    }
    """

    private func decodedCapability() throws -> ImageSizeCapabilityResponse {
        try decoder().decode(
            ImageSizeCapabilityResponse.self,
            from: Data(capabilityJSON.utf8)
        )
    }

    // MARK: - Decoding

    func testCapabilityDecodesServerPayload() throws {
        let capability = try decodedCapability()
        XCTAssertEqual(capability.schemaVersion, 1)
        XCTAssertEqual(capability.param, "image_size")
        XCTAssertEqual(capability.sizes, ["small", "medium", "large", "original"])
        XCTAssertEqual(capability.originalMaxWidthPx, 1920)
        XCTAssertEqual(capability.widths["poster"]?["large"], 780)
        XCTAssertEqual(capability.widths["logo"]?["large"], 1280)
        XCTAssertEqual(capability.widths["backdrop"]?["large"], 1920)
        XCTAssertEqual(
            capability.textlessPoster?.endpoint,
            "/api/v1/catalog/items/{id}/images/textless-poster"
        )
        XCTAssertEqual(capability.textlessPoster?.supportedTypes, ["movie", "series"])
    }

    /// Roles the client doesn't know about must not fail the decode —
    /// the server is free to add image roles without a client release.
    func testCapabilityDecodesUnknownImageRole() throws {
        let json = """
        {
          "schema_version": 1,
          "param": "image_size",
          "sizes": ["small", "large"],
          "widths": {"thumb": {"small": 120, "large": 480}},
          "original_max_width_px": 1920
        }
        """
        let capability = try decoder().decode(
            ImageSizeCapabilityResponse.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(capability.widths["thumb"]?["large"], 480)
    }

    func testTextlessPosterEndpointOnlySupportsAdvertisedContentTypes() throws {
        let capability = try decodedCapability()
        XCTAssertEqual(
            ImageSizeCapability.textlessPosterEndpoint(capability: capability, for: "movie"),
            "/api/v1/catalog/items/{id}/images/textless-poster"
        )
        XCTAssertEqual(
            ImageSizeCapability.textlessPosterEndpoint(capability: capability, for: "SERIES"),
            "/api/v1/catalog/items/{id}/images/textless-poster"
        )
        XCTAssertNil(
            ImageSizeCapability.textlessPosterEndpoint(capability: capability, for: "episode")
        )
        XCTAssertNil(
            ImageSizeCapability.textlessPosterEndpoint(capability: capability, for: "audiobook")
        )
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

    /// A schema the client doesn't understand is treated as "off".
    func testQueryEntriesEmptyForUnknownSchemaVersion() {
        let capability = ImageSizeCapabilityResponse(
            schemaVersion: 2,
            param: "image_size",
            sizes: ["small", "large"],
            widths: [:],
            originalMaxWidthPx: 1920
        )
        XCTAssertTrue(
            ImageSizeCapability.queryEntries(
                capability: capability,
                platformPrefersLargeImages: true
            ).isEmpty
        )
    }

    /// A server that doesn't advertise `large` gets no parameter at all,
    /// because an unadvertised value is a 400.
    func testQueryEntriesEmptyWhenLargeNotAdvertised() {
        let capability = ImageSizeCapabilityResponse(
            schemaVersion: 1,
            param: "image_size",
            sizes: ["small", "medium"],
            widths: [:],
            originalMaxWidthPx: 1920
        )
        XCTAssertTrue(
            ImageSizeCapability.queryEntries(
                capability: capability,
                platformPrefersLargeImages: true
            ).isEmpty
        )
    }

    /// The parameter name comes from the payload, not a hardcoded string.
    func testQueryEntriesUseServerSuppliedParamName() {
        let capability = ImageSizeCapabilityResponse(
            schemaVersion: 1,
            param: "img_size",
            sizes: ["large"],
            widths: [:],
            originalMaxWidthPx: 1920
        )
        XCTAssertEqual(
            ImageSizeCapability.queryEntries(
                capability: capability,
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

    func testFailedRefreshIsCachedUntilExplicitRetry() async throws {
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
        var callCount = await stub.callCount
        XCTAssertEqual(callCount, 1)

        await capability.retryUnavailable()
        await capability.refresh()

        callCount = await stub.callCount
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(capability.requestQuery, ["image_size": "large"])
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
