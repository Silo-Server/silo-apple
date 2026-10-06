#if !os(tvOS)
import SwiftUI

// MARK: - Primary play

/// Solid-white capsule play button. Phone-sized — comfortable 52pt
/// touch target with the play icon and label sitting inline.
///
/// `fullWidth` lets the button expand to its container — used in the
/// Apple-TV-style centered hero where Play is the dominant CTA.
///
/// `progress` (0...1) draws a thin track along the bottom of the pill for
/// items resumed from a saved position, such as a half-listened audiobook.
struct PhonePrimaryPillButton: View {
    let icon: String
    let title: String
    let action: () -> Void
    var fullWidth: Bool = false
    var progress: Double? = nil

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.body.bold())
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundColor(.black)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(minHeight: 52)
            .background {
                ZStack {
                    Capsule().fill(Color.white)
                    if let progress, progress > 0 {
                        progressTrack(progress)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func progressTrack(_ progress: Double) -> some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width - 48)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.14))
                Capsule()
                    .fill(Color.black.opacity(0.78))
                    .frame(width: max(4, width * min(1, progress)))
            }
            .frame(width: width, height: 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 6)
        }
        .accessibilityHidden(true)
    }
}

#endif
