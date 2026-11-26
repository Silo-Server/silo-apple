import Foundation

/// Admin and metadata-curator operations backed exclusively by `/api/v2/admin/...`.
extension APIv2Client {

    // MARK: - Fix Match

    func adminItemMatchHints(
        id: String,
        libraryId: Int? = nil,
        auth suppliedAuth: CapturedOrdinaryRequestAuth? = nil
    ) async throws -> AdminMatchHints {
        guard let auth = await ownerOrCurrent(suppliedAuth) else { throw HTTPError.requestIdentityChanged }
        let segment = try catalogPathSegment(id)
        var query: [String: String] = [:]
        if let libraryId { query["library_id"] = String(libraryId) }
        let raw = try await ownedRequest(
            method: "GET",
            path: "/api/v2/admin/items/\(segment)/match/hints",
            query: query,
            auth: auth
        )
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        return try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(AdminMatchHints.self, from: raw.data)
    }

    func searchAdminItemMatches(
        id: String,
        request: AdminMatchSearchRequest,
        auth suppliedAuth: CapturedOrdinaryRequestAuth? = nil
    ) async throws -> AdminMatchSearchResponse {
        guard let auth = await ownerOrCurrent(suppliedAuth) else { throw HTTPError.requestIdentityChanged }
        let segment = try catalogPathSegment(id)
        let body = try Self.snakeCaseJSONEncoder().encode(request)
        let raw = try await ownedRequest(
            method: "POST",
            path: "/api/v2/admin/items/\(segment)/match/search",
            body: body,
            timeout: .extended,
            auth: auth
        )
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        return try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(AdminMatchSearchResponse.self, from: raw.data)
    }

    func applyAdminItemMatch(
        id: String,
        request: AdminMatchApplyRequest,
        auth suppliedAuth: CapturedOrdinaryRequestAuth? = nil
    ) async throws -> AdminMatchApplyResponse {
        guard let auth = await ownerOrCurrent(suppliedAuth) else { throw HTTPError.requestIdentityChanged }
        let segment = try catalogPathSegment(id)
        let body = try Self.snakeCaseJSONEncoder().encode(request)
        let raw = try await ownedRequest(
            method: "POST",
            path: "/api/v2/admin/items/\(segment)/match/apply",
            body: body,
            timeout: .extended,
            auth: auth
        )
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        return try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(AdminMatchApplyResponse.self, from: raw.data)
    }

    // MARK: - Artwork / Images

    func adminItemImages(
        id: String,
        auth suppliedAuth: CapturedOrdinaryRequestAuth? = nil
    ) async throws -> AdminItemImagesResponse {
        guard let auth = await ownerOrCurrent(suppliedAuth) else { throw HTTPError.requestIdentityChanged }
        let segment = try catalogPathSegment(id)
        var allImages: [AdminItemImage] = []
        var seenCursors: Set<String> = []
        var cursor: String?
        var current = AdminCurrentImages(posterUrl: nil, backdropUrl: nil, logoUrl: nil)
        var providerErrors: [String: String] = [:]

        while true {
            var query: [String: String] = ["limit": "200"]
            if let cursor { query["cursor"] = cursor }
            let raw = try await ownedRequest(
                method: "GET",
                path: "/api/v2/admin/items/\(segment)/images",
                query: query,
                timeout: .extended,
                auth: auth
            )
            guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
            let page = try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url)
                .decode(AdminImagesPageWire.self, from: raw.data)
            allImages.append(contentsOf: page.items)
            current = page.current
            if let errors = page.providerErrors {
                for (k, v) in errors { providerErrors[k] = v }
            }
            guard page.page.hasMore else { break }
            guard let next = page.page.nextCursor, !next.isEmpty, seenCursors.insert(next).inserted else {
                throw APIv2Error.incompleteCatalogRead
            }
            cursor = next
        }

