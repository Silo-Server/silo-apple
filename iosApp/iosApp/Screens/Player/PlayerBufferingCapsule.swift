import SwiftUI

/// A single, shell-level buffering indicator shared by every player surface.
struct PlayerBufferingCapsule: View {
    var body: some View {
        HStack(spacing: spacing) {
            ProgressView()
                .tint(.white)
                .progressViewStyle(.circular)
                .scaleEffect(spinnerScale)

            Text("Loading…")
                .font(.continuumSmall.weight(.medium))
                .foregroundStyle(.white.opacity(0.82))
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 6)
        .siloPlayerGlass(in: Capsule())
        .shadow(color: .black.opacity(0.45), radius: 18, y: 7)
        .padding(.top, topPadding)
        .padding(.trailing, trailingPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading")
    }

    private var spacing: CGFloat {
        #if os(tvOS)
        8
        #else
        7
        #endif
    }

    private var spinnerScale: CGFloat {
        #if os(tvOS)
        0.9
        #else
        0.8
        #endif
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        12
        #else
        10
        #endif
    }

    private var topPadding: CGFloat {
        #if os(tvOS)
        64
        #elseif os(macOS)
        88
        #else
        68
        #endif
    }

    private var trailingPadding: CGFloat {
        #if os(tvOS)
        80
        #elseif os(macOS)
        20
        #else
        16
        #endif
    }
}
