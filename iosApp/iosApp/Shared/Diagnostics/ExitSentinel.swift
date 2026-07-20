#if os(tvOS)
import Foundation

struct ExitSentinelMarker: Codable, Equatable {
    let runID: String
    let startedAt: String

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case startedAt = "started_at"
    }

    var startedAtDate: Date {
        DiagnosticsDates.date(from: startedAt) ?? .distantPast
    }
}

final class ExitSentinel {
    static let shared = ExitSentinel()

    // Consent gate, wired by DiagnosticsCoordinator to the same signal that
    // gates breadcrumb capture (mode != never for the active binding). While
    // disabled the sentinel neither arms nor reports, and any marker left on
    // disk is removed.
    var captureEnabled: () -> Bool = { true }

    private let markerURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var leftoverMarker: ExitSentinelMarker?

    init(markerURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.markerURL = markerURL ?? appSupport
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("exit-sentinel.json", isDirectory: false)
    }

    func appDidEnterForeground(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }

        guard captureEnabled() else {
            leftoverMarker = nil
            try? fileManager.removeItem(at: markerURL)
            return
        }

        if let marker = readMarker(), marker.runID != DiagLog.captureSessionID {
            leftoverMarker = marker
        } else if readMarker()?.runID == DiagLog.captureSessionID {
            return
        }
        writeMarker(ExitSentinelMarker(
            runID: DiagLog.captureSessionID,
            startedAt: DiagnosticsTimestamp.string(from: now)
        ))
    }

    func purge() {
        lock.lock()
        defer { lock.unlock() }

        leftoverMarker = nil
        try? fileManager.removeItem(at: markerURL)
    }

    func appDidLaunch(now: Date = Date()) {
        appDidEnterForeground(now: now)
    }

    func appDidEnterBackground() {
        clearMarker()
    }

    func appWillTerminate() {
        clearMarker()
    }

    func captureLeftoverIfNeeded() async {
        let marker = currentLeftoverMarker()
        guard let marker else { return }
        let captured = await DiagnosticsCoordinator.shared.captureAbnormalExit(marker: marker)
        if captured {
            clearLeftoverMarker()
        }
    }

    private func currentLeftoverMarker() -> ExitSentinelMarker? {
        lock.lock()
        defer { lock.unlock() }
        return leftoverMarker
    }

    private func clearLeftoverMarker() {
        lock.lock()
        defer { lock.unlock() }
        leftoverMarker = nil
    }

    private func readMarker() -> ExitSentinelMarker? {
        guard let data = try? Data(contentsOf: markerURL) else {
            return nil
        }
        return try? DiagnosticsJSONCoding.makeDecoder().decode(ExitSentinelMarker.self, from: data)
    }

    private func writeMarker(_ marker: ExitSentinelMarker) {
        do {
            try fileManager.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var directory = markerURL.deletingLastPathComponent()
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            let data = try DiagnosticsJSONCoding.makeEncoder().encode(marker)
            try data.write(to: markerURL, options: .atomic)
        } catch {
            return
        }
    }

    private func clearMarker() {
        lock.lock()
        defer { lock.unlock() }

        try? fileManager.removeItem(at: markerURL)
    }
}
#endif
