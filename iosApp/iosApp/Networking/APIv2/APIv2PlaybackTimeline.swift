import Foundation

/// The server owns this mapping. Detail metadata may decorate it, never reorder it.
struct APIv2PlaybackManifest: Codable, Equatable, Sendable {
    static let feature = "bound_client_timeline"
    let installationId: String
    let timelineId: String
    let mediaItemId: String
    let editionId: String
    let durationSeconds: Double
    let parts: [Part]

    struct Part: Codable, Equatable, Sendable {
        let fileId: String
        let offsetSeconds: Double
        let durationSeconds: Double
    }

    func validate(installation: String, item: String, anchor: Int) throws {
        guard installationId == installation, mediaItemId == item, !editionId.isEmpty,
              Self.validDigest(timelineId), durationSeconds.isFinite, durationSeconds > 0,
              !parts.isEmpty, parts.count <= 4096,
              parts.contains(where: { $0.fileId == String(anchor) }) else {
            throw PlaybackSequencedError.invalidResponse
        }
        var offset = 0.0
        var ids: Set<String> = []
        for part in parts {
            guard let id = Int(part.fileId), id > 0, String(id) == part.fileId,
                  ids.insert(part.fileId).inserted,
                  part.offsetSeconds.isFinite, abs(part.offsetSeconds - offset) < 0.000001,
                  part.durationSeconds.isFinite, part.durationSeconds > 0 else {
                throw PlaybackSequencedError.invalidResponse
            }
            offset += part.durationSeconds
        }
        guard offset.isFinite, abs(offset - durationSeconds) < 0.000001 else {
            throw PlaybackSequencedError.invalidResponse
        }
    }

    static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    func binding(fileID: Int) throws -> APIv2ProgressTimeline {
        guard let part = parts.first(where: { $0.fileId == String(fileID) }) else {
            throw PlaybackSequencedError.invalidResponse
        }
        return APIv2ProgressTimeline(timelineId: timelineId, mediaItemId: mediaItemId,
            fileId: part.fileId, partOffsetSeconds: part.offsetSeconds,
            partDurationSeconds: part.durationSeconds, durationSeconds: durationSeconds)
    }
}

struct APIv2ProgressTimeline: Codable, Equatable, Sendable {
    let timelineId: String
    let mediaItemId: String
    let fileId: String
    let partOffsetSeconds: Double
    let partDurationSeconds: Double
    let durationSeconds: Double

    func validate() throws {
        guard APIv2PlaybackManifest.validDigest(timelineId), !mediaItemId.isEmpty,
              let id = Int(fileId), id > 0, String(id) == fileId,
              partOffsetSeconds.isFinite, partOffsetSeconds >= 0,
              partDurationSeconds.isFinite, partDurationSeconds > 0,
              durationSeconds.isFinite, durationSeconds > 0,
              partOffsetSeconds + partDurationSeconds <= durationSeconds + 0.000001 else {
            throw PlaybackSequencedError.invalidResponse
        }
    }

    func validateReceipt(_ sample: PlaybackSequencedSample?) throws {
        guard let sample, sample.timelineId == timelineId,
              sample.position <= partDurationSeconds,
              let global = sample.itemPosition, global.isFinite,
              abs(global - (partOffsetSeconds + sample.position)) < 0.000001 else {
            throw PlaybackSequencedError.invalidResponse
        }
    }
}

extension APIv2Client {
    func playbackManifest(fileID: Int, installationID: String, itemID: String,
                          auth: CapturedOrdinaryRequestAuth) async throws -> APIv2PlaybackManifest {
        guard fileID > 0 else { throw PlaybackSequencedError.invalidSample }
        let raw = try await playbackRequest(method: "GET", suffix: "/timelines/\(fileID)", auth: auth,
            query: ["installation_id": installationID])
        guard raw.statusCode == 200 else { throw PlaybackSequencedError.invalidResponse }
        let manifest = try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackManifest.self, from: raw.data)
        try manifest.validate(installation: installationID, item: itemID, anchor: fileID)
        return manifest
    }
}
