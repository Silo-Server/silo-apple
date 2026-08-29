#if os(tvOS)
import SwiftUI

/// The single native Liquid Glass treatment for interactive controls on
/// tvOS detail pages. Buttons and menus keep their own labels and semantics;
/// this modifier owns the material, selection tint, and border shape.
extension View {
    func tvDetailGlassControl(
        shape: ButtonBorderShape,
        isSelected: Bool = false
    ) -> some View {
        let glass = isSelected
            ? Glass.clear.tint(Color.white.opacity(0.76))
            : Glass.clear

        return buttonStyle(.glass(glass))
            .buttonBorderShape(shape)
    }
}
#endif
