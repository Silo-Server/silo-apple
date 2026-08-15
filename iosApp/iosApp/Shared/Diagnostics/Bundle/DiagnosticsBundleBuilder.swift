#if os(iOS) || os(tvOS)
import Foundation
import zlib

struct DiagnosticsBundleBuildResult {
    let manifest: DiagnosticsManifest
    let manifestData: Data
    let bundleData: Data
    /// Sanitized members retained locally so stale hosted consent can be
    /// reframed without ever reopening raw evidence under a rotated token set.
    let archiveEntries: [PendingReportArtifact]
}

struct DiagnosticsBundleBuilder {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func build(
        report: PendingReport,
        logLines: [String],
        droppedLogLines: Int,
        redactionTokens: [String] = []
    ) throws -> DiagnosticsBundleBuildResult {
        let isHosted = report.binding.binding.destinationChoice == .hosted
        let rawLogsData = Data(
            logLines.joined(separator: "\n").appending(logLines.isEmpty ? "" : "\n").utf8
        )
        let destinationSafeLogsData = isHosted
            ? Self.sanitizeHostedLogJSONL(rawLogsData)
            : rawLogsData
        let hostedNormalizedLogsData = isHosted
            ? Self.normalizeHostedTextualIdentifiers(
                name: "logs.jsonl",
                data: destinationSafeLogsData
            )
            : destinationSafeLogsData
        let logsData = Self.scrubTextualEntry(
            name: "logs.jsonl",
            data: hostedNormalizedLogsData,
            tokens: redactionTokens
        )
        let logsGzipSize = (try? Self.gzip(logsData).count) ?? 0
        var draft = report.manifest
        if isHosted {
            draft.report = Self.sanitizeHostedReport(draft.report)
            draft.deviceSummary = Self.sanitizeHostedDeviceSummary(draft.deviceSummary)
            if let crash = draft.crash {
                draft.crash = Self.sanitizeHostedCrashInfo(crash)
            }
        }
        draft.logSummary = makeLogSummary(
            logsData: logsData,
            logsGzipSize: logsGzipSize,
            droppedLines: droppedLogLines,
            debugLogging: draft.logSummary.debugLogging
        )

        var entries: [(String, Data)] = []
        func appendEntry(_ name: String, _ data: Data) throws {
            let destinationSafeData: Data
            if isHosted, name == "breadcrumbs.jsonl" {
                destinationSafeData = Self.sanitizeHostedLogJSONL(data)
            } else if isHosted, name == "device.json" {
                destinationSafeData = try Self.sanitizeHostedDeviceJSON(data)
            } else if isHosted, name == "crash/metrickit.json" {
                destinationSafeData = try Self.sanitizeHostedMetricKitJSON(data)
            } else if isHosted, name == "crash/stack.txt" {
                destinationSafeData = Self.sanitizeHostedCrashTextData(data)
            } else {
                destinationSafeData = data
            }
            let hostedSafeData = isHosted
                ? Self.normalizeHostedTextualIdentifiers(name: name, data: destinationSafeData)
                : destinationSafeData
            entries.append((
                name,
                Self.scrubTextualEntry(
                    name: name,
                    data: hostedSafeData,
                    tokens: redactionTokens
                )
            ))
        }

        let manifestDraftData = try DiagnosticsJSONCoding.makeEncoder().encode(draft)
        try appendEntry("manifest.json", manifestDraftData)
        try appendEntry("device.json", try readRequired("device.json", from: report.directoryURL))
        try appendEntry("logs.jsonl", logsData)

        if let crash = draft.crash {
            try appendEntry("crash/summary.json", try DiagnosticsJSONCoding.makeEncoder().encode(crash))
        }

        for artifact in ["crash/stack.txt", "crash/tombstone.pb", "crash/metrickit.json", "breadcrumbs.jsonl"] {
            // Native tombstones are opaque binary evidence. The hosted
            // collector cannot inspect them for private identifiers, so keep
            // this artifact available only to the existing self-hosted path.
            if isHosted, artifact == "crash/tombstone.pb" {
                continue
            }
            let url = report.directoryURL.appendingPathComponent(artifact)
            guard fileManager.fileExists(atPath: url.path),
                  !entries.contains(where: { $0.0 == artifact }) else {
                continue
            }
            try appendEntry(artifact, try Data(contentsOf: url))
        }

        return try finalize(entries: entries, isHosted: isHosted, redactionTokens: redactionTokens)
    }

    func reframeHosted(
        cached: DiagnosticsBundleBuildResult,
        consent: DiagnosticsManifest.Consent
    ) throws -> DiagnosticsBundleBuildResult {
        guard cached.manifest.destination.serverInstanceID == HostedDiagnosticsCapabilities.pinnedCollectorID,
              cached.manifest.report.profileID == nil,
              cached.manifest.playbackSessionIds.isEmpty,
              !cached.manifest.archive.entries.contains("crash/tombstone.pb"),
              cached.archiveEntries.map(\.relativePath) == cached.manifest.archive.entries,
              let embedded = cached.archiveEntries.first,
              embedded.relativePath == "manifest.json" else {
            throw DiagnosticsBundleError.invalidHostedEnvelope
        }
        var draft = try DiagnosticsJSONCoding.makeDecoder().decode(
            DiagnosticsManifestDraft.self,
            from: embedded.data
        )
        draft.consent = consent
        var entries = cached.archiveEntries.map { ($0.relativePath, $0.data) }
        entries[0] = (
            "manifest.json",
            try DiagnosticsJSONCoding.makeEncoder().encode(draft)
        )
        return try finalize(entries: entries, isHosted: true, redactionTokens: [])
    }

