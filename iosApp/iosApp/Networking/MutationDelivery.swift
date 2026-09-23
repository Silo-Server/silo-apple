import Foundation

/// Whether a failed mutation reached the server, for the plan's three-outcome
/// failure model: a definite failure is released and reported, an owner
/// change applies nothing, and an unconfirmed one is never replayed
/// automatically.
enum MutationDelivery: String, Sendable {
    /// A response arrived, or the request never left the device.
    case definite
    /// The owner changed; nothing is applied under the new one.
    case ownerChanged = "owner_changed"
    /// The request may have reached the server without an answer.
    case unconfirmed

    /// Maps the shared classification (`APIv2MutationOutcome`); this type
    /// keeps no transport or status rules of its own.
    init(_ error: Error) {
        switch APIv2MutationOutcome(error) {
        case .definite, .notSent:
            self = .definite
        case .ownerChanged:
            self = .ownerChanged
        case .uncertain:
            self = .unconfirmed
        }
    }
}
