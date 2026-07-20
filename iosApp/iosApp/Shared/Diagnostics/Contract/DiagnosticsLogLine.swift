#if os(iOS) || os(tvOS)
import Foundation

enum DiagnosticsLogLevel: String, Codable, Equatable, CaseIterable {
    case verbose = "V"
    case debug = "D"
    case info = "I"
    case warning = "W"
    case error = "E"
}

enum DiagnosticsLogCategory: String, Codable, Equatable, Hashable, CaseIterable {
    case playback
    case focus
    case network
    case lifecycle
    case browse
    case cast
    case download
    case crash
    case other
}

struct DiagnosticsLogLine: Codable, Equatable {
    let ts: String
    let run: String
    let lvl: DiagnosticsLogLevel
    let cat: DiagnosticsLogCategory
    let tag: String
    let msg: String
    let attrs: [String: DiagnosticsJSONValue]?

    init(
        ts: String,
        run: String,
        lvl: DiagnosticsLogLevel,
        cat: DiagnosticsLogCategory,
        tag: String,
        msg: String,
        attrs: [String: DiagnosticsJSONValue]? = nil
    ) {
        self.ts = ts
        self.run = run
        self.lvl = lvl
        self.cat = cat
        self.tag = tag
        self.msg = msg
        self.attrs = attrs
    }

    func validate() throws {
        guard ts.diagnosticsIsNonEmpty else {
            throw DiagnosticsValidationError.invalidField("log.ts")
        }
        guard run.diagnosticsIsNonEmpty else {
            throw DiagnosticsValidationError.invalidField("log.run")
        }
        guard tag.diagnosticsIsNonEmpty else {
            throw DiagnosticsValidationError.invalidField("log.tag")
        }
        guard msg.diagnosticsIsNonEmpty else {
            throw DiagnosticsValidationError.invalidField("log.msg")
        }
    }
}
#endif