    func validateCachedHostedEnvelope(_ cached: DiagnosticsBundleBuildResult) throws {
        guard cached.manifest.destination.serverInstanceID == HostedDiagnosticsCapabilities.pinnedCollectorID,
              cached.manifest.report.profileID == nil,
              cached.manifest.playbackSessionIds.isEmpty,
              !cached.manifest.archive.entries.contains("crash/tombstone.pb"),
              cached.archiveEntries.map(\.relativePath) == cached.manifest.archive.entries,
              cached.archiveEntries.first?.relativePath == "manifest.json",
              cached.archiveEntries.contains(where: { $0.relativePath == "device.json" }),
              cached.manifestData == (try DiagnosticsJSONCoding.makeEncoder().encode(cached.manifest)) else {
            throw DiagnosticsBundleError.invalidHostedEnvelope
        }

        let entries = cached.archiveEntries.map { ($0.relativePath, $0.data) }
        let tarData = try Self.makeTar(entries: entries)
        let bundleData = try Self.gzip(tarData)
        guard bundleData == cached.bundleData,
              cached.manifest.archive.bytes == bundleData.count,
              cached.manifest.archive.uncompressedBytes == tarData.count,
              cached.manifest.archive.sha256 == DiagnosticsSHA256.hex(data: bundleData) else {
            throw DiagnosticsBundleError.invalidHostedEnvelope
        }

        let draft = try DiagnosticsJSONCoding.makeDecoder().decode(
            DiagnosticsManifestDraft.self,
            from: cached.archiveEntries[0].data
        )
        guard draft.finalized(archive: cached.manifest.archive) == cached.manifest else {
            throw DiagnosticsBundleError.invalidHostedEnvelope
        }
    }

    private func finalize(
        entries: [(String, Data)],
        isHosted: Bool,
        redactionTokens: [String]
    ) throws -> DiagnosticsBundleBuildResult {
        guard let embeddedManifest = entries.first,
              embeddedManifest.0 == "manifest.json" else {
            throw DiagnosticsBundleError.invalidHostedEnvelope
        }
        let draft = try DiagnosticsJSONCoding.makeDecoder().decode(
            DiagnosticsManifestDraft.self,
            from: embeddedManifest.1
        )
        let tarData = try Self.makeTar(entries: entries)
        let bundleData = try Self.gzip(tarData)
        let archive = DiagnosticsManifest.Archive(
            entries: entries.map(\.0),
            bytes: bundleData.count,
            uncompressedBytes: tarData.count,
            sha256: DiagnosticsSHA256.hex(data: bundleData)
        )
        let manifest = draft.finalized(archive: archive)
        try manifest.validate()
        let finalizedManifestData = try DiagnosticsJSONCoding.makeEncoder().encode(manifest)
        let hostedNormalizedManifestData = isHosted
            ? Self.normalizeHostedTextualIdentifiers(
                name: "manifest.json",
                data: finalizedManifestData
            )
            : finalizedManifestData
        let manifestData = Self.scrubTextualEntry(
            name: "manifest.json",
            data: hostedNormalizedManifestData,
            tokens: redactionTokens
        )
        // The upload APIs consume both representations below. Decode the
        // scrubbed bytes back into the returned model so the JSON envelope can
        // never serialize an unsanitized value while the embedded manifest is
        // sanitized. Keeping one canonical sanitized object also preserves
        // collector outer-vs-embedded validation semantics.
        let sanitizedManifest = try DiagnosticsJSONCoding.makeDecoder().decode(
            DiagnosticsManifest.self,
            from: manifestData
        )
        try sanitizedManifest.validate()
        return DiagnosticsBundleBuildResult(
            manifest: sanitizedManifest,
            manifestData: manifestData,
            bundleData: bundleData,
            archiveEntries: entries.map {
                PendingReportArtifact(relativePath: $0.0, data: $0.1)
            }
        )
    }

