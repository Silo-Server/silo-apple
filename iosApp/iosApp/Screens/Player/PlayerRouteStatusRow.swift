import Foundation

struct PlayerRouteStatusRow: Identifiable, Equatable {
    let label: String
    let value: String

    var id: String { label }
}
