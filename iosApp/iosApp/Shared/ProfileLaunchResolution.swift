import Foundation

enum ProfileLaunchResolution: Equatable, Sendable {
    case needsSelection
    case restore(RememberedProfile)
}
