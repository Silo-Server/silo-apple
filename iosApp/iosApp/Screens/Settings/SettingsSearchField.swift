#if os(iOS)
import SwiftUI

struct SettingsSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.continuumSecondaryText)
                .accessibilityHidden(true)

            TextField("Search settings", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(Color.continuumOnSurface)

            if !text.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") {
                    text = ""
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(Color.continuumSecondaryText)
                .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 15)
        .frame(minHeight: 48)
        .background(Color.continuumSurfaceElevated.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .strokeBorder(Color.continuumOutline, lineWidth: 1)
        }
    }
}
#endif
