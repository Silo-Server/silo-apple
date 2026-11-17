import SwiftUI

/// The Not interested entry in a movie or series page's More menu. Draws
/// nothing when the server predates the mark (`isNotInterested == nil`).
struct NotInterestedMenuButton: View {
    let isNotInterested: Bool?
    let action: (() -> Void)?

    var body: some View {
        if let isNotInterested, let action {
            Button(action: action) {
                Label(
                    isNotInterested ? .cardMenuShowInRecommendations : .cardMenuNotInterested,
                    systemImage: isNotInterested ? "hand.thumbsup" : "hand.thumbsdown"
                )
            }
        }
    }
}
