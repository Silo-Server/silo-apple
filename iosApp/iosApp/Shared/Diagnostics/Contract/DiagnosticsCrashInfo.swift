#if os(iOS) || os(tvOS)
import Foundation

enum CrashSource: String, Codable, Equatable, CaseIterable {
    case ueh
    case exitInfo = "exit_info"
    case metrickit
    case exitSentinel = "exit_sentinel"
}

enum Provenance: String, Codable, Equatable, CaseIterable {
    case preFailure = "pre_failure"
    case postRestart = "post_restart"
    case metricReportingPeriod = "metric_reporting_period"
}

struct DiagnosticsCrashInfo: Codable, Equatable {
    let summary: String
    let stackExcerpt: String?
    let thread: String?
    let foreground: Bool?
    let source: CrashSource
    let provenance: Provenance
    let occurredAt: String
    let occurredAtStart: String?
    let occurredAtEnd: String?

    enum CodingKeys: String, CodingKey {
        case summary
        case stackExcerpt = "stack_excerpt"
        case thread
        case foreground
        case source
        case provenance
        case occurredAt = "occurred_at"
        case occurredAtStart = "occurred_at_start"
        case occurredAtEnd = "occurred_at_end"
    }

    init(
        summary: String,
        stackExcerpt: String?,
        thread: String?,
        foreground: Bool?,
        source: CrashSource,
        provenance: Provenance,
        occurredAt: String,
        occurredAtStart: String? = nil,
        occurredAtEnd: String? = nil
    ) {
        self.summary = summary
        self.stackExcerpt = stackExcerpt
        self.thread = thread
        self.foreground = foreground
        self.source = source
        self.provenance = provenance
        self.occurredAt = occurredAt
        self.occurredAtStart = occurredAtStart
        self.occurredAtEnd = occurredAtEnd
    }

    func validate() throws {
        guard summary.diagnosticsIsNonEmpty else {
            throw DiagnosticsValidationError.invalidField("crash.summary")
        }
        if let stackExcerpt, stackExcerpt.utf8.count > 8192 {
            throw DiagnosticsValidationError.invalidField("crash.stack_excerpt")
        }
        guard occurredAt.diagnosticsIsNonEmpty else {
            throw DiagnosticsValidationError.invalidField("crash.occurred_at")
        }
        if let occurredAtStart, !occurredAtStart.diagnosticsIsNonEmpty {
            throw DiagnosticsValidationError.invalidField("crash.occurred_at_start")
        }
        if let occurredAtEnd, !occurredAtEnd.diagnosticsIsNonEmpty {
            throw DiagnosticsValidationError.invalidField("crash.occurred_at_end")
        }
    }
}
#endif
