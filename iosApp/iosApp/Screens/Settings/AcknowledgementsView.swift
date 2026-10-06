import SwiftUI

/// One outside service: its name (or approved logo), what Silo uses it for,
/// and any notice its terms require. Passive text on every platform.
struct ThirdPartyCreditRow: View {
    let credit: ThirdPartyCredits.Credit
    var nameFont: Font = .headline
    var detailFont: Font = .subheadline
    var logoHeight: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let logo = credit.logoAsset {
                // The logo replaces the name. TMDB's terms ask for it to stay
                // less prominent than Silo's own branding.
                Image(logo)
                    .resizable()
                    .scaledToFit()
                    .frame(height: logoHeight)
                    .padding(.vertical, 2)
            } else {
                Text(credit.name)
                    .font(nameFont)
                    .foregroundStyle(Color.siloOnSurface)
            }
            Text(credit.use)
            if let notice = credit.notice {
                Text(notice)
            }
        }
        .font(detailFont)
        .foregroundStyle(Color.siloSecondaryText)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([credit.name, credit.use, credit.notice].compactMap { $0 }.joined(separator: ". "))
    }
}

#if !os(tvOS)
/// Settings > About > Acknowledgements: the outside services whose data or
/// artwork Silo shows, then the open source licenses.
struct AcknowledgementsView: View {
    var body: some View {
        List {
            Section {
                ForEach(ThirdPartyCredits.credits) { credit in
                    ThirdPartyCreditRow(credit: credit)
                        .padding(.vertical, 4)
                        .listRowBackground(Color.siloGroupedCell)
                }
            } header: {
                Text("Services")
                    .foregroundStyle(Color.siloSecondaryText)
            } footer: {
                Text(ThirdPartyCredits.trademarkNotice)
                    .foregroundStyle(Color.siloSecondaryText)
            }

            Section {
                NavigationLink {
                    OpenSourceAcknowledgementsView()
                } label: {
                    Text("Open Source Licenses")
                        .foregroundStyle(Color.siloOnSurface)
                }
                .listRowBackground(Color.siloGroupedCell)
            } header: {
                Text("Open Source")
                    .foregroundStyle(Color.siloSecondaryText)
            } footer: {
                Text("Silo's license, and the licenses and exact source revisions of the code built into it.")
                    .foregroundStyle(Color.siloSecondaryText)
            }
        }
        .settingsListChrome()
        .navigationTitle("Acknowledgements")
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
    }
}
#endif
