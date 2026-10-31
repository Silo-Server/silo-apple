import Foundation

/// An inline form error. Each one is a distinct value even when its message
/// repeats, so a view keyed on it (the error haptic) reacts to every report.
struct FormError: Equatable {
    /// The one field an error is about. An error about the whole form, such as
    /// a wrong password or an unreachable server, names none.
    enum Field: Equatable {
        case username
        case port
    }

    let message: String
    let field: Field?
    private let id = UUID()

    init(_ message: String) {
        self.init(message, field: nil)
    }

    init(_ message: String, field: Field?) {
        self.message = message
        self.field = field
    }
}
