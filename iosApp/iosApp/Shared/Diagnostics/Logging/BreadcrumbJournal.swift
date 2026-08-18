#if os(iOS) || os(tvOS)
import Darwin
import Foundation

final class BreadcrumbJournal {
    static let defaultSegmentByteLimit = 128 * 1024
    static let defaultSegmentCount = 2

    private let directory: URL
    private let isEnabled: () -> Bool
    private let fileManager: FileManager
    private let segmentByteLimit: Int
    private let segmentCount: Int
    private var activeIndex: Int
    private let lock = NSLock()

    init(
        directory: URL? = nil,
        segmentByteLimit: Int = BreadcrumbJournal.defaultSegmentByteLimit,
        segmentCount: Int = BreadcrumbJournal.defaultSegmentCount,
        fileManager: FileManager = .default,
        isEnabled: @escaping () -> Bool
    ) {
        precondition(segmentByteLimit > 0, "Breadcrumb segment size must be positive")
        precondition(segmentCount == 2, "Breadcrumb journal v1 uses exactly two segments")
        self.directory = directory ?? BreadcrumbJournal.defaultDirectory(fileManager: fileManager)
        self.segmentByteLimit = segmentByteLimit
        self.segmentCount = segmentCount
        self.fileManager = fileManager
        self.isEnabled = isEnabled
        self.activeIndex = BreadcrumbJournal.initialActiveIndex(
            directory: self.directory,
            segmentCount: segmentCount,
            segmentByteLimit: segmentByteLimit,
            fileManager: fileManager
        )
    }

    @discardableResult
    func append(
        level: DiagnosticsLogLevel = .info,
        category: DiagnosticsLogCategory,
        tag: String,
        message: String,
        attrs: [String: DiagLogAttributeValue] = [:],
        timestamp: Date = Date(),
        captureSessionID: String = DiagLog.captureSessionID
    ) -> Bool {
        guard Self.isBreadcrumbCategory(category) else {
            #if DEBUG
            assertionFailure("Breadcrumb category must be lifecycle, playback, or focus")
            #endif
            return false
        }
        guard let rendered = DiagLog.renderedLine(
            level: level,
            category: category,
            tag: tag,
            message: message,
            attrs: attrs,
            timestamp: timestamp,
            captureSessionID: captureSessionID
        ) else {
            return false
        }
        return appendRenderedLine(rendered)
    }

    @discardableResult
    func append(_ line: DiagnosticsLogLine) -> Bool {
        guard Self.isBreadcrumbCategory(line.cat) else {
            #if DEBUG
            assertionFailure("Breadcrumb category must be lifecycle, playback, or focus")
            #endif
            return false
        }
        do {
            try line.validate()
            let data = try DiagnosticsJSONCoding.makeEncoder().encode(line)
            guard let rendered = String(data: data, encoding: .utf8) else {
                return false
            }
            return appendRenderedLine(rendered)
        } catch {
            assertionFailure("Invalid breadcrumb line: \(error)")
            return false
        }
    }

    func readAll() -> [DiagnosticsLogLine] {
        // Hold the same lock append/rotation take: segment discovery and file
        // reads must not overlap a concurrent append that rotates (and removes)
        // the active segment, which would otherwise yield truncated breadcrumbs.
        lock.lock()
        defer { lock.unlock() }

        let decoder = DiagnosticsJSONCoding.makeDecoder()
        return orderedSegmentURLs().flatMap { url in
            readCompleteLines(from: url, decoder: decoder)
        }
    }

    private func appendRenderedLine(_ line: String) -> Bool {
        let data = Data((line + "\n").utf8)
        lock.lock()
        defer { lock.unlock() }

        // A refused write clears the whole trail, not just this line: the gate
        // closing is how a "Never" choice, a sign-out, and a profile switch
        // reach the journal, and each of them requires the on-disk history to
        // be gone rather than merely frozen.
        //
        // That makes offering a line to this journal a destructive act while
        // the gate is closed, so callers must not use it to *ask* whether
        // capture is allowed. In particular, the directory at cold launch holds
        // the previous run's breadcrumbs — the tvOS abnormal-exit report's only
        // content — and this launch's capture decision does not exist until
        // after authentication. `DiagnosticsCoordinator.recordBreadcrumb` owns
        // that distinction: it stages pre-decision lines in `EarlyBootBuffer`
        // and only reaches this method once the launch's decision is in effect,
        // at which point a closed gate really is a denial.
        guard isEnabled() else {
            purgeLocked()
            return false
        }

        ensureDirectory()
        if currentSegmentSize() + data.count > segmentByteLimit {
            rotateSegment()
        }
        return writeSingleLine(data, to: segmentURL(index: activeIndex))
    }

