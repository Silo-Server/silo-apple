import Foundation
import SwiftUI

enum PlayerNoticeTone {
    case info
    case warning

    var accentColor: Color {
        switch self {
        case .info:
            return .siloPrimary
        case .warning:
            return .siloWarning
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
        HStack(spacing: SiloTheme.spacing) {
            Circle()
                .fill(notice.tone.accentColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: SiloTheme.smallPadding) {
                Text(notice.title)
                    .font(.siloSubheadline)
                    .foregroundColor(.siloOnSurface)

                Text(notice.message)
                    .font(.siloBody)
                    .foregroundColor(.siloSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, SiloTheme.padding)
        .padding(.vertical, SiloTheme.spacing)
        .frame(maxWidth: 720)
        .siloPlayerGlass(
            in: RoundedRectangle(
                cornerRadius: SiloTheme.cardCornerRadius,
                style: .continuous
            ),
            tint: notice.tone.accentColor.opacity(0.28)
        )
        .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
        .padding(.horizontal, SiloTheme.safePadding)
        .padding(.top, SiloTheme.safePadding)
        .transition(
            .move(edge: .top)
            .combined(with: .opacity)
        )
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(notice.title). \(notice.message)")
    }
}

// MARK: - Buffering quality pill

extension BufferingQualityController.PillKind {
    /// The prompt's title or the undo pill's caption. Always its own element,
    /// apart from the actions, so the two never read as one phrase.
    var message: String {
        switch self {
        case .prompt: return BufferingQualityController.promptTitle
        case .undo: return BufferingQualityController.undoCaption
        }
    }

    /// Select's action: **Lower quality**, or **Restore quality** on the undo
    /// pill. It carries the countdown.
    var primaryAction: String {
        switch self {
        case .prompt: return BufferingQualityController.lowerAction
        case .undo: return BufferingQualityController.undoAction
        }
    }

    /// The prompt's **Keep quality**. The undo pill has one action.
    var secondaryAction: String? {
        switch self {
        case .prompt: return BufferingQualityController.keepAction
        case .undo: return nil
        }
    }

    var tone: PlayerNoticeTone {
        switch self {
        case .prompt: return .warning
        case .undo: return .info
        }
    }
}

/// The buffering prompt or undo pill, drawn as a notice card: the accent dot
/// and message, then the platform's buttons. Only the buttons take hits, so a
/// tap anywhere else on the card still reaches the player.
struct PlayerBufferingPillCard<Actions: View>: View {
    let kind: BufferingQualityController.PillKind
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        layout
            .padding(.horizontal, SiloTheme.padding)
            .padding(.vertical, SiloTheme.spacing)
            .frame(maxWidth: 720)
            .background {
                Color.clear
                    .siloPlayerGlass(
                        in: RoundedRectangle(
                            cornerRadius: SiloTheme.cardCornerRadius,
                            style: .continuous
                        ),
                        tint: kind.tone.accentColor.opacity(0.28)
                    )
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var layout: some View {
        #if os(tvOS)
        // One arrangement on the TV: swapping between two would rebuild the
        // buttons under the focus engine.
        VStack(alignment: .leading, spacing: SiloTheme.spacing) {
            message
            actions()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #else
        // Side by side where they fit; the actions drop below the message on
        // a portrait iPhone or a narrow window.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: SiloTheme.spacing) {
                message
                Spacer(minLength: SiloTheme.spacing)
                actions()
            }
            VStack(alignment: .leading, spacing: SiloTheme.spacing) {
                message
                actions()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #endif
    }

    private var message: some View {
        HStack(spacing: SiloTheme.spacing) {
            Circle()
                .fill(kind.tone.accentColor)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)

            Text(kind.message)
                .font(.siloSubheadline)
                .foregroundColor(.siloOnSurface)
                .fixedSize(horizontal: false, vertical: true)
        }
        .allowsHitTesting(false)
    }
}

/// The notice position, shared by a display-only notice and the buffering
/// pill. The notice lays out exactly as it does alone. The pill sits just
/// below it, or at the notice's own inset when there is none, and never above
/// `pillMinY`, so a platform can keep the pill's buttons clear of its chrome.
/// Mark the pill with ``SwiftUI/View/playerNoticeStackPill()``.
struct PlayerNoticeStack: Layout {
    /// The highest the pill's top edge may sit, in the stack's space.
    var pillMinY: CGFloat = SiloTheme.safePadding
    var spacing: CGFloat = SiloTheme.smallPadding

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(of: subviews, width: proposal.width)
        return CGSize(
            width: proposal.width ?? frames.map(\.width).max() ?? 0,
            height: frames.map(\.maxY).max() ?? 0
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(of: subviews, width: bounds.width)) {
            subview.place(
                at: CGPoint(x: bounds.midX, y: bounds.minY + frame.minY),
                anchor: .top,
                proposal: ProposedViewSize(width: bounds.width, height: frame.height)
            )
        }
    }

    private func frames(of subviews: Subviews, width: CGFloat?) -> [CGRect] {
        var noticeBottom: CGFloat?
        return subviews.map { subview in
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            guard subview[PlayerNoticeStackPill.self] else {
                noticeBottom = max(noticeBottom ?? 0, size.height)
                return CGRect(origin: .zero, size: size)
            }
            let y = max(noticeBottom.map { $0 + spacing } ?? 0, pillMinY)
            return CGRect(origin: CGPoint(x: 0, y: y), size: size)
        }
    }
}

private struct PlayerNoticeStackPill: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    /// Marks the buffering pill inside a ``PlayerNoticeStack``. Apply it last.
    func playerNoticeStackPill() -> some View {
        layoutValue(key: PlayerNoticeStackPill.self, value: true)
    }
}

#if DEBUG
extension BufferingQualityController.Pill {
    /// A pill partway through its timer, for previews.
    static func preview(_ kind: BufferingQualityController.PillKind) -> Self {
        Self(
            kind: kind,
            deadline: Date().addingTimeInterval(9),
            remaining: 9,
            total: BufferingQualityController.promptSeconds
        )
    }
}

extension PlayerNotice {
    static let preview = PlayerNotice(
        title: "Subtitles ready",
        message: "English subtitles are now available.",
        tone: .info
    )
}
#endif
