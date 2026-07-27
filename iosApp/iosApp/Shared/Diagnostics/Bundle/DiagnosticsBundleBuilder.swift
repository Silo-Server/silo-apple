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
        let logsData = Self.scrubTextualEntry(
            name: "logs.jsonl",
            data: Data(logLines.joined(separator: "\n").appending(logLines.isEmpty ? "" : "\n").utf8),
            tokens: redactionTokens
        )
        let logsGzipSize = (try? Self.gzip(logsData).count) ?? 0
        var draft = report.manifest
        draft.logSummary = makeLogSummary(
            logsData: logsData,
            logsGzipSize: logsGzipSize,
            droppedLines: droppedLogLines
        )

        var entries: [(String, Data)] = []
        func appendEntry(_ name: String, _ data: Data) {
            entries.append((name, Self.scrubTextualEntry(name: name, data: data, tokens: redactionTokens)))
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
        return DiagnosticsBundleBuildResult(
            manifest: manifest,
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
        droppedLines: Int
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
            debugLogging: DiagnosticsConsentStore.shared.debugLoggingEnabled
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
