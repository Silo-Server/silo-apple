#if os(iOS) || os(tvOS)
import Foundation
import zlib

struct DiagnosticsBundleBuildResult {
    let manifest: DiagnosticsManifest
    let manifestData: Data
    let bundleData: Data
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
        let logsData = Self.scrubTextualEntry(
            name: "logs.jsonl",
            data: destinationSafeLogsData,
            tokens: redactionTokens
        )
        let logsGzipSize = (try? Self.gzip(logsData).count) ?? 0
        var draft = report.manifest
        draft.logSummary = makeLogSummary(
            logsData: logsData,
            logsGzipSize: logsGzipSize,
            droppedLines: droppedLogLines,
            debugLogging: draft.logSummary.debugLogging
        )

        var entries: [(String, Data)] = []
        func appendEntry(_ name: String, _ data: Data) {
            let destinationSafeData = isHosted && name == "breadcrumbs.jsonl"
                ? Self.sanitizeHostedLogJSONL(data)
                : data
            entries.append((
                name,
                Self.scrubTextualEntry(
                    name: name,
                    data: destinationSafeData,
                    tokens: redactionTokens
                )
            ))
        }

        let manifestDraftData = try DiagnosticsJSONCoding.makeEncoder().encode(draft)
        appendEntry("manifest.json", manifestDraftData)
        appendEntry("device.json", try readRequired("device.json", from: report.directoryURL))
        appendEntry("logs.jsonl", logsData)

        if let crash = draft.crash {
            appendEntry("crash/summary.json", try DiagnosticsJSONCoding.makeEncoder().encode(crash))
        }

        for artifact in ["crash/stack.txt", "crash/tombstone.pb", "crash/metrickit.json", "breadcrumbs.jsonl"] {
            let url = report.directoryURL.appendingPathComponent(artifact)
            guard fileManager.fileExists(atPath: url.path),
                  !entries.contains(where: { $0.0 == artifact }) else {
                continue
            }
            appendEntry(artifact, try Data(contentsOf: url))
        }

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
        let manifestData = Self.scrubTextualEntry(
            name: "manifest.json",
            data: try DiagnosticsJSONCoding.makeEncoder().encode(manifest),
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
            bundleData: bundleData
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
                let safeAttributes = line.attrs?.filter { key, value in
                    registered[key]?.accepts(value) == true
                }
                let sanitized = DiagnosticsLogLine(
                    ts: line.ts,
                    run: line.run,
                    lvl: line.lvl,
                    cat: line.cat,
                    tag: sanitizeHostedPrivateIdentifierAssignments(in: line.tag),
                    msg: sanitizeHostedPrivateIdentifierAssignments(in: line.msg),
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

    private static func sanitizeHostedPrivateIdentifierAssignments(in value: String) -> String {
        let range = NSRange(location: 0, length: (value as NSString).length)
        return hostedPrivateIdentifierAssignmentRegex.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: "[redacted_private_id]"
        )
    }

    private static let hostedPrivateIdentifierAssignmentRegex: NSRegularExpression = {
        // CMP messages predate typed diagnostic attributes and include private
        // Silo correlation IDs as key=value text. Remove the full assignment
        // so neither a private value nor a rejected identity-like key reaches
        // the collector. The matcher accepts camelCase and snake_case and
        // covers current playback/file/item/media/plan identifiers.
        let pattern = #"(?i)\b(playback[_-]?session[_-]?id|session[_-]?id|(?:plan|selected|effective|requested|media)?[_-]?file[_-]?id|item[_-]?id|media[_-]?id|plan[_-]?id|playback[_-]?attempt[_-]?id|plan[_-]?attempt[_-]?key|subtitle[_-]?id|track[_-]?id)\s*[:=]\s*(?:\"(?:\\.|[^\"\\\r\n])*\"|'[^'\r\n]*'|[^\s,;)\]}]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("Hosted diagnostics identifier redaction regex must compile")
        }
        return regex
    }()

    private enum HostedAttributeType {
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

    // Vendored from silo-diagnostics/contract/v1/attr-registry.json. Keep this
    // destination-specific: Apple's self-hosted registry has additional local
    // playback attributes for compatibility with existing Silo servers.
    private static let hostedAttributeRegistry: [
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
        ],
        .lifecycle: [
            "state": .string,
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

    private static func gzip(_ data: Data) throws -> Data {
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
}
#endif
