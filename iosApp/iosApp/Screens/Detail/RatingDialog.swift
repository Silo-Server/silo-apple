import SwiftUI

extension UserStarRating {
    /// The More menu entry for the viewer's rating, on every platform:
    /// "Rate Movie" or "Rate Series" (just "Rate" without a noun), or the
    /// saved rating once there is one ("Your Rating: 4 Stars").
    static func menuTitle(rating: Int?, noun: String?) -> String {
        if let rating { return "Your Rating: \(label(rating))" }
        return ["Rate", noun].compactMap { $0 }.joined(separator: " ")
    }

    static func menuSymbol(rating: Int?) -> String {
        rating == nil ? "star" : "star.fill"
    }
}

extension View {
    /// The dialog the More menu's rating entry opens: one button per rating,
    /// 5 stars first. Picking a rating sets it; picking the current one again
    /// clears it, as the message says. A pick made while a save runs is
    /// ignored by `ItemDetailViewModel.setRating`.
    func ratingDialog(
        isPresented: Binding<Bool>,
        title: String,
        rating: Int?,
        onRate: @escaping (Int?) -> Void
    ) -> some View {
        confirmationDialog("Rate \(title)", isPresented: isPresented, titleVisibility: .visible) {
            ForEach(UserStarRating.range.reversed(), id: \.self) { stars in
                Button(UserStarRating.label(stars)) {
                    onRate(UserStarRating.choosing(stars, current: rating))
                }
                .accessibilityHint(stars == rating ? "Removes your rating" : "")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let rating {
                Text("Your rating is \(UserStarRating.label(rating)). Choose it again to remove it.")
            } else {
                Text("Choose how many stars to give it.")
            }
        }
    }
}
