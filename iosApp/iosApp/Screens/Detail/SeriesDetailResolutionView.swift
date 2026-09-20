import SwiftUI

/// Resolves legacy catalog links without pushing an intermediate detail page.
struct SeriesDetailResolutionView: View {
    let detail: ItemDetail
    let onResolve: ((SeriesDetailContext) -> Void)?
    let onRetry: () -> Void

    var body: some View {
        if let context = SeriesDetailContext(detail: detail), let onResolve {
            Color.clear
                .task(id: context) { onResolve(context) }
        } else {
            ErrorView(
                state: ErrorState(statusCode: nil, message: "Couldn't find the series for this item."),
                onRetry: onRetry
            )
        }
    }
}
