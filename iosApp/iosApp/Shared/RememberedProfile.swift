import Foundation

struct RememberedProfile: Codable, Equatable, Sendable {
    let profileID: String
    let requiredPINAtSelection: Bool
    let accountEpoch: String
}
