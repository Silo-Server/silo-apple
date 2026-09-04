import SwiftUI

/// A reusable top bar styled for the Silo dark theme.
struct SiloTopBar<LeadingContent: View, TrailingContent: View>: View {
    let title: String
    @ViewBuilder var leading: () -> LeadingContent
    @ViewBuilder var trailing: () -> TrailingContent

    init(
        title: String,
        @ViewBuilder leading: @escaping () -> LeadingContent = { EmptyView() },
        @ViewBuilder trailing: @escaping () -> TrailingContent = { EmptyView() }
    ) {
        self.title = title
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            leading()
                .frame(width: 44, alignment: .leading)

            Spacer()

            Text(title)
                .font(.siloTitle)
                .foregroundColor(.siloOnSurface)

            Spacer()

            trailing()
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, SiloTheme.padding)
        .padding(.vertical, SiloTheme.smallPadding)
        .background(Color.siloBackground)
    }
}