    func purge() {
        lock.lock()
        defer { lock.unlock() }

        purgeLocked()
    }

    private func ensureDirectory() {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var mutableDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableDirectory.setResourceValues(values)
    }

    private func currentSegmentSize() -> Int {
        segmentSize(index: activeIndex)
    }

    private func segmentSize(index: Int) -> Int {
        let path = segmentURL(index: index).path
        guard let size = (try? fileManager.attributesOfItem(atPath: path)[.size]) as? NSNumber else {
            return 0
        }
        return size.intValue
    }

    private func rotateSegment() {
        activeIndex = (activeIndex + 1) % segmentCount
        let next = segmentURL(index: activeIndex)
        try? fileManager.removeItem(at: next)
    }

    private func purgeLocked() {
        try? fileManager.removeItem(at: directory)
        activeIndex = 0
    }

    private func segmentURL(index: Int) -> URL {
        directory.appendingPathComponent("breadcrumbs-\(index).jsonl", isDirectory: false)
    }

    private func orderedSegmentURLs() -> [URL] {
        (0..<segmentCount)
            .map { index in
                let url = segmentURL(index: index)
                let attributes = try? fileManager.attributesOfItem(atPath: url.path)
                let modifiedAt = attributes?[.modificationDate] as? Date ?? .distantPast
                return (index: index, url: url, modifiedAt: modifiedAt)
            }
            .filter { fileManager.fileExists(atPath: $0.url.path) }
            .sorted {
                if $0.modifiedAt == $1.modifiedAt {
                    return $0.index < $1.index
                }
                return $0.modifiedAt < $1.modifiedAt
            }
            .map(\.url)
    }

    private func readCompleteLines(from url: URL, decoder: JSONDecoder) -> [DiagnosticsLogLine] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return []
        }
        var slices = data.split(separator: 10, omittingEmptySubsequences: true)
        if data.last != 10, !slices.isEmpty {
            slices.removeLast()
        }
        return slices.compactMap { slice in
            guard let line = try? decoder.decode(DiagnosticsLogLine.self, from: Data(slice)),
                  (try? line.validate()) != nil else {
                return nil
            }
            return line
        }
    }

    private func writeSingleLine(_ data: Data, to url: URL) -> Bool {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            return false
        }
        defer { Darwin.close(fd) }

        let written = data.withUnsafeBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else {
                return 0
            }
            return Darwin.write(fd, baseAddress, buffer.count)
        }
        return written == data.count
    }

    private static func isBreadcrumbCategory(_ category: DiagnosticsLogCategory) -> Bool {
        category == .lifecycle || category == .playback || category == .focus
    }

    private static func defaultDirectory(fileManager: FileManager) -> URL {
        DiagnosticsStorageRoot.baseDirectory(fileManager: fileManager)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("breadcrumbs", isDirectory: true)
    }

    private static func initialActiveIndex(
        directory: URL,
        segmentCount: Int,
        segmentByteLimit: Int,
        fileManager: FileManager
    ) -> Int {
        let candidates = (0..<segmentCount).compactMap { index -> (Int, Date, Int)? in
            let url = directory.appendingPathComponent("breadcrumbs-\(index).jsonl", isDirectory: false)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
                return nil
            }
            let modifiedAt = attributes[.modificationDate] as? Date ?? .distantPast
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            return (index, modifiedAt, size)
        }
        if let writable = candidates
            .filter({ $0.2 < segmentByteLimit })
            .max(by: { $0.1 < $1.1 }) {
            return writable.0
        }
        return 0
    }
}
#endif