    private func readRequired(_ relativePath: String, from directory: URL) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(relativePath))
    }

    static func scrubExactTokenMatches(in data: Data, tokens: [String]) -> Data {
        let uniqueTokens = tokens.reduce(into: [String]()) { result, token in
            guard !token.isEmpty, !result.contains(token) else {
                return
            }
            result.append(token)
        }
        guard !uniqueTokens.isEmpty else {
            return data
        }
        guard var text = String(data: data, encoding: .utf8) else {
            // Fail closed: malformed textual evidence cannot be verified as
            // token-free and must never be uploaded verbatim.
            return Data("[redaction_failed: non-utf8 content dropped]".utf8)
        }
        for token in uniqueTokens {
            text = text.replacingOccurrences(of: token, with: "[redacted_token]")
        }
        return Data(text.utf8)
    }

    /// Hosted collection uses the canonical server v1 attribute registry,
    /// which intentionally excludes private-server correlation fields. The
    /// self-hosted contract still accepts Apple's local playback extensions,
    /// so filtering belongs at bundle construction rather than log capture.
    /// Re-encoding every accepted line also fails closed for malformed frozen
    /// evidence instead of forwarding bytes the public collector cannot
    /// validate.
    static func sanitizeHostedLogJSONL(_ data: Data) -> Data {
        let decoder = DiagnosticsJSONCoding.makeDecoder()
        let encoder = DiagnosticsJSONCoding.makeEncoder()
        let rendered = data
            .split(separator: 10, omittingEmptySubsequences: true)
            .compactMap { rawLine -> String? in
                guard let line = try? decoder.decode(
                    DiagnosticsLogLine.self,
                    from: Data(rawLine)
                ), (try? line.validate()) != nil else {
                    return nil
                }
                let registered = hostedAttributeRegistry[line.cat] ?? [:]
                var safeAttributes = line.attrs?.filter { key, value in
                    registered[key]?.accepts(value) == true
                }
                if line.cat == .network,
                   case .string(let path) = safeAttributes?["path"] {
                    safeAttributes?["path"] = .string(templateHostedPrivatePathSegments(path))
                }
                safeAttributes = safeAttributes?.mapValues(sanitizeHostedJSONValue)
                let sanitized = DiagnosticsLogLine(
                    ts: line.ts,
                    run: line.run,
                    lvl: line.lvl,
                    cat: line.cat,
                    tag: sanitizeHostedMessage(line.tag),
                    msg: sanitizeHostedMessage(line.msg),
                    attrs: safeAttributes?.isEmpty == false ? safeAttributes : nil
                )
                guard let encoded = try? encoder.encode(sanitized) else {
                    return nil
                }
                return String(data: encoded, encoding: .utf8)
            }
        guard !rendered.isEmpty else {
            return Data()
        }
        return Data(rendered.joined(separator: "\n").appending("\n").utf8)
    }

    static func sanitizeHostedDeviceJSON(_ data: Data) throws -> Data {
        let snapshot = try DiagnosticsJSONCoding.makeDecoder().decode(
            DeviceSnapshotPayload.self,
            from: data
        )
        let sanitized = DeviceSnapshotPayload(
            capturedAt: snapshot.capturedAt,
            provenance: snapshot.provenance,
            identity: removeHostedDevicePrivateFields(from: snapshot.identity),
            display: removeHostedDevicePrivateFields(from: snapshot.display),
            audio: removeHostedDevicePrivateFields(from: snapshot.audio),
            videoCodecs: removeHostedDevicePrivateFields(from: snapshot.videoCodecs),
            network: removeHostedDevicePrivateFields(from: snapshot.network)
        )
        try sanitized.validate()
        return try DiagnosticsJSONCoding.makeEncoder().encode(sanitized)
    }

    /// MetricKit's JSON representation is useful crash evidence, but it can
    /// include a process-container path in `virtualMemoryRegionInfo` and other
    /// free-form strings. Keep the raw payload on disk for self-hosted reports;
    /// hosted archives instead drop that field and structurally sanitize every
    /// remaining string so a JSON escape or key ordering change cannot bypass
    /// destination-specific redaction.
    static func sanitizeHostedMetricKitJSON(_ data: Data) throws -> Data {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw DiagnosticsBundleError.invalidHostedEnvelope
        }
        let sanitized = sanitizeHostedMetricKitValue(raw)
        guard JSONSerialization.isValidJSONObject(sanitized) else {
            throw DiagnosticsBundleError.invalidHostedEnvelope
        }
        do {
            return try JSONSerialization.data(
                withJSONObject: sanitized,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw DiagnosticsBundleError.invalidHostedEnvelope
        }
    }

    private static func sanitizeHostedMetricKitValue(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, entry in
                let normalizedKey = entry.key.lowercased().filter { $0.isLetter || $0.isNumber }
                // `address` is an ASLR-sensitive absolute frame address. The
                // binary UUID plus offset retain the symbolication value, so
                // hosted reports omit it and the collector can reject this
                // otherwise ambiguous network-identity key globally.
                guard normalizedKey != "virtualmemoryregioninfo",
                      normalizedKey != "address",
                      !hasHostedBareUUID(in: entry.key) else { return }
                if normalizedKey == "binaryuuid",
                   let binaryUUID = entry.value as? String,
                   isHostedMetricKitBinaryUUID(binaryUUID) {
                    result[entry.key] = binaryUUID
                } else {
                    result[entry.key] = sanitizeHostedMetricKitValue(entry.value)
                }
            }
        }
        if let array = value as? [Any] {
            return array.map(sanitizeHostedMetricKitValue)
        }
        if let string = value as? String {
            return sanitizeHostedCrashText(string)
        }
        return value
    }

    private static func isHostedMetricKitBinaryUUID(_ value: String) -> Bool {
        let range = NSRange(location: 0, length: (value as NSString).length)
        guard let match = hostedExactMetricKitBinaryUUIDRegex.firstMatch(
            in: value,
            range: range
        ) else { return false }
        return match.range == range
    }

    private static func sanitizeHostedCrashInfo(
        _ crash: DiagnosticsCrashInfo
    ) -> DiagnosticsCrashInfo {
        DiagnosticsCrashInfo(
            summary: sanitizeHostedCrashText(crash.summary),
            stackExcerpt: crash.stackExcerpt.map(sanitizeHostedCrashText),
            thread: crash.thread.map(sanitizeHostedCrashText),
            foreground: crash.foreground,
            source: crash.source,
            provenance: crash.provenance,
            occurredAt: crash.occurredAt,
            occurredAtStart: crash.occurredAtStart,
            occurredAtEnd: crash.occurredAtEnd
        )
    }

    private static func sanitizeHostedReport(
        _ report: DiagnosticsManifest.Report
    ) -> DiagnosticsManifest.Report {
        DiagnosticsManifest.Report(
            type: report.type,
            capturedAt: report.capturedAt,
            captureSessionID: report.captureSessionID,
            appVersion: sanitizeHostedMessage(report.appVersion),
            appBuild: sanitizeHostedMessage(report.appBuild),
            platform: report.platform,
            osVersion: sanitizeHostedMessage(report.osVersion),
            profileID: nil
        )
    }

    private static func sanitizeHostedDeviceSummary(
        _ summary: DiagnosticsManifest.DeviceSummary
    ) -> DiagnosticsManifest.DeviceSummary {
        DiagnosticsManifest.DeviceSummary(
            manufacturer: sanitizeHostedMessage(summary.manufacturer),
            model: sanitizeHostedMessage(summary.model),
            os: sanitizeHostedMessage(summary.os),
            formFactor: sanitizeHostedMessage(summary.formFactor)
        )
    }

    private static func sanitizeHostedCrashText(_ value: String) -> String {
        let identifiersNormalized = sanitizeHostedMessage(value)
        let nativeLibrariesNormalized = replaceMatches(
            of: hostedNativeLibraryRegex,
            in: identifiersNormalized,
            with: "apple-native-library"
        )
        return redactHostedAbsolutePaths(in: nativeLibrariesNormalized)
    }

    private static func sanitizeHostedCrashTextData(_ data: Data) -> Data {
        guard let value = String(data: data, encoding: .utf8) else {
            return Data("[redaction_failed: non-utf8 content dropped]".utf8)
        }
        return Data(sanitizeHostedCrashText(value).utf8)
    }

    private static func removeHostedDevicePrivateFields(
        from value: DiagnosticsJSONValue
    ) -> DiagnosticsJSONValue {
        switch value {
        case .string(let string):
            return .string(sanitizeHostedMessage(string))
        case .array(let values):
            return .array(values.map { removeHostedDevicePrivateFields(from: $0) })
        case .object(let object):
            return .object(object.reduce(into: [:]) { result, entry in
                let normalizedKey = entry.key.lowercased().filter { $0.isLetter || $0.isNumber }
                guard !hostedDevicePrivateFieldKeys.contains(normalizedKey),
                      !hasHostedBareUUID(in: entry.key) else { return }
                result[entry.key] = removeHostedDevicePrivateFields(from: entry.value)
            })
        default:
            return value
        }
    }

    private static func sanitizeHostedJSONValue(
        _ value: DiagnosticsJSONValue
    ) -> DiagnosticsJSONValue {
        switch value {
        case .string(let string):
            return .string(sanitizeHostedMessage(string))
        case .array(let values):
            return .array(values.map(sanitizeHostedJSONValue))
        case .object(let object):
            return .object(object.mapValues(sanitizeHostedJSONValue))
        default:
            return value
        }
    }

    private static func sanitizeHostedPrivateIdentifierAssignments(in value: String) -> String {
        let range = NSRange(location: 0, length: (value as NSString).length)
        return hostedPrivateIdentifierAssignmentRegex.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: "[redacted_private_id]"
        )
    }

    private static func sanitizeHostedNetworkIdentityAssignments(in value: String) -> String {
        let range = NSRange(location: 0, length: (value as NSString).length)
        return hostedNetworkIdentityAssignmentRegex.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: "[redacted_network_identity]"
        )
    }

    private static func sanitizeHostedMessage(_ value: String) -> String {
        redactHostedAbsolutePaths(
            in: sanitizeHostedBarePrivateIdentifiers(
                in: sanitizeHostedContainerText(value)
            )
        )
    }

    /// Applies container-safe transformations that do not rewrite canonical
    /// report, capture, log-run, or MetricKit binary UUID fields. JSON members
    /// receive bare private-ID redaction structurally before this final pass.
    private static func sanitizeHostedContainerText(_ value: String) -> String {
        let hostsNormalized = replaceMatches(
            of: hostedStableHostTokenRegex,
            in: value,
            with: "redacted.invalid"
        )
        let identifiersRemoved = sanitizeHostedPrivateIdentifierAssignments(in: hostsNormalized)
        let networkAssignmentsRemoved = sanitizeHostedNetworkIdentityAssignments(
            in: identifiersRemoved
        )
        let numericMediaNormalized = replaceMatches(
            of: hostedNumericMediaAssignmentRegex,
            in: networkAssignmentsRemoved,
            with: "mediaSeconds"
        )
        let numericTelemetryNormalized = normalizeHostedNumericTelemetryAssignments(
            in: numericMediaNormalized
        )
        let loopbackNormalized = replaceMatches(
            of: hostedLoopbackHostRegex,
            in: numericTelemetryNormalized,
            with: "redacted.invalid"
        )
        let ambiguousLegacyNumbersRemoved = sanitizeHostedAmbiguousLegacyNumericAssignments(
            in: loopbackNormalized
        )
        return templateHostedURLPaths(in: ambiguousLegacyNumbersRemoved)
    }

    private static func sanitizeHostedAmbiguousLegacyNumericAssignments(
        in value: String
    ) -> String {
        let source = value as NSString
        let range = NSRange(location: 0, length: source.length)
        let matches = hostedAmbiguousLegacyNumericAssignmentRegex.matches(
            in: value,
            options: [],
            range: range
        )
        var rendered = value
        for match in matches.reversed() {
            let prefix = source.substring(with: match.range(at: 1))
            let sign = source.substring(with: match.range(at: 2))
            let token = source.substring(with: match.range(at: 3))
            let parts = token.split(separator: ".", omittingEmptySubsequences: false)
            let isExactSafeClockAssignment =
                sign.isEmpty &&
                (prefix.lowercased() == "ac.cur=" || prefix.lowercased() == "ac.pts=") &&
                (2...4).contains(parts.count) &&
                parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
            guard !isExactSafeClockAssignment,
                  isHostedRejectedLegacyNumericToken(token) else { continue }
            rendered = (rendered as NSString).replacingCharacters(
                in: match.range,
                with: "\(prefix)[redacted_network_identity]"
            )
        }
        return rendered
    }

    /// Mirrors the collector's legacy IPv4 parsing and rejection boundary for
    /// free-text numeric assignments. Public decimal multipart values remain
    /// useful telemetry; explicit radix syntax, integer IPv4, and non-public
    /// multipart values are ambiguous network identities and fail closed.
    private static func isHostedRejectedLegacyNumericToken(_ token: String) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...4).contains(parts.count) else { return false }
        var numbers: [UInt64] = []
        for component in parts {
            guard !component.isEmpty, component.count <= 16 else { return false }
            let lowercased = component.lowercased()
            let radix: Int
            let digits: String
            if lowercased.hasPrefix("0x") {
                radix = 16
                digits = String(lowercased.dropFirst(2))
                guard !digits.isEmpty,
                      digits.allSatisfy({ $0.isHexDigit }) else { return false }
            } else if component.count > 1, component.hasPrefix("0") {
                radix = 8
                digits = String(component.dropFirst())
                guard digits.allSatisfy({ ("0"..."7").contains(String($0)) }) else {
                    return false
                }
            } else {
                radix = 10
                digits = component
                guard digits.allSatisfy(\.isNumber) else { return false }
            }
            guard let number = UInt64(digits.isEmpty ? "0" : digits, radix: radix),
                  number <= UInt64(UInt32.max) else { return false }
            numbers.append(number)
        }
        guard numbers.dropLast().allSatisfy({ $0 <= 255 }) else { return false }
        let lastLimits: [UInt64] = [UInt64(UInt32.max), 0x00ff_ffff, 0x0000_ffff, 0xff]
        guard let last = numbers.last, last <= lastLimits[parts.count - 1] else { return false }

        let address = numbers.dropLast().enumerated().reduce(last) { result, entry in
            result + (entry.element << UInt64(24 - (entry.offset * 8)))
        }
        let first = address >> 24
        let second = (address >> 16) & 0xff
        let isNonPublic = first == 0 || first == 10 ||
            (first == 100 && (64...127).contains(second)) ||
            first == 127 ||
            (first == 169 && second == 254) ||
            (first == 172 && (16...31).contains(second)) ||
            (first == 192 && (second == 0 || second == 168)) ||
            (first == 198 && (second == 18 || second == 19)) ||
            first >= 224
        let explicitLegacySyntax = parts.contains { component in
            component.lowercased().hasPrefix("0x") ||
                (component.count > 1 && component.hasPrefix("0"))
        }
        let longIntegerSyntax = parts.count == 1 &&
            (7...10).contains(token.count) && token.allSatisfy(\.isNumber)
        return explicitLegacySyntax || longIntegerSyntax || (parts.count > 1 && isNonPublic)
    }

    private static func sanitizeHostedBarePrivateIdentifiers(in value: String) -> String {
        var rendered = replaceMatches(
            of: hostedBareUUIDRegex,
            in: value,
            with: "[redacted_private_id]"
        )
        rendered = replaceMatches(
            of: hostedBareCompactUUIDRegex,
            in: rendered,
            with: "[redacted_private_id]"
        )
        let source = rendered as NSString
        let range = NSRange(location: 0, length: source.length)
        let matches = hostedBarePrivateIdentifierRegex.matches(in: rendered, range: range)
        for match in matches.reversed() {
            guard match.numberOfRanges == 2,
                  match.range(at: 1).location != NSNotFound else { continue }
            let token = source.substring(with: match.range(at: 1)).lowercased()
            guard !hostedSafeSemanticIdentifierTokens.contains(token) else { continue }
            rendered = (rendered as NSString).replacingCharacters(
                in: match.range(at: 1),
                with: "[redacted_private_id]"
            )
        }
        return rendered
    }

    private static func hasHostedBareUUID(in value: String) -> Bool {
        let range = NSRange(location: 0, length: (value as NSString).length)
        return hostedBareUUIDRegex.firstMatch(in: value, range: range) != nil
            || hostedBareCompactUUIDRegex.firstMatch(in: value, range: range) != nil
    }

    private static func normalizeHostedNumericTelemetryAssignments(in value: String) -> String {
        var rendered = value
        for (regex, suffix) in hostedNumericTelemetryAssignmentRegexes {
            let source = rendered as NSString
            let range = NSRange(location: 0, length: source.length)
            for match in regex.matches(in: rendered, range: range).reversed() {
                guard match.numberOfRanges == 4 else { continue }
                let key = source.substring(with: match.range(at: 1))
                if key.caseInsensitiveCompare("bytes") == .orderedSame,
                   isHostedByteRangeValue(in: source, before: match.range.location) {
                    continue
                }
                let delimiter = source.substring(with: match.range(at: 2))
                let numeric = source.substring(with: match.range(at: 3))
                    .replacingOccurrences(of: ".", with: "p")
                rendered = (rendered as NSString).replacingCharacters(
                    in: match.range,
                    with: key + delimiter + numeric + suffix
                )
            }
        }
        return rendered
    }

    private static func isHostedByteRangeValue(in source: NSString, before location: Int) -> Bool {
        let prefix = source.substring(to: location)
        let range = NSRange(location: 0, length: (prefix as NSString).length)
        return hostedByteRangeAssignmentPrefixRegex.firstMatch(in: prefix, range: range) != nil
    }

    private static func redactHostedAbsolutePaths(in value: String) -> String {
        let source = value as NSString
        let range = NSRange(location: 0, length: source.length)
        let matches = hostedAbsolutePathRegex.matches(in: value, range: range)
        var rendered = value
        for match in matches.reversed() {
            guard match.numberOfRanges == 3,
                  match.range(at: 1).location != NSNotFound else {
                continue
            }
            let candidate = source.substring(with: match.range(at: 2))
            guard !candidate.hasPrefix("//") else { continue }
            let prefix = source.substring(with: match.range(at: 1))
            rendered = (rendered as NSString).replacingCharacters(
                in: match.range,
                with: prefix + "[redacted_path]"
            )
        }
        return rendered
    }

    private static func normalizeHostedTextualIdentifiers(name: String, data: Data) -> Data {
        guard textualEntryNames.contains(name) else { return data }
        guard let value = String(data: data, encoding: .utf8) else {
            return Data("[redaction_failed: non-utf8 content dropped]".utf8)
        }
        // JSON members have already passed through their typed structural
        // sanitizers. Whole-assignment regexes deliberately remove a complete
        // `key: value` pair from free-form text and would corrupt JSON syntax.
        guard !name.hasSuffix(".json"), !name.hasSuffix(".jsonl") else {
            return data
        }
        return Data(sanitizeHostedContainerText(value).utf8)
    }

    private static func templateHostedURLPaths(in value: String) -> String {
        let nsValue = value as NSString
        var rendered = value
        let fullRange = NSRange(location: 0, length: nsValue.length)
        let matches = hostedAuthorityURLRegex.matches(in: value, range: fullRange)
        for match in matches.reversed() {
            let candidate = nsValue.substring(with: match.range)
            let trailing = candidate.reversed().prefix { hostedTrailingURLPunctuation.contains($0) }
            let trailingText = String(trailing.reversed())
            let core = String(candidate.dropLast(trailingText.count))
            guard var components = URLComponents(string: core) else { continue }
            let templatedPath = templateHostedPrivatePathSegments(components.percentEncodedPath)
                .replacingOccurrences(of: "{id}", with: "%7Bid%7D")
            components.percentEncodedPath = templatedPath
            guard let encoded = components.string else { continue }
            let sanitized = encoded.replacingOccurrences(
                of: "%7Bid%7D",
                with: "{id}",
                options: .caseInsensitive
            )
            guard let range = Range(match.range, in: rendered) else { continue }
            rendered.replaceSubrange(range, with: sanitized + trailingText)
        }
        return rendered
    }

    // The segment rules moved to DiagnosticsPathTemplate so networking can
    // template `network.path` at emission time using the same regexes; these
    // stay as the hosted-path spelling of that shared logic.
    private static func templateHostedPrivatePathSegments(_ value: String) -> String {
        DiagnosticsPathTemplate.template(value)
    }

    private static func replaceMatches(
        of regex: NSRegularExpression,
        in value: String,
        with replacement: String
    ) -> String {
        let range = NSRange(location: 0, length: (value as NSString).length)
        return regex.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: replacement
        )
    }

    private static let hostedPrivateIdentifierAssignmentRegex: NSRegularExpression = {
        // CMP messages predate typed diagnostic attributes and include private
        // Silo correlation IDs as key=value text. Remove the full assignment
        // so neither a private value nor a rejected identity-like key reaches
        // the collector. The matcher accepts camelCase and snake_case and
        // covers current playback/file/item/media/plan identifiers.
        let pattern = #"(?i)(?:\"|')?\b(playback[_-]?session[_-]?id|session[_-]?id|(?:plan|selected|effective|requested|media)?[_-]?file[_-]?id|item[_-]?id|media[_-]?id|plan[_-]?id|playback[_-]?attempt[_-]?id|plan[_-]?attempt[_-]?key|subtitle[_-]?id|track[_-]?id)(?:\"|')?\s*[:=]\s*(?:\"(?:\\.|[^\"\\\r\n])*\"|'[^'\r\n]*'|[^\s,;)\]}]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("Hosted diagnostics identifier redaction regex must compile")
        }
        return regex
    }()

    private static let hostedNetworkIdentityAssignmentRegex: NSRegularExpression = {
        // The public collector rejects raw network-identity assignment keys
        // even when their values are already canonical. Remove the complete
        // hosted assignment while leaving canonical manifest keys such as
        // server_instance_id untouched.
        let pattern = #"(?i)(?:\"|')?\b(host|hostname|server|origin|endpoint|address|url|(?:server|base|origin)[_-]?url)(?:\"|')?\s*[:=]\s*(?:\"(?:\\.|[^\"\\\r\n])*\"|'[^'\r\n]*'|[^\s,;)\]}]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("Hosted diagnostics network redaction regex must compile")
        }
        return regex
    }()

    private static let hostedStableHostTokenRegex = try! NSRegularExpression(
        pattern: #"(?i)(?:\[host:[0-9a-f]{12}\]|\bhost_[0-9a-f]{16}\b)"#
    )
    private static let hostedLoopbackHostRegex = try! NSRegularExpression(
        pattern: #"(?i)(?:(?<![A-Za-z0-9.-])(?:localhost|127(?:\.(?:25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})){3})(?![A-Za-z0-9.-])|\[::1\]|(?<![A-Fa-f0-9:])::1(?![A-Fa-f0-9:]))"#
    )
    private static let hostedAbsolutePathRegex = try! NSRegularExpression(
        pattern: #"(?m)(^|[^A-Za-z0-9/])(/[^\s\"'<>\\]+)"#
    )
    private static let hostedNativeLibraryRegex = try! NSRegularExpression(
        pattern: #"(?i)(?<![A-Za-z0-9_+-])(?:[A-Za-z0-9_+-]+\.)+(?:dylib|so)(?:\.[0-9]+)*(?![A-Za-z0-9_.-])"#
    )
    private static let hostedAuthorityURLRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:https?|wss?)://[^\s<>\"']+"#
    )
    // The path-segment regexes (UUID / numeric / hex / opaque) live in
    // DiagnosticsPathTemplate, shared with emission-time network templating.
    private static let hostedBareUUIDRegex = try! NSRegularExpression(
        pattern: #"(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#
    )
    private static let hostedBareCompactUUIDRegex = try! NSRegularExpression(
        pattern: #"(?i)(?<![0-9a-f])[0-9a-f]{32}(?![0-9a-f])"#
    )
    private static let hostedNumericMediaAssignmentRegex = try! NSRegularExpression(
        pattern: #"(?i)\bmedia(?=\s*[:=]\s*-?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?:$|[\s,;)\]}]))"#
    )
    private static let hostedNumericTelemetryAssignmentRegexes: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(
            pattern: #"(?i)\b(budgetBytes|bytes)(\s*[:=]\s*)(-?[0-9]+)(?![0-9A-Za-z.])"#
        ), "B"),
        (try! NSRegularExpression(
            pattern: #"(?i)\b(elapsedMs)(\s*[:=]\s*)(-?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+))(?![0-9A-Za-z.])"#
        ), "ms"),
        (try! NSRegularExpression(
            pattern: #"(?i)\b(current|mediaSeconds|start|startTime)(\s*[:=]\s*)(-?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+))(?![0-9A-Za-z.])"#
        ), "s"),
        (try! NSRegularExpression(
            pattern: #"(?i)\b(rate)(\s*[:=]\s*)(-?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+))(?![0-9A-Za-z.])"#
        ), "x"),
    ]
    private static let hostedByteRangeAssignmentPrefixRegex = try! NSRegularExpression(
        pattern: #"(?i)\brange\s*[:=]\s*$"#
    )
    private static let hostedAmbiguousLegacyNumericAssignmentRegex = try! NSRegularExpression(
        // Playback telemetry such as `bufAhead=0.0` and
        // `cachedAheadBytes=67108864` is indistinguishable from shortened,
        // integer, octal, hexadecimal, or mixed-radix IPv4 syntax at the
        // public collector. Preserve the explicitly unit-normalized keys
        // above, but fail closed for every remaining numeric assignment,
        // including quoted JSON-style fields, instead of maintaining an
        // incomplete free-text key allowlist.
        pattern: #"(?i)(?<![A-Za-z0-9_.-])((?:\"[A-Za-z][A-Za-z0-9_.-]{0,95}\"|'[A-Za-z][A-Za-z0-9_.-]{0,95}'|[A-Za-z][A-Za-z0-9_.-]{0,95})\s*[:=]\s*(?:[\"'])?)([-+]?)((?:(?:0x[0-9a-f]{1,16}|0[0-7]{1,15}|[0-9]{1,16})\.){1,3}(?:0x[0-9a-f]{1,16}|0[0-7]{1,15}|[0-9]{1,16})|0x[0-9a-f]{1,16}|0[0-7]+|[0-9]{7,10})(?![0-9A-Za-z.])"#
    )
    private static let hostedBarePrivateIdentifierRegex = try! NSRegularExpression(
        pattern: #"(?i)(?<![A-Za-z0-9])((?:ps|playback|session|file|item|media|plan|attempt|profile|account|user|device|content|library|request|req|correlation|server|subtitle|track|run)[_-](?:[0-9]+|[A-Za-z0-9][A-Za-z0-9_-]{7,}))(?![A-Za-z0-9_-])"#
    )
    private static let hostedExactMetricKitBinaryUUIDRegex = try! NSRegularExpression(
        pattern: #"(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#
    )
    private static let hostedSafeSemanticIdentifierTokens: Set<String> = [
        "file_not_found",
        "item_count",
        "plan_invalidated",
        "playback_unavailable",
        "request_cancelled",
        "request_completed",
        "session_unavailable",
    ]
    private static let hostedTrailingURLPunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]",
    ]
    private static let hostedDevicePrivateFieldKeys: Set<String> = [
        "uidhash",
        "routehash",
        "routehashes",
        "host",
        "hostname",
        "server",
        "serverurl",
        "baseurl",
        "origin",
        "originurl",
        "endpoint",
        "address",
        "url",
        "ip",
        "ipaddress",
        "deviceid",
        "deviceaddress",
        "serial",
        "serialnumber",
        "imei",
        "meid",
        "mac",
        "macaddress",
        "ssid",
        "bssid",
    ]

    // Internal rather than private so DiagnosticsAttributeRegistryParityTests can
    // prove this allowlist is a subset of the canonical attribute registry. An
    // entry here that the collectors do not register is a hard upload rejection,
    // so the relationship has to be checked mechanically rather than by review.
    enum HostedAttributeType: Equatable {
        case string
        case integer

        func accepts(_ value: DiagnosticsJSONValue) -> Bool {
            switch (self, value) {
            case (.string, .string), (.integer, .int):
                return true
            default:
                return false
            }
        }
    }

    // A privacy allowlist for the hosted destination, not a second copy of the
    // emission registry. Every key here must also appear in the canonical
    // attribute registry (vendored at
    // Tests/Fixtures/DiagnosticsContract/attr-registry.json) with the same type
    // — the hosted collector rejects the whole bundle on an unregistered key.
    // The reverse does not hold: canonical registers keys this table withholds.
    // Self-hosted uploads carry the full canonical set; only hosted bundles are
    // narrowed here.
    //
    // Two distinct reasons put a canonical key on the withheld list, and the
    // distinction matters because they fail differently:
    //
    // 1. Content we do not want a third party to hold, regardless of whether it
    //    would accept it. `playback.session_id`, `play_method`, `reason` and
    //    `position_ms` describe one user's specific viewing session — a
    //    server-issued identifier, operator free text, and a viewing position.
    //    The collector would take them; we choose not to send them.
    //
    // 2. Keys that collide with the hosted collector's own `FORBIDDEN_KEYS`
    //    privacy scanner (silo-diagnostics `src/privacy.ts`). A collision does
    //    *not* reject the bundle — the report still processes to `ready`, but
    //    the `privacy_fields` check fails and the report is permanently marked
    //    `privacy_flagged` in the admin UI. `network.attempt` is exactly this:
    //    canonical and harmless (a retry ordinal), but `attempt` is a scanner
    //    forbidden key, so forwarding it would flag every hosted report from a
    //    session containing a routine 401-token-refresh retry. Those flags are
    //    all false positives, and false positives train operators to ignore the
    //    one check that catches real leaks. The retry line's `msg` ("401 retry"
    //    / "401 not retried") carries the distinction on its own, so hosted
    //    evidence loses nothing by dropping the attribute.
    //
    // Before adding a key here, normalize it and check it against
    // `FORBIDDEN_KEYS`, `FORBIDDEN_COMPACT_KEYS` and the credential/identifier
    // segment rules in silo-diagnostics `src/privacy.ts` — a key is forbidden
    // if it equals a forbidden key, contains one as an `_`-delimited segment,
    // matches one with `_` stripped, or contains any `*_id`/`*_token`-style
    // segment. See testHostedFrozenLogsAndBreadcrumbsDropPrivatePlaybackAttributes,
    // testHostedAttributeAllowlistIsACanonicalSubset, and
    // testHostedAllowlistWithholdsSessionIdentifyingAndCollectorForbiddenAttributes
    // for the pinned sets.
    static let hostedAttributeRegistry: [
        DiagnosticsLogCategory: [String: HostedAttributeType]
    ] = [
        .playback: [
            "sink": .string,
            "fmt": .string,
            "decoder": .string,
            "width": .integer,
            "height": .integer,
            "hdr_mode": .string,
            "bitrate_kbps": .integer,
            "dropped_frames": .integer,
            "audio_underruns": .integer,
        ],
        .focus: [
            "target": .string,
            "action": .string,
        ],
        .network: [
            "method": .string,
            "path": .string,
            "status": .integer,
            "duration_ms": .integer,
            "outcome": .string,
            "error_code": .string,
            // "attempt" is canonical, but withheld: see reason 2 above.
        ],
        .lifecycle: [
            "state": .string,
            "phase": .string,
            "duration_ms": .integer,
            "outcome": .string,
            "reason": .string,
            "launch_type": .string,
        ],
        .crash: [
            "fingerprint": .string,
            "source": .string,
        ],
    ]

    private static func scrubTextualEntry(name: String, data: Data, tokens: [String]) -> Data {
        guard textualEntryNames.contains(name) else {
            return data
        }
        return scrubExactTokenMatches(in: data, tokens: tokens)
    }

    private static let textualEntryNames: Set<String> = [
        "manifest.json",
        "device.json",
        "logs.jsonl",
        "crash/summary.json",
        "crash/stack.txt",
        "crash/metrickit.json",
        "breadcrumbs.jsonl",
    ]

    private func makeLogSummary(
        logsData: Data,
        logsGzipSize: Int,
        droppedLines: Int,
        debugLogging: Bool
    ) -> DiagnosticsManifest.LogSummary {
        let decoder = DiagnosticsJSONCoding.makeDecoder()
        let lines = String(decoding: logsData, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        var categories: [DiagnosticsLogCategory] = []
        for line in lines {
            guard let decoded = try? decoder.decode(DiagnosticsLogLine.self, from: Data(line.utf8)),
                  !categories.contains(decoded.cat) else {
                continue
            }
            categories.append(decoded.cat)
        }
        return DiagnosticsManifest.LogSummary(
            lines: lines.count,
            bytesGz: logsGzipSize,
            droppedLines: droppedLines,
            categories: categories,
            debugLogging: debugLogging
        )
    }

    private static func makeTar(entries: [(String, Data)]) throws -> Data {
        var tar = Data()
        for (name, data) in entries {
            guard DiagnosticsManifest.Archive.allowedEntries.contains(name),
                  name.utf8.count <= 100 else {
                throw DiagnosticsBundleError.invalidEntryName(name)
            }
            tar.append(makeTarHeader(name: name, size: data.count))
            tar.append(data)
            let padding = (512 - (data.count % 512)) % 512
            if padding > 0 {
                tar.append(Data(repeating: 0, count: padding))
            }
        }
        tar.append(Data(repeating: 0, count: 1024))
        return tar
    }

    private static func makeTarHeader(name: String, size: Int) -> Data {
        var header = [UInt8](repeating: 0, count: 512)
        write(name, to: &header, offset: 0, length: 100)
        writeOctal(0o644, to: &header, offset: 100, length: 8)
        writeOctal(0, to: &header, offset: 108, length: 8)
        writeOctal(0, to: &header, offset: 116, length: 8)
        writeOctal(size, to: &header, offset: 124, length: 12)
        writeOctal(0, to: &header, offset: 136, length: 12)
        for index in 148..<156 {
            header[index] = 32
        }
        header[156] = UInt8(ascii: "0")
        write("ustar", to: &header, offset: 257, length: 6)
        write("00", to: &header, offset: 263, length: 2)
        let checksum = header.reduce(0) { $0 + Int($1) }
        writeChecksum(checksum, to: &header)
        return Data(header)
    }

    private static func write(_ value: String, to header: inout [UInt8], offset: Int, length: Int) {
        let bytes = Array(value.utf8.prefix(length))
        for (index, byte) in bytes.enumerated() {
            header[offset + index] = byte
        }
    }

    private static func writeOctal(_ value: Int, to header: inout [UInt8], offset: Int, length: Int) {
        let raw = String(value, radix: 8)
        let padded = String(repeating: "0", count: max(0, length - 1 - raw.count)) + raw
        write(padded, to: &header, offset: offset, length: length - 1)
    }

    private static func writeChecksum(_ checksum: Int, to header: inout [UInt8]) {
        let raw = String(checksum, radix: 8)
        let padded = String(repeating: "0", count: max(0, 6 - raw.count)) + raw
        write(padded, to: &header, offset: 148, length: 6)
        header[154] = 0
        header[155] = 32
    }

    static func gzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        let initStatus = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            MAX_WBITS + 16,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            throw DiagnosticsBundleError.gzipFailed(initStatus)
        }
        defer { deflateEnd(&stream) }

        var output = Data()
        var status: Int32 = Z_OK
        try data.withUnsafeBytes { inputBuffer in
            guard let inputBase = inputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                return
            }
            stream.next_in = UnsafeMutablePointer(mutating: inputBase)
            stream.avail_in = uInt(data.count)

            repeat {
                var buffer = [UInt8](repeating: 0, count: 16 * 1024)
                let capacity = buffer.count
                var produced = 0
                try buffer.withUnsafeMutableBytes { outputBuffer in
                    stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(capacity)
                    status = deflate(&stream, Z_FINISH)
                    guard status == Z_OK || status == Z_STREAM_END else {
                        throw DiagnosticsBundleError.gzipFailed(status)
                    }
                    produced = capacity - Int(stream.avail_out)
                }
                if produced > 0 {
                    output.append(buffer, count: produced)
                }
            } while status != Z_STREAM_END
        }
        return output
    }
}

enum DiagnosticsBundleError: Error, Equatable {
    case invalidEntryName(String)
    case gzipFailed(Int32)
    case invalidHostedEnvelope
}
#endif
