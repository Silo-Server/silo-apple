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
            // Known limitation: MetricKit delivers crash/hang diagnostics
            // later (often at the next launch), so this binds the report to
            // the server/account active at delivery time via captureContext().
            // If the user switched servers/accounts between the incident and
            // delivery, the report binds to the current one.
            guard let context = await DiagnosticsCoordinator.shared.captureContext(
                applicationVersionOverride: applicationVersion
            ) else {
                return
            }
            // MetricKit exposes a reporting interval, not the instant or local
            // run that produced a crash/hang. A relaunch can occur before that
            // interval ends, so timestamp filtering cannot safely distinguish
            // failed-run breadcrumbs/logs from the new session. Keep only the
            // MetricKit diagnostic and post-restart device snapshot until a
            // reliable incident/run correlation is available.
            let report = try? Self.captureFixtureDiagnostic(
                rawJSON: rawJSON,
                type: type,
                periodStart: periodStart,
                periodEnd: periodEnd,
                context: context,
                store: PendingReportStore.shared,
                deviceSnapshotBuilder: .live
            )
            if report != nil {
                NotificationCenter.default.post(name: .diagnosticsPendingReportCreated, object: nil)
            }
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
        deviceSnapshotBuilder: DeviceSnapshotBuilder
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
            // MetricKit does not expose a local run/incident identifier. A
            // binding-scoped recent-session list can include playback from the
            // relaunch that receives this payload, so it cannot be attributed
            // safely to the diagnostic.
            playbackSessionIDs: []
        )

        let artifacts = [
            PendingReportArtifact(relativePath: "crash/metrickit.json", data: rawJSON),
            // Freeze the intentional absence of attributable logs. Without
            // this sentinel, bundle construction falls back to the live ring
            // of the later launch that receives MetricKit data.
            PendingReportArtifact(relativePath: "logs.jsonl", data: Data()),
        ]

        return try store.save(PendingReportCapture(
            binding: context.binding,
            profileID: context.profileID,
            type: type,
            fingerprint: fingerprint,
            capturedAt: periodEnd,
            manifest: manifest,
            deviceSnapshot: device,
            artifacts: artifacts,
            issueFingerprint: MetricKitDiagnosticParser.issueFingerprint(for: rawJSON, type: type)
        ))
    }
}

enum MetricKitDiagnosticParser {
    static func fingerprint(for rawJSON: Data) -> String {
        DiagnosticsSHA256.hex(data: canonicalJSON(rawJSON))
    }

    /// Groups repeats of one crash or hang: the build, the exception, and the
    /// top of the attributed call stack. Unlike `fingerprint(for:)` it leaves
    /// out everything that differs from one event to the next.
    static func issueFingerprint(
        for rawJSON: Data,
        type: ReportType,
        appBinaryName: String? = Bundle.main.infoDictionary?["CFBundleExecutable"] as? String
    ) -> String {
        let object = (try? JSONSerialization.jsonObject(with: rawJSON)) as? [String: Any] ?? [:]
        let metadata = object["diagnosticMetaData"] as? [String: Any] ?? [:]
        let reason = metadata["objectiveCexceptionReason"] as? [String: Any] ?? [:]
        let exception = ["appBuildVersion", "exceptionType", "exceptionCode", "signal"]
            .map { key in metadata[key].map { "\($0)" } ?? "" }
            + ["exceptionName", "className"].map { key in reason[key].map { "\($0)" } ?? "" }
        let frames = attributedTopFrames(in: object["callStackTree"], appBinaryName: appBinaryName, limit: 8)
        let key = ([type.rawValue] + exception + frames).joined(separator: "|")
        return DiagnosticsSHA256.hex(data: Data(key.utf8))
    }

