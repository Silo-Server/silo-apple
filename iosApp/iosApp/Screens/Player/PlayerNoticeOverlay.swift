import Foundation
import SwiftUI

enum PlayerNoticeTone {
    case info
    case warning

    var accentColor: Color {
        switch self {
        case .info:
            return .continuumPrimary
        case .warning:
            return .continuumWarning
        }
    }
}

struct PlayerNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let tone: PlayerNoticeTone
}

struct PlayerNoticeOverlay: View {
    let notice: PlayerNotice

    var body: some View {
        HStack(spacing: ContinuumTheme.spacing) {
            Circle()
                .fill(notice.tone.accentColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: ContinuumTheme.smallPadding) {
                Text(notice.title)
                    .font(.continuumSubheadline)
                    .foregroundColor(.continuumOnSurface)

                Text(notice.message)
                    .font(.continuumBody)
                    .foregroundColor(.continuumSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, ContinuumTheme.padding)
        .padding(.vertical, ContinuumTheme.spacing)
        .frame(maxWidth: 720)
        .siloPlayerGlass(
            in: RoundedRectangle(
                cornerRadius: ContinuumTheme.cardCornerRadius,
                style: .continuous
            ),
            tint: notice.tone.accentColor.opacity(0.28)
        )
        .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
        .padding(.horizontal, ContinuumTheme.safePadding)
        .padding(.top, ContinuumTheme.safePadding)
        .transition(
            .move(edge: .top)
            .combined(with: .opacity)
        )
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(notice.title). \(notice.message)")
    }
}
