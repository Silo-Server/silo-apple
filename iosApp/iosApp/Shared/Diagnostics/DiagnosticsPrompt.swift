#if os(iOS) || os(tvOS)
import Foundation

struct DiagnosticsPrompt: Identifiable, Equatable {
    let id = UUID()
    let reports: [PendingReport]

    var title: LocalizedStringResource {
        // Two strings: Xcode can't vary a plural that doesn't print its count.
        reports.count == 1 ? .diagnosticsPromptSendTitleSingle : .diagnosticsPromptSendTitleMultiple
    }

    var message: LocalizedStringResource {
        let count = reports.count
        let types = Set(reports.map(\.binding.type))
        let hosted = reports.allSatisfy { $0.binding.binding.destinationChoice == .hosted }
        if count == 1, let type = reports.first?.binding.type {
            return Self.singleMessage(for: type, hosted: hosted)
        }
        if types.count == 1, let type = types.first {
            switch type {
            case .crash, .nativeCrash:
                return hosted
                    ? .diagnosticsPromptCrashedCountHosted(count)
                    : .diagnosticsPromptCrashedCountSelfHosted(count)
            case .hang, .anr:
                return hosted
                    ? .diagnosticsPromptNotRespondingCountHosted(count)
                    : .diagnosticsPromptNotRespondingCountSelfHosted(count)
            case .abnormalExit:
                return hosted
                    ? .diagnosticsPromptUncleanShutdownCountHosted(count)
                    : .diagnosticsPromptUncleanShutdownCountSelfHosted(count)
            case .manual:
                return .diagnosticsPromptManualCount(count)
            }
        }

        // The language on screen, so the list sorts in the order it reads.
        let descriptions = types
            .map { AppLanguage.string(Self.shortDescription(for: $0)) }
            .sorted()
            .joined(separator: ", ")
        return .diagnosticsPromptMixedCount(count, descriptions)
    }

    private static func singleMessage(for type: ReportType, hosted: Bool) -> LocalizedStringResource {
        switch type {
        case .crash, .nativeCrash:
            return hosted ? .diagnosticsPromptCrashedHosted : .diagnosticsPromptCrashedSelfHosted
        case .hang, .anr:
            return hosted ? .diagnosticsPromptNotRespondingHosted : .diagnosticsPromptNotRespondingSelfHosted
        case .abnormalExit:
            return hosted ? .diagnosticsPromptUncleanShutdownHosted : .diagnosticsPromptUncleanShutdownSelfHosted
        case .manual:
            return .diagnosticsPromptManualOne
        }
    }

    private static func shortDescription(for type: ReportType) -> LocalizedStringResource {
        switch type {
        case .crash, .nativeCrash:
            return .diagnosticsPromptTypeCrash
        case .hang, .anr:
            return .diagnosticsPromptTypeNotResponding
        case .abnormalExit:
            return .diagnosticsPromptTypeUncleanShutdown
        case .manual:
            return .diagnosticsPromptTypeManual
        }
    }
}
#endif
