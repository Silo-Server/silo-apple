import SwiftUI

/// The last card of a Home or library row. It opens the row's full page,
/// since a row shows at most `SectionRowLimit.cards` cards.
///
/// Drawn at the row's artwork size so it lines up with the cards before it;
/// it has no caption. Every such row ends with one: Home drops titles another
/// row already shows, so a row can look complete while its page holds more.
struct SectionExploreAllCard: View {
    /// The row's card artwork size.
    let size: CGSize
    var cornerRadius: CGFloat = SiloTheme.cornerRadius
    let rowTitle: String
    /// tvOS: the row's card focus binding, so the card is one more stop in
    /// the row's native focus graph.
    var focusedItemId: FocusState<String?>.Binding? = nil
    let action: () -> Void

    /// Focus identity inside a row's `focusedItemId`. Content IDs never take
    /// this form.
    static let focusId = "silo.row.exploreAll"
    static let label = "Explore all"

    var body: some View {
        button
            // The card has no caption. Rows centre their cards on iPad and
            // tvOS, so filling the row's height keeps the tile level with the
            // artwork beside it instead of the artwork and caption together.
            .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var button: some View {
        #if os(tvOS)
        Button(action: action) { tile }
            .buttonStyle(TVCardOutlineButtonStyle(cornerRadius: cornerRadius))
            .applyRowFocus(focusedItemId)
            .accessibilityLabel("\(Self.label), \(rowTitle)")
        #else
        Button(action: action) { tile }
            .buttonStyle(.plain)
            .accessibilityLabel("\(Self.label), \(rowTitle)")
        #endif
    }

    private var tile: some View {
        VStack(spacing: iconSpacing) {
            Image(systemName: "arrow.right")
                .font(.system(size: iconSize, weight: .semibold))
                .frame(width: iconSize * 2.2, height: iconSize * 2.2)
                .background(Circle().fill(Color.siloOnSurface.opacity(0.12)))
            Text(Self.label)
                .font(labelFont)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(Color.siloOnSurface)
        .padding(.horizontal, 8)
        .frame(width: size.width, height: size.height)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.siloSurfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    // MARK: - Metrics

    private var iconSize: CGFloat {
        #if os(tvOS)
        30
        #else
        16
        #endif
    }

    private var iconSpacing: CGFloat {
        #if os(tvOS)
        18
        #else
        10
        #endif
    }

    private var labelFont: Font {
        #if os(tvOS)
        .siloPosterTitle
        #else
        .footnote.weight(.semibold)
        #endif
    }
}

#if os(tvOS)
private extension View {
    @ViewBuilder
    func applyRowFocus(_ binding: FocusState<String?>.Binding?) -> some View {
        if let binding {
            focused(binding, equals: SectionExploreAllCard.focusId)
        } else {
            self
        }
    }
}
#endif
