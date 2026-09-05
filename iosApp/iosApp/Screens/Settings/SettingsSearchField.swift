#if os(iOS)
import SwiftUI

struct SettingsSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.siloSecondaryText)
                .accessibilityHidden(true)

            TextField("Search settings", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(Color.siloOnSurface)

            if !text.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") {
                    text = ""
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(Color.siloSecondaryText)
                .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 15)
        .frame(minHeight: 48)
        .background(Color.siloSurfaceElevated.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .strokeBorder(Color.siloOutline, lineWidth: 1)
        }
    }
}
#endif
