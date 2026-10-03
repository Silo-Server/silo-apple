#if !os(tvOS)
import SwiftUI

// MARK: - Inline error row

struct AuroraErrorLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.siloCaption)
        .foregroundStyle(Color.requestRose)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(text)")
    }
}

// MARK: - Screen scaffold

/// Silo backdrop + a vertically scrollable, keyboard-friendly column capped
/// to a comfortable reading width. Callers supply the wordmark + content.
struct AuroraScreen<Content: View>: View {
    var variant: AuroraVariant
    var scrim: AuroraScrim = .soft
    var maxContentWidth: CGFloat = 480
    @ViewBuilder var content: () -> Content

    init(variant: AuroraVariant,
         scrim: AuroraScrim = .soft,
         maxContentWidth: CGFloat = 480,
         @ViewBuilder content: @escaping () -> Content) {
        self.variant = variant
        self.scrim = scrim
        self.maxContentWidth = maxContentWidth
        self.content = content
    }

    var body: some View {
        ZStack {
            AuroraBackdrop(variant: variant, scrim: scrim)
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 0) { content() }
                        .frame(maxWidth: maxContentWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 32)
                        .frame(minHeight: geo.size.height)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .preferredColorScheme(.dark)
    }
}
#endif
