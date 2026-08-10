//
//  SidecarSubtitleFetcher.swift
//  Continuum (iOS + tvOS)
//
//  Fetches server-provided subtitle sidecar URLs (`subtitle_urls[].url`)
//  using the app's auth headers. The Silo server serves either raw
//  ASS (`text/x-ssa`) for ASS/SSA tracks or WebVTT (`text/vtt`) for every
//  other text codec. The fetcher returns the raw body + a detected
//  format; the caller (`SubtitleSession`) decides whether to feed
//  libass directly (ASS) or run the VTT converter first.
//

import Foundation

enum SidecarSubtitleFetchError: Error {
    case invalidResponse
    case statusCode(Int)
    case transport(underlying: Error)
    case emptyBody
    case responseTooLarge(maxBytes: Int)
}

struct SubtitleFontAttachment: Sendable, Equatable {
    let name: String
    let data: Data
}

actor SidecarSubtitleFetcher {

    private struct FontBundleItem: Decodable {
        let name: String
        let data: String
    }

    private struct CachedFontBundle {
        let attachments: [SubtitleFontAttachment]
        let decodedBytes: Int
    }

    static let maxFontBundleResponseBytes = 32 * 1_024 * 1_024
    static let maxFontBundleCacheBytes = 64 * 1_024 * 1_024
    private static let maxFontBundleCacheEntries = 8

    private let session: URLSession
    private let tokenStore: TokenStore
    private let fontBundleResponseByteLimit: Int
    private let fontBundleCacheByteLimit: Int
    private var fontBundleCache: [URL: CachedFontBundle] = [:]
    private var fontBundleCacheOrder: [URL] = []
    private var fontBundleCacheBytes = 0

    init(
        session: URLSession? = nil,
        tokenStore: TokenStore = .shared,
        fontBundleResponseByteLimit: Int = SidecarSubtitleFetcher.maxFontBundleResponseBytes,
        fontBundleCacheByteLimit: Int = SidecarSubtitleFetcher.maxFontBundleCacheBytes
    ) {
        self.session = session ?? Self.makeSession()
        self.tokenStore = tokenStore
        self.fontBundleResponseByteLimit = max(0, fontBundleResponseByteLimit)
        self.fontBundleCacheByteLimit = max(0, fontBundleCacheByteLimit)
    }

    /// Auth-gated sidecar fetches must not share `URLSession.shared`'s cache:
    /// the cache is keyed by URL alone, so a response fetched under one
    /// profile can be served to a request under a different profile.
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    /// Fetch a subtitle sidecar. Raises `SidecarSubtitleFetchError` on
    /// network failure, non-2xx response, or empty body. The body is
    /// returned as a `String` — subtitle content is always text.
    func fetch(
        url: URL,
        preferredFormatHint: SubtitleFormat? = nil
    ) async throws -> (content: String, format: SubtitleFormat) {
        // Offline downloads carry `file://` sidecar URLs. URLSession would
        // load them, but the response is a plain `URLResponse` (not
        // `HTTPURLResponse`), so the status-code path below would reject it.
        // Read the local file directly instead — no auth, no network.
        if url.isFileURL {
            return try readLocalSubtitle(url: url, preferredFormatHint: preferredFormatHint)
        }

        let request = await buildRequest(url: url)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SidecarSubtitleFetchError.transport(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SidecarSubtitleFetchError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SidecarSubtitleFetchError.statusCode(http.statusCode)
        }
        guard !data.isEmpty else {
            throw SidecarSubtitleFetchError.emptyBody
        }

        // Subtitle files should be UTF-8. Tolerate occasional stray bytes
        // by falling back to `String(decoding:as:)`, which replaces invalid
        // sequences with U+FFFD rather than failing.
        let content: String
        if let utf8 = String(data: data, encoding: .utf8) {
            content = utf8
        } else {
            content = String(decoding: data, as: UTF8.self)
        }

        let format = detectFormat(
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            urlHint: url,
            codecHint: preferredFormatHint,
            body: content
        )
        return (content, format)
    }

    /// Fetch the server's JSON/base64 font bundle for an authored ASS track.
    func fetchFontBundle(url: URL) async throws -> [SubtitleFontAttachment] {
        if let cached = fontBundleCache[url] {
            markFontBundleRecentlyUsed(url)
            return cached.attachments
        }

        var request = await buildRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw SidecarSubtitleFetchError.transport(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SidecarSubtitleFetchError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SidecarSubtitleFetchError.statusCode(http.statusCode)
        }
        let declaredLength = max(
            http.expectedContentLength,
            http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) ?? -1
        )
        guard declaredLength <= Int64(fontBundleResponseByteLimit) else {
            throw SidecarSubtitleFetchError.responseTooLarge(
                maxBytes: fontBundleResponseByteLimit
            )
        }

        var data = Data()
        if declaredLength > 0 {
            data.reserveCapacity(Int(declaredLength))
        }
        do {
            for try await byte in bytes {
                guard data.count < fontBundleResponseByteLimit else {
                    throw SidecarSubtitleFetchError.responseTooLarge(
                        maxBytes: fontBundleResponseByteLimit
                    )
                }
                data.append(byte)
            }
        } catch let error as SidecarSubtitleFetchError {
            throw error
        } catch {
            throw SidecarSubtitleFetchError.transport(underlying: error)
        }

        let items: [FontBundleItem]
        do {
            items = try JSONDecoder().decode([FontBundleItem].self, from: data)
        } catch {
            throw SidecarSubtitleFetchError.transport(underlying: error)
        }
        let attachments = try items.map { item in
            guard let decoded = Data(base64Encoded: item.data) else {
                throw SidecarSubtitleFetchError.invalidResponse
            }
            return SubtitleFontAttachment(name: item.name, data: decoded)
        }
        cacheFontBundle(attachments, for: url)
        return attachments
    }

    private func markFontBundleRecentlyUsed(_ url: URL) {
        fontBundleCacheOrder.removeAll { $0 == url }
        fontBundleCacheOrder.append(url)
    }

    private func cacheFontBundle(
        _ attachments: [SubtitleFontAttachment],
        for url: URL
    ) {
        let decodedBytes = attachments.reduce(0) { $0 + $1.data.count }
        guard decodedBytes <= fontBundleCacheByteLimit,
              fontBundleCacheByteLimit > 0 else {
            return
        }

        if let replaced = fontBundleCache.removeValue(forKey: url) {
            fontBundleCacheBytes -= replaced.decodedBytes
            fontBundleCacheOrder.removeAll { $0 == url }
        }
        while (fontBundleCacheBytes + decodedBytes > fontBundleCacheByteLimit
                || fontBundleCache.count >= Self.maxFontBundleCacheEntries),
              let leastRecentlyUsed = fontBundleCacheOrder.first {
            fontBundleCacheOrder.removeFirst()
            if let evicted = fontBundleCache.removeValue(forKey: leastRecentlyUsed) {
                fontBundleCacheBytes -= evicted.decodedBytes
            }
        }

        fontBundleCache[url] = CachedFontBundle(
            attachments: attachments,
            decodedBytes: decodedBytes
        )
        fontBundleCacheBytes += decodedBytes
        fontBundleCacheOrder.append(url)
    }

    // MARK: - Local (offline) sidecars

    /// Read a downloaded sidecar straight off disk. Format detection falls
    /// back to the file extension + body sniff since there is no
    /// `Content-Type` header.
    private func readLocalSubtitle(
        url: URL,
        preferredFormatHint: SubtitleFormat?
    ) throws -> (content: String, format: SubtitleFormat) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SidecarSubtitleFetchError.transport(underlying: error)
        }
        guard !data.isEmpty else {
            throw SidecarSubtitleFetchError.emptyBody
        }

        let content: String
        if let utf8 = String(data: data, encoding: .utf8) {
            content = utf8
        } else {
            content = String(decoding: data, as: UTF8.self)
        }

        let format = detectFormat(
            contentType: nil,
            urlHint: url,
            codecHint: preferredFormatHint,
            body: content
        )
        return (content, format)
    }

    // MARK: - Request building

    private func buildRequest(url: URL) async -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Accept header advertises what we can handle. The server ignores
        // it today but it sets the expectation cleanly.
        request.setValue(
            "text/vtt, text/x-ssa, text/plain;q=0.5, */*;q=0.1",
            forHTTPHeaderField: "Accept"
        )

        if let token = await tokenStore.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let profileId = await tokenStore.getProfileId() {
            request.setValue(profileId, forHTTPHeaderField: "X-Profile-Id")
        }
        if let profileToken = await tokenStore.getProfileToken() {
            request.setValue(profileToken, forHTTPHeaderField: "X-Profile-Token")
        }
        return request
    }

    // MARK: - Format detection

    /// Priority: content-type header → URL extension → caller's codec hint
    /// → sniff the first few bytes of the body. Last-resort default is
    /// WebVTT since that's what the server serves for everything except
    /// ASS/SSA.
    private func detectFormat(
        contentType: String?,
        urlHint: URL,
        codecHint: SubtitleFormat?,
        body: String
    ) -> SubtitleFormat {
        if let ct = contentType?.lowercased() {
            if ct.contains("text/x-ssa") || ct.contains("text/x-ass")
                || ct.contains("application/x-ass")
                || ct.contains("application/x-ssa") {
                return .ass
            }
            if ct.contains("text/vtt") || ct.contains("application/x-webvtt") {
                return .vtt
            }
            if ct.contains("application/x-subrip") {
                return .srt
            }
        }

        let ext = urlHint.pathExtension.lowercased()
        switch ext {
        case "ass", "ssa": return .ass
        case "vtt":        return .vtt
        case "srt":        return .srt
        default: break
        }

        if let hint = codecHint { return hint }

        // Body sniff. ASS files start with `[Script Info]`. VTT files
        // start with the `WEBVTT` signature. SRT files start with a cue
        // number (digit) followed by a newline and a timestamp line
        // using `,` millisecond separators.
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[Script Info]") || trimmed.hasPrefix("[ScriptInfo]") {
            return .ass
        }
        if trimmed.hasPrefix("WEBVTT") || trimmed.hasPrefix("\u{FEFF}WEBVTT") {
            return .vtt
        }
        if let firstLine = trimmed.split(separator: "\n").first,
           Int(firstLine.trimmingCharacters(in: .whitespaces)) != nil {
            return .srt
        }

        return .vtt
    }
}