    /// The top frames of the attributed thread (or the first thread). MetricKit
    /// nests each frame's caller in its `subFrames`, so the root frame is the
    /// top of the stack: the crash site, or a hang's busiest frame. The walk
    /// reads arrays only, never dictionary order, which is not stable between
    /// launches.
    ///
    /// The top frames of a signal or an uncaught exception are often the same
    /// system frames for every crash, so when none of them is in the app's
    /// own binary the first app frame further down is added.
    private static func attributedTopFrames(in tree: Any?, appBinaryName: String?, limit: Int) -> [String] {
        guard let stacks = (tree as? [String: Any])?["callStacks"] as? [[String: Any]] else {
            return []
        }
        let stack = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks.first
        var level = stack?["callStackRootFrames"] as? [[String: Any]] ?? []
        var frames: [String] = []
        var hasAppFrame = appBinaryName == nil
        for _ in 0..<maxFingerprintStackDepth {
            guard let frame = heaviestFrame(in: level) else { break }
            let binary = frame["binaryName"].map { "\($0)" } ?? "?"
            let isAppFrame = binary == appBinaryName
            if frames.count < limit || isAppFrame {
                let offset = frame["offsetIntoBinaryTextSegment"].map { "\($0)" } ?? "?"
                frames.append("\(binary)+\(offset)")
            }
            hasAppFrame = hasAppFrame || isAppFrame
            if frames.count >= limit, hasAppFrame {
                break
            }
            level = frame["subFrames"] as? [[String: Any]] ?? []
        }
        return frames
    }

    /// Bounds the walk to the first app frame on a pathological tree.
    private static let maxFingerprintStackDepth = 512

    /// A crash stack has one frame per level. A sampled hang tree can branch;
    /// follow the branch with the most samples, breaking ties by binary and
    /// offset so the same tree always yields the same path.
    private static func heaviestFrame(in frames: [[String: Any]]) -> [String: Any]? {
        func sampleCount(_ frame: [String: Any]) -> Int {
            (frame["sampleCount"] as? NSNumber)?.intValue ?? 0
        }
        func tieBreak(_ frame: [String: Any]) -> (String, Int64) {
            (
                frame["binaryName"].map { "\($0)" } ?? "",
                (frame["offsetIntoBinaryTextSegment"] as? NSNumber)?.int64Value ?? -1
            )
        }
        return frames.min { lhs, rhs in
            let (left, right) = (sampleCount(lhs), sampleCount(rhs))
            return left != right ? left > right : tieBreak(lhs) < tieBreak(rhs)
        }
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
        return truncatedToUTF8ByteLimit(excerpt, crashTextByteLimit)
    }

    private static func summary(type: ReportType, stackExcerpt: String?) -> String {
        let prefix = type == .hang ? "Main thread hang reported by MetricKit" : "Crash reported by MetricKit"
        guard let firstFrame = stackExcerpt?.split(separator: "\n").first else {
            return prefix
        }
        // The first frame is prefixed here without its own cap, and it can
        // itself be near the limit. Trim the prefixed result the same
        // byte-safe way stackExcerpt() does so the schema's crash.summary cap
        // isn't exceeded (local validation only checks non-empty, so an
        // over-cap summary would build locally and then fail upload).
        return truncatedToUTF8ByteLimit("\(prefix): \(firstFrame)", crashTextByteLimit)
    }

    /// The byte cap DiagnosticsCrashInfo.validate() enforces on `stackExcerpt`
    /// and `summary`.
    private static let crashTextByteLimit = 8192

    /// Trims `value` to at most `maxBytes` UTF-8 bytes without splitting a
    /// character, so multibyte content can't push the result past the limit.
    private static func truncatedToUTF8ByteLimit(_ value: String, _ maxBytes: Int) -> String {
        var result = value
        while result.utf8.count > maxBytes {
            result.removeLast()
        }
        return result
    }

    private static func collectFrames(from value: Any, into frames: inout [String]) {
        if frames.count >= 12 {
            return
        }
        if let dictionary = value as? [String: Any] {
            if let rendered = renderFrame(dictionary) {
                frames.append(rendered)
            }
            // Recurse into every value once. A separate named-keys pass would
            // revisit the same subtrees (callStackRootFrames, subFrames, …),
            // appending each frame twice until the 12-frame cap.
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
