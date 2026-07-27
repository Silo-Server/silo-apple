#if os(iOS) || os(tvOS)
import Foundation

struct DiagnosticsPromptPolicy {
    static func isEligible(
        reportBinding: DiagnosticsBinding,
        currentBinding: DiagnosticsBinding,
        status: DiagnosticsAvailabilityStatus,
        mode: DiagnosticsConsentChoice,
        isSuppressed: Bool,
        isChildProfile: Bool
    ) -> Bool {
        reportBinding == currentBinding
            && status == .available
            && mode == .ask
            && !isSuppressed
            && !isChildProfile
    }
}
#endif