        return AdminItemImagesResponse(images: allImages, current: current, providerErrors: providerErrors)
    }

    func applyAdminItemImage(
        id: String,
        request: AdminImageApplyRequest,
        auth suppliedAuth: CapturedOrdinaryRequestAuth? = nil
    ) async throws -> AdminImageApplyResponse {
        guard let auth = await ownerOrCurrent(suppliedAuth) else { throw HTTPError.requestIdentityChanged }
        let segment = try catalogPathSegment(id)
        let body = try Self.snakeCaseJSONEncoder().encode(request)
        let raw = try await ownedRequest(
            method: "POST",
            path: "/api/v2/admin/items/\(segment)/images/apply",
            body: body,
            timeout: .extended,
            auth: auth
        )
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        return try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(AdminImageApplyResponse.self, from: raw.data)
    }

    func uploadAdminItemImage(
        id: String,
        slot: MetadataImageSlot,
        image: ValidatedUploadImage,
        auth suppliedAuth: CapturedOrdinaryRequestAuth? = nil
    ) async throws -> AdminImageApplyResponse {
        guard let auth = await ownerOrCurrent(suppliedAuth) else { throw HTTPError.requestIdentityChanged }
        let segment = try catalogPathSegment(id)
        let boundary = "SiloArtwork-\(UUID().uuidString)"
        let body = Self.artworkUploadMultipartBody(slot: slot.rawValue, image: image, boundary: boundary)
        let raw = try await ownedRequest(
            method: "POST",
            path: "/api/v2/admin/items/\(segment)/images/upload",
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            timeout: .extended,
            auth: auth
        )
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        return try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(AdminImageApplyResponse.self, from: raw.data)
    }

    // MARK: - Edit Metadata

    func updateAdminItemMetadata(
        id: String,
        patch: AdminItemMetadataPatch,
        auth suppliedAuth: CapturedOrdinaryRequestAuth? = nil
    ) async throws -> ItemDetail {
        guard let auth = await ownerOrCurrent(suppliedAuth) else { throw HTTPError.requestIdentityChanged }
        let segment = try catalogPathSegment(id)
        let body = try JSONEncoder().encode(patch)
        let raw = try await ownedRequest(
            method: "PATCH",
            path: "/api/v2/admin/items/\(segment)/metadata",
            body: body,
            auth: auth
        )
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        let wire = try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url)
            .decode(APIv2CatalogRead.CatalogItemDetail.self, from: raw.data)
        return try ItemDetail(catalog: wire)
    }

    // MARK: - Refresh Metadata & Jobs

    func refreshAdminItemMetadata(
        id: String,
        mode: MetadataRefreshMode,
        auth suppliedAuth: CapturedOrdinaryRequestAuth? = nil
    ) async throws -> AdminTaskJob {
        guard let auth = await ownerOrCurrent(suppliedAuth) else { throw HTTPError.requestIdentityChanged }
        let segment = try catalogPathSegment(id)
        let body = try Self.snakeCaseJSONEncoder().encode(AdminRefreshItemMetadataRequest(mode: mode))
        let raw = try await ownedRequest(
            method: "POST",
            path: "/api/v2/admin/items/\(segment)/refresh-metadata",
            body: body,
            auth: auth
        )
        guard raw.statusCode == 200 || raw.statusCode == 202 else {
            throw APIv2Error.httpStatus(raw.statusCode)
        }
        return try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(AdminTaskJob.self, from: raw.data)
    }

    func adminJob(
        id: String,
        auth suppliedAuth: CapturedOrdinaryRequestAuth? = nil
    ) async throws -> AdminTaskJob {
        guard let auth = await ownerOrCurrent(suppliedAuth) else { throw HTTPError.requestIdentityChanged }
        let segment = try catalogPathSegment(id)
        let raw = try await ownedRequest(
            method: "GET",
            path: "/api/v2/admin/jobs/\(segment)",
            auth: auth
        )
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        return try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(AdminTaskJob.self, from: raw.data)
    }

    // MARK: - Item Files (Multi-Library Disambiguation)

    func adminItemFiles(
        id: String,
        auth suppliedAuth: CapturedOrdinaryRequestAuth? = nil
    ) async throws -> [AdminItemFile] {
        guard let auth = await ownerOrCurrent(suppliedAuth) else { throw HTTPError.requestIdentityChanged }
        let segment = try catalogPathSegment(id)
        var allFiles: [AdminItemFile] = []
        var seenCursors: Set<String> = []
        var cursor: String?

        while true {
            var query: [String: String] = ["limit": "200"]
            if let cursor { query["cursor"] = cursor }
            let raw = try await ownedRequest(
                method: "GET",
                path: "/api/v2/admin/items/\(segment)/files",
                query: query,
                auth: auth
            )
            guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
            let page = try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url)
                .decode(AdminItemFilesPageWire.self, from: raw.data)
            allFiles.append(contentsOf: page.items)
            guard page.page?.hasMore == true else { break }
            guard let next = page.page?.nextCursor, !next.isEmpty, seenCursors.insert(next).inserted else {
                throw APIv2Error.incompleteCatalogRead
            }
            cursor = next
        }
        return allFiles
    }

    // MARK: - Admin Metadata Translation

    func translateAdminItemMetadata(
        id: String,
        request: AdminTranslateMetadataRequest,
        auth suppliedAuth: CapturedOrdinaryRequestAuth? = nil
    ) async throws -> AdminMetadataTranslationJob {
        guard let auth = await ownerOrCurrent(suppliedAuth) else { throw HTTPError.requestIdentityChanged }
        let segment = try catalogPathSegment(id)
        let body = try Self.snakeCaseJSONEncoder().encode(request)
        let raw = try await ownedRequest(
            method: "POST",
            path: "/api/v2/admin/items/\(segment)/metadata-translation",
            body: body,
            auth: auth
        )
        guard raw.statusCode == 200 || raw.statusCode == 202 else {
            throw APIv2Error.httpStatus(raw.statusCode)
        }
        return try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url)
            .decode(AdminMetadataTranslationJob.self, from: raw.data)
    }

    func adminMetadataTranslationJobs(
        id: String,
        auth suppliedAuth: CapturedOrdinaryRequestAuth? = nil
    ) async throws -> [AdminMetadataTranslationJob] {
        guard let auth = await ownerOrCurrent(suppliedAuth) else { throw HTTPError.requestIdentityChanged }
        let segment = try catalogPathSegment(id)
        let raw = try await ownedRequest(
            method: "GET",
            path: "/api/v2/admin/items/\(segment)/metadata-translation/jobs",
            auth: auth
        )
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        return try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url)
            .decode(AdminMetadataTranslationJobsResponse.self, from: raw.data)
            .jobs
    }

    // MARK: - Helpers

    private static func snakeCaseJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func artworkUploadMultipartBody(
        slot: String,
        image: ValidatedUploadImage,
        boundary: String
    ) -> Data {
        HTTPClient.multipartBody(
            parts: [
                HTTPMultipartPart(name: "type", data: Data(slot.utf8)),
                HTTPMultipartPart(
                    name: "image",
                    filename: "artwork.\(image.fileExtension)",
                    contentType: image.mimeType,
                    data: image.data
                ),
            ],
            boundary: boundary
        )
    }
}
