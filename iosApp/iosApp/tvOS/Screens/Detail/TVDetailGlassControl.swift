#if os(tvOS)
import SwiftUI

/// The single native Liquid Glass treatment for interactive controls on
/// tvOS detail pages. Buttons and menus keep their own labels and semantics;
/// this modifier owns the material, selection tint, and border shape.
extension View {
    func tvDetailGlassControl(
        shape: ButtonBorderShape,
        isSelected: Bool = false,
        isFocused: Bool = false
    ) -> some View {
        buttonStyle(.glass(detailGlass(isSelected: isSelected, isFocused: isFocused)))
            .buttonBorderShape(shape)
    }

    /// The same detail-control material for a single custom focus owner. Use
    /// this when a native Button plus an eligibility wrapper would create two
    /// competing focus/activation interactions.
    func tvDetailGlassSurface(
        in shape: some Shape,
        isSelected: Bool = false,
        isFocused: Bool = false
    ) -> some View {
        glassEffect(
            detailGlass(isSelected: isSelected, isFocused: isFocused)
                .interactive(),
            in: shape
        )
    }
}

private func detailGlass(isSelected: Bool, isFocused: Bool) -> Glass {
    if isFocused {
        Glass.clear.tint(Color.white.opacity(0.94))
    } else if isSelected {
        Glass.clear.tint(Color.white.opacity(0.26))
    } else {
        Glass.clear
    }
}
#endif
