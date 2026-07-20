#if os(iOS)
import Foundation
import MetricKit

final class MetricKitCapture: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitCapture()

    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for diagnostic in payload.crashDiagnostics ?? [] {
                capture(
                    rawJSON: diagnostic.jsonRepresentation(),
                    type: .crash,
                    applicationVersion: diagnostic.applicationVersion,
                    periodStart: payload.timeStampBegin,
                    periodEnd: payload.timeStampEnd
                )
            }
            for diagnostic in payload.hangDiagnostics ?? [] {
                capture(
                    rawJSON: diagnostic.jsonRepresentation(),
                    type: .hang,
                    applicationVersion: diagnostic.applicationVersion,
                    periodStart: payload.timeStampBegin,
                    periodEnd: payload.timeStampEnd
                )
            }
        }
    }

    private func capture(
        rawJSON: Data,
        type: ReportType,
        applicationVersion: String,
        periodStart: Date,
        periodEnd: Date
    ) {
        Task {
            guard let context = await DiagnosticsCoordinator.shared.captureContext(
                applicationVersionOverride: applicationVersion
            ) else {
                return
            }
            let breadcrumbs = DiagnosticsCoordinator.shared.breadcrumbsData()
            _ = try? Self.captureFixtureDiagnostic(
                rawJSON: rawJSON,
                type: type,
                periodStart: periodStart,
                periodEnd: periodEnd,
                context: context,
                store: PendingReportStore.shared,
                deviceSnapshotBuilder: .live,
                breadcrumbsData: breadcrumbs
            )
        }
    }

    @discardableResult
    static func captureFixtureDiagnostic(
        rawJSON: Data,
        type: ReportType,
        periodStart: Date,
        periodEnd: Date,
        context: DiagnosticsCaptureContext,
        store: PendingReportStore,
        deviceSnapshotBuilder: DeviceSnapshotBuilder,
        breadcrumbsData: Data? = nil
    ) throws -> PendingReport? {
        let fingerprint = MetricKitDiagnosticParser.fingerprint(for: rawJSON)
        guard !store.hasSeenFingerprint(fingerprint, now: periodEnd) else {
            return nil
        }

        let device = deviceSnapshotBuilder.build(provenance: .postRestart)
        let crash = MetricKitDiagnosticParser.crashInfo(
            rawJSON: rawJSON,
            type: type,
            periodStart: periodStart,
            periodEnd: periodEnd
        )
        let manifest = context.makeManifestDraft(
            type: type,
            capturedAt: periodEnd,
            crash: crash,
            deviceSummary: deviceSnapshotBuilder.deviceSummary(from: device),
            playbackSessionIDs: RecentSessionTracker.shared.recentSessionIDs()
        )

        var artifacts = [
            PendingReportArtifact(relativePath: "crash/metrickit.json", data: rawJSON),
        ]
        if let breadcrumbsData, !breadcrumbsData.isEmpty {
            artifacts.append(PendingReportArtifact(relativePath: "breadcrumbs.jsonl", data: breadcrumbsData))
        }

        return try store.save(PendingReportCapture(
            binding: context.binding,
            profileID: context.profileID,
            type: type,
            fingerprint: fingerprint,
            capturedAt: periodEnd,
            manifest: manifest,
            deviceSnapshot: device,
            artifacts: artifacts
        ))
    }
}

enum MetricKitDiagnosticParser {
    static func fingerprint(for rawJSON: Data) -> String {
        DiagnosticsSHA256.hex(data: canonicalJSON(rawJSON))
    }

    static func crashInfo(
        rawJSON: Data,
        type: ReportType,
        periodStart: Date,
        periodEnd: Date
    ) -> DiagnosticsCrashInfo {
        let stackExcerpt = stackExcerpt(from: rawJSON)
        let summary = summary(type: type, stackExcerpt: stackExcerpt)
        return DiagnosticsCrashInfo(
            summary: summary,
            stackExcerpt: stackExcerpt,
            thread: nil,
            foreground: nil,
            source: .metrickit,
            provenance: .metricReportingPeriod,
            occurredAt: DiagnosticsTimestamp.string(from: periodEnd),
            occurredAtStart: DiagnosticsTimestamp.string(from: periodStart),
            occurredAtEnd: DiagnosticsTimestamp.string(from: periodEnd)
        )
    }

    private static func canonicalJSON(_ rawJSON: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: rawJSON),
              JSONSerialization.isValidJSONObject(object),
              let canonical = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
              ) else {
            return rawJSON
        }
        return canonical
    }

    private static func stackExcerpt(from rawJSON: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: rawJSON) else {
            return nil
        }
        var frames: [String] = []
        collectFrames(from: object, into: &frames)
        guard !frames.isEmpty else {
            return nil
        }
        let excerpt = frames.prefix(12).joined(separator: "\n")
        if excerpt.utf8.count <= 8192 {
            return excerpt
        }
        return String(excerpt.prefix(8192))
    }

    private static func summary(type: ReportType, stackExcerpt: String?) -> String {
        let prefix = type == .hang ? "Main thread hang reported by MetricKit" : "Crash reported by MetricKit"
        guard let firstFrame = stackExcerpt?.split(separator: "\n").first else {
            return prefix
        }
        return "\(prefix): \(firstFrame)"
    }

    private static func collectFrames(from value: Any, into frames: inout [String]) {
        if frames.count >= 12 {
            return
        }
        if let dictionary = value as? [String: Any] {
            if let rendered = renderFrame(dictionary) {
                frames.append(rendered)
            }
            for key in ["callStackRootFrames", "subFrames", "frames", "callStacks", "threadAttributedCallStack"] {
                if let nested = dictionary[key] {
                    collectFrames(from: nested, into: &frames)
                }
            }
            for nested in dictionary.values {
                collectFrames(from: nested, into: &frames)
            }
        } else if let array = value as? [Any] {
            for element in array {
                collectFrames(from: element, into: &frames)
                if frames.count >= 12 {
                    break
                }
            }
        }
    }

    private static func renderFrame(_ dictionary: [String: Any]) -> String? {
        let symbol = firstString(dictionary, keys: ["symbol", "symbolName", "functionName", "binaryName", "module"])
        let offset = firstNumberString(dictionary, keys: ["offsetIntoBinaryTextSegment", "offset", "address"])
        guard let symbol else {
            return nil
        }
        if let offset {
            return "\(symbol) \(offset)"
        }
        return symbol
    }

    private static func firstString(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func firstNumberString(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? NSNumber {
                return value.stringValue
            }
            if let value = dictionary[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
#endif
