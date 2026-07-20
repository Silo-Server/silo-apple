#if os(iOS) || os(tvOS)
import Foundation

enum ReportType: String, Codable, Equatable, CaseIterable {
    case crash
    case anr
    case nativeCrash = "native_crash"
    case hang
    case abnormalExit = "abnormal_exit"
    case manual
}

enum Platform: String, Codable, Equatable, CaseIterable {
    case android
    case androidTV = "android-tv"
    case ios
    case tvos
}

enum ConsentMode: String, Codable, Equatable, CaseIterable {
    case prompt
    case always
    case manual
}

struct DiagnosticsManifest: Codable, Equatable {
    let schemaVersion: Int
    let report: Report
    let destination: Destination
    let consent: Consent
    let crash: DiagnosticsCrashInfo?
    let deviceSummary: DeviceSummary
    let playbackSessionIds: [String]
    let logSummary: LogSummary
    let archive: Archive

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case report
        case destination
        case consent
        case crash
        case deviceSummary = "device_summary"
        case playbackSessionIds = "playback_session_ids"
        case logSummary = "log_summary"
        case archive
    }

    func validate() throws {
        guard schemaVersion == 1 else {
            throw DiagnosticsValidationError.invalidField("schema_version")
        }
        try report.validate()
        try destination.validate()
        try consent.validate()
        try deviceSummary.validate()
        try logSummary.validate()
        try archive.validate()

        guard playbackSessionIds.count <= 20 else {
            throw DiagnosticsValidationError.invalidField("playback_session_ids")
        }
        for id in playbackSessionIds where !id.diagnosticsIsNonEmpty {
            throw DiagnosticsValidationError.invalidField("playback_session_ids")
        }

        if report.type == .manual {
            guard crash == nil else {
                throw DiagnosticsValidationError.invalidField("crash")
            }
        } else {
            guard let crash else {
                throw DiagnosticsValidationError.invalidField("crash")
            }
            try crash.validate()
        }
    }

    struct Report: Codable, Equatable {
        let type: ReportType
        let capturedAt: String
        let captureSessionID: String
        let appVersion: String
        let appBuild: String
        let platform: Platform
        let osVersion: String
        let profileID: String?

        enum CodingKeys: String, CodingKey {
            case type
            case capturedAt = "captured_at"
            case captureSessionID = "capture_session_id"
            case appVersion = "app_version"
            case appBuild = "app_build"
            case platform
            case osVersion = "os_version"
            case profileID = "profile_id"
        }

        func validate() throws {
            guard capturedAt.diagnosticsIsNonEmpty else {
                throw DiagnosticsValidationError.invalidField("report.captured_at")
            }
            guard captureSessionID.diagnosticsIsNonEmpty else {
                throw DiagnosticsValidationError.invalidField("report.capture_session_id")
            }
            guard appVersion.diagnosticsIsNonEmpty else {
                throw DiagnosticsValidationError.invalidField("report.app_version")
            }
            guard appBuild.diagnosticsIsNonEmpty else {
                throw DiagnosticsValidationError.invalidField("report.app_build")
            }
            guard osVersion.diagnosticsIsNonEmpty else {
                throw DiagnosticsValidationError.invalidField("report.os_version")
            }
        }
    }

    struct Destination: Codable, Equatable {
        let serverInstanceID: String

        enum CodingKeys: String, CodingKey {
            case serverInstanceID = "server_instance_id"
        }

        func validate() throws {
            guard serverInstanceID.diagnosticsIsNonEmpty else {
                throw DiagnosticsValidationError.invalidField("destination.server_instance_id")
            }
        }
    }

    struct Consent: Codable, Equatable {
        let mode: ConsentMode
        let noticeVersion: Int

        enum CodingKeys: String, CodingKey {
            case mode
            case noticeVersion = "notice_version"
        }

        func validate() throws {
            guard noticeVersion >= 1 else {
                throw DiagnosticsValidationError.invalidField("consent.notice_version")
            }
        }
    }

    struct DeviceSummary: Codable, Equatable {
        let manufacturer: String
        let model: String
        let os: String
        let formFactor: String

        enum CodingKeys: String, CodingKey {
            case manufacturer
            case model
            case os
            case formFactor = "form_factor"
        }

        func validate() throws {
            guard manufacturer.diagnosticsIsNonEmpty else {
                throw DiagnosticsValidationError.invalidField("device_summary.manufacturer")
            }
            guard model.diagnosticsIsNonEmpty else {
                throw DiagnosticsValidationError.invalidField("device_summary.model")
            }
            guard os.diagnosticsIsNonEmpty else {
                throw DiagnosticsValidationError.invalidField("device_summary.os")
            }
            guard formFactor.diagnosticsIsNonEmpty else {
                throw DiagnosticsValidationError.invalidField("device_summary.form_factor")
            }
        }
    }

    struct LogSummary: Codable, Equatable {
        let lines: Int
        let bytesGz: Int
        let droppedLines: Int
        let categories: [DiagnosticsLogCategory]
        let debugLogging: Bool

        enum CodingKeys: String, CodingKey {
            case lines
            case bytesGz = "bytes_gz"
            case droppedLines = "dropped_lines"
            case categories
            case debugLogging = "debug_logging"
        }

        func validate() throws {
            guard lines >= 0 else {
                throw DiagnosticsValidationError.invalidField("log_summary.lines")
            }
            guard bytesGz >= 0 else {
                throw DiagnosticsValidationError.invalidField("log_summary.bytes_gz")
            }
            guard droppedLines >= 0 else {
                throw DiagnosticsValidationError.invalidField("log_summary.dropped_lines")
            }
            guard categories.count <= 9, Set(categories).count == categories.count else {
                throw DiagnosticsValidationError.invalidField("log_summary.categories")
            }
        }
    }

    struct Archive: Codable, Equatable {
        static let allowedEntries: Set<String> = [
            "manifest.json",
            "device.json",
            "logs.jsonl",
            "crash/summary.json",
            "crash/stack.txt",
            "crash/tombstone.pb",
            "crash/metrickit.json",
            "breadcrumbs.jsonl",
        ]

        let entries: [String]
        let bytes: Int
        let uncompressedBytes: Int
        let sha256: String

        enum CodingKeys: String, CodingKey {
            case entries
            case bytes
            case uncompressedBytes = "uncompressed_bytes"
            case sha256
        }

        func validate() throws {
            guard (1...8).contains(entries.count),
                  entries.contains("manifest.json"),
                  Set(entries).count == entries.count else {
                throw DiagnosticsValidationError.invalidField("archive.entries")
            }
            for entry in entries where !Self.allowedEntries.contains(entry) {
                throw DiagnosticsValidationError.invalidField("archive.entries")
            }
            guard bytes >= 0 else {
                throw DiagnosticsValidationError.invalidField("archive.bytes")
            }
            guard uncompressedBytes >= 0 else {
                throw DiagnosticsValidationError.invalidField("archive.uncompressed_bytes")
            }
            guard sha256.count == 64,
                  sha256.unicodeScalars.allSatisfy({ CharacterSet.diagnosticsHexDigits.contains($0) }) else {
                throw DiagnosticsValidationError.invalidField("archive.sha256")
            }
        }
    }
}

private extension CharacterSet {
    static let diagnosticsHexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
}
#endif
