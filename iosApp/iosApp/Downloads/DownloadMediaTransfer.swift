import Foundation

/// Moving a finished download's media file between the app container and an
/// external folder. `DownloadManager` runs the moves one at a time and
/// updates the record; this holds the selection and file work.
///
/// A move copies to `<media>.partial` and checks the size off the main
/// actor, then renames it into place on the main actor in the same step that
/// switches the record's volume, so a newer download of the record can't be
/// replaced by an older copy. The source goes only after the record is
/// saved, so a move cut short at any point leaves the record naming a
/// complete file.
enum DownloadMediaTransfer {
    struct Job: Equatable {
        let record: DownloadRecord
        let target: DownloadMediaVolume
    }

    enum TransferError: Error {
        case sizeMismatch
    }

    /// The next finished download whose media is waiting to move to a
    /// reachable volume, from a reachable one. Oldest download first, so
    /// moves finish in the order downloads did.
    static func nextJob(
        records: some Sequence<DownloadRecord>,
        isAvailable: (DownloadMediaVolume) -> Bool,
        skipping skipped: Set<String>
    ) -> Job? {
        records
            .filter { record in
                guard let target = record.pendingMediaVolume,
                      target != record.resolvedMediaVolume,
                      record.isPlayableOffline,
                      !skipped.contains(record.id) else { return false }
                return isAvailable(target) && isAvailable(record.resolvedMediaVolume)
            }
            .min { lhs, rhs in
                let left = lhs.downloadedAt ?? .distantPast
                let right = rhs.downloadedAt ?? .distantPast
                return left == right ? lhs.id < rhs.id : left < right
            }
            .map { Job(record: $0, target: $0.pendingMediaVolume ?? .device) }
    }

    /// The pending moves after the user picks where downloads go. With
    /// `moveExisting`, every finished download not already there moves.
    /// Otherwise only downloads still waiting to move follow the new choice;
    /// the rest stay where they are.
    static func retargeted(
        _ record: DownloadRecord, to target: DownloadMediaVolume, moveExisting: Bool
    ) -> DownloadMediaVolume? {
        guard record.isPlayableOffline else { return nil }
        let waiting = record.pendingMediaVolume != nil
        guard moveExisting || waiting else { return record.pendingMediaVolume }
        return record.resolvedMediaVolume == target ? nil : target
    }

    /// Copies `source` beside `destination` as `<destination>.partial` and
    /// checks its size, returning the partial file. Slow for large files on a
    /// USB drive; run it off the main actor.
    static func copyToPartial(_ source: URL, for destination: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        do {
            try fm.copyItem(at: source, to: partial)
            let expected = fileSize(source)
            guard expected > 0, fileSize(partial) == expected else { throw TransferError.sizeMismatch }
            return partial
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    /// Renames a checked partial file into place, replacing any file there.
    /// A rename within one folder, so quick enough for the main actor.
    static func finish(_ partial: URL, at destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    /// Whether a volume's download tree is there, read fresh: the drive may
    /// have gone since the last availability refresh.
    static func isReachable(_ root: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.deletingLastPathComponent().path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Removes a media file and, when nothing else is left in it, its
    /// download folder. A download's folder in the app container keeps its
    /// manifest and artwork; one on an external folder held only media.
    static func removeMedia(at url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        let folder = url.deletingLastPathComponent()
        if (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? fm.removeItem(at: folder)
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
