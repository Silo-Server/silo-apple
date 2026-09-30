import Foundation

/// An inline form error. Each one is a distinct value even when its message
/// repeats, so a view keyed on it (the error haptic) reacts to every report.
struct FormError: Equatable {
    let message: String
    private let id = UUID()

    init(_ message: String) {
        self.message = message
    }
}
