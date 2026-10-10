import SwiftUI

/// The on-view description translation's line under the synopsis on iOS,
/// iPadOS and macOS item detail.
///
/// Shows, from the page's ``ItemDetailViewModel``:
/// - "Translating…" while a translation for the page runs;
/// - "Translated by AI" when the description shown was machine-translated;
/// - a Translate button in the server's `button` on-view mode, or after a
///   run failed, while something on the page is missing in the profile's
///   metadata language.
///
/// Renders nothing otherwise. Automatic runs are started by the page's
/// ``DescriptionTranslationTrigger``, not by this view, so they keep going
/// when the line scrolls away. tvOS draws the status inside the hero's
/// synopsis and offers the action from the More menu instead.
struct DescriptionTranslationView: View {
    let viewModel: ItemDetailViewModel

    var body: some View {
        let status = viewModel.descriptionTranslationStatus
        let offersTranslation = viewModel.offersDescriptionTranslation
        if status != nil || offersTranslation {
            HStack(spacing: 12) {
                if let status {
                    DescriptionTranslationStatusLabel(status: status)
                }
                if offersTranslation {
                    Button {
                        viewModel.translateDescriptions()
                    } label: {
                        translateLabel
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var translateLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: MachineTranslation.symbol)
            Text("Translate")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Color.siloPrimary)
    }
}
