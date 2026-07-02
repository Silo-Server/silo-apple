import SwiftUI

/// The "Available to request" section embedded in the library `SearchView`
/// below local results: TMDB matches the library can't answer, one tap from
/// the query the user already typed. Renders nothing when the feature is
/// disabled or there's nothing requestable to show, so the search screen is
/// untouched on servers without requests.
struct RequestSearchSectionView: View {
    let viewModel: RequestSearchSectionViewModel
    @Environment(AppRouter.self) private var router

    var body: some View {
        if !viewModel.results.isEmpty {
            VStack(alignment: .leading, spacing: RequestsUI.headerSpacing) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.continuumCaption)
                        Text("Available to request")
                            .font(.continuumHeadline)
                    }
                    .foregroundColor(.continuumOnSurface)

                    Text("Not in the library yet · tap to request")
                        .font(.continuumSmall)
                        .foregroundColor(.continuumSecondaryText)
                }

                RequestCardRail(items: viewModel.results) { result in
                    RequestMediaCard(result: result, onTap: { router.openRequestResult(result) })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(tvOS)
            .focusSection()
            #endif
            .onChange(of: RequestsEventBus.shared.lastUpdate) { _, update in
                if let update {
                    viewModel.applyRequestUpdate(update)
                }
            }
        }
    }

}
