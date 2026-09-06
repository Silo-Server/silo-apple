import Foundation

struct APIv2DownloadManifest: Decodable {
    let value: OfflineManifest

    init(from decoder: Decoder) throws {
        value = try OfflineManifest(from: decoder)
        guard value.manifestVersion == 3, let revision = value.revision, revision > 0,
              value.generatedAt != nil else { throw DownloadOwnershipError.incompleteAction }
    }

    func validated(for record: DownloadRecord) throws -> OfflineManifest {
        try validated(downloadID: record.id, contentID: record.contentId, episodeID: record.episodeId,
                      mediaFileID: record.mediaFileId, revision: record.revision)
    }

    func validated(downloadID: String, contentID: String, episodeID: String?, mediaFileID: Int,
                   revision: Int?) throws -> OfflineManifest {
        guard value.downloadId == downloadID, value.contentId == contentID,
              value.episodeId == episodeID, value.mediaFileId == mediaFileID,
              value.revision == revision else { throw DownloadOwnershipError.stale }
        for (path, kind) in [(value.artworkUrls?.poster, "poster"), (value.artworkUrls?.backdrop, "backdrop"),
                             (value.artworkUrls?.logo, "logo")] {
            if let path { try Self.validateAsset(path, downloadID: downloadID, artwork: kind) }
        }
        for subtitle in value.subtitles ?? [] {
            try Self.validateAsset(subtitle.fetchUrl, downloadID: downloadID, artwork: nil)
        }
        return value
    }

    static func validateAsset(_ path: String, downloadID: String, artwork: String?) throws {
        guard let url = URLComponents(string: path), url.scheme == nil, url.host == nil,
              url.fragment == nil else { throw DownloadOwnershipError.wrongAuthority }
        let base = try DownloadRegistryV2.path(id: downloadID)
        if let artwork {
            guard url.percentEncodedPath == base + "/artwork/" + artwork else { throw DownloadOwnershipError.wrongAuthority }
        } else {
            let prefix = base + "/subtitles/"
            guard url.percentEncodedPath.hasPrefix(prefix) else { throw DownloadOwnershipError.wrongAuthority }
            let suffix = String(url.percentEncodedPath.dropFirst(prefix.count))
            guard let decoded = suffix.removingPercentEncoding, !decoded.isEmpty, decoded != ".", decoded != "..",
                  !decoded.contains("/"), !decoded.contains("\\") else { throw DownloadOwnershipError.wrongAuthority }
        }
    }

    static func fileURL(origin: String, downloadID: String) throws -> URL {
        guard let url = URL(string: origin + (try DownloadRegistryV2.path(id: downloadID)) + "/file") else {
            throw DownloadOwnershipError.incompleteAction
        }
        return url
    }
}
