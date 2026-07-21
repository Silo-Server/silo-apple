#if os(iOS) || os(tvOS)
import Foundation

struct DiagnosticsNotice: Identifiable, Equatable {
    let id = UUID()
    let message: String
}
#endif
