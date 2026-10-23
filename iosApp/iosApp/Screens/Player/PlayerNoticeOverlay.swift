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

    /// The card's leading symbol when the notice names none of its own.
    var symbol: String {
        switch self {
        case .info:
            return "info.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        }
    }
}

struct PlayerNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let tone: PlayerNoticeTone
    /// The leading SF Symbol, in the tone's colour; the tone's own when nil.
    var symbol: String? = nil
}

struct PlayerNoticeOverlay: View {
    let notice: PlayerNotice

    var body: some View {
        PlayerNoticeCardHeader(
            symbol: notice.symbol ?? notice.tone.symbol,
            tone: notice.tone,
            title: notice.title,
            // A title-only notice, such as the buffering notices, has no
            // second line.
            detail: notice.message.isEmpty ? nil : notice.message
        )
        .playerNoticeCard()
        .padding(.horizontal, SiloTheme.safePadding)
        .padding(.top, SiloTheme.safePadding)
        .transition(
            .move(edge: .top)
            .combined(with: .opacity)
        )
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(notice.message.isEmpty ? notice.title : "\(notice.title). \(notice.message)")
    }
}

// MARK: - Notice card

/// The player's notice card: neutral dark glass, like the player's other
/// controls, that hugs its content up to a cap. Tone shows only in the
/// header's symbol.
private enum PlayerNoticeCardMetrics {
    #if os(tvOS)
    static let maxWidth: CGFloat = 760
    static let horizontalPadding: CGFloat = 32
    static let verticalPadding: CGFloat = 26
    static let spacing: CGFloat = 22
    static let iconSpacing: CGFloat = 18
    static let lineSpacing: CGFloat = 4
    static let cornerRadius: CGFloat = 28
    static let trackHeight: CGFloat = 4
    static let titleFont: Font = .system(size: 30, weight: .semibold)
    static let detailFont: Font = .system(size: 24)
    #else
    static let maxWidth: CGFloat = 600
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 12
    static let spacing: CGFloat = 12
    static let iconSpacing: CGFloat = 10
    static let lineSpacing: CGFloat = 2
    static let cornerRadius: CGFloat = 16
    static let trackHeight: CGFloat = 3
    static let titleFont: Font = .subheadline.weight(.semibold)
    static let detailFont: Font = .footnote
    #endif

    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

/// A notice card's symbol, title and optional second line.
private struct PlayerNoticeCardHeader: View {
    let symbol: String
    let tone: PlayerNoticeTone
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PlayerNoticeCardMetrics.iconSpacing) {
            Image(systemName: symbol)
                .font(PlayerNoticeCardMetrics.titleFont)
                .foregroundStyle(tone.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: PlayerNoticeCardMetrics.lineSpacing) {
                Text(title)
                    .font(PlayerNoticeCardMetrics.titleFont)
                    .foregroundStyle(Color.siloOnSurface)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(PlayerNoticeCardMetrics.detailFont)
                        .foregroundStyle(Color.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// Draws a notice card around this content: padding, the dark glass and
    /// a light shadow. The card takes the width its content needs, at most
    /// the cap, rather than the whole proposal. With `countdown`, a thin
    /// track along the card's bottom edge drains as that timer runs out.
    func playerNoticeCard(countdown: (any PlayerTimedPill)? = nil) -> some View {
        PlayerNoticeCardWidth(maxWidth: PlayerNoticeCardMetrics.maxWidth) {
            padding(.horizontal, PlayerNoticeCardMetrics.horizontalPadding)
                .padding(.vertical, PlayerNoticeCardMetrics.verticalPadding)
                .background {
                    Color.clear
                        .siloPlayerGlass(in: PlayerNoticeCardMetrics.shape, tint: .black.opacity(0.5))
                        .overlay(alignment: .bottom) {
                            if let countdown {
                                PlayerPillCountdownTrack(pill: countdown)
                                    .frame(height: PlayerNoticeCardMetrics.trackHeight)
                            }
                        }
                        .clipShape(PlayerNoticeCardMetrics.shape)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        }
    }
}

/// Offers its content at most `maxWidth` and takes the size the content
/// asks for, so a card hugs short content and wraps long text at the cap.
/// A flexible `.frame(maxWidth:)` would take the whole proposal instead.
private struct PlayerNoticeCardWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(proposal.width ?? maxWidth, maxWidth)
        return subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
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

    /// The prompt's second line, under its title.
    var detail: String? {
        switch self {
        case .prompt: return "Try a lower quality to keep watching"
        case .undo: return nil
        }
    }

    /// Select's action: **Lower quality**, or **Restore quality** on the undo
    /// pill.
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

    var symbol: String {
        switch self {
        case .prompt: return tone.symbol
        case .undo: return "arrow.down.circle.fill"
        }
    }
}

extension BufferingQualityController.Notice {
    /// The notice card's symbol: the undo pill's for a lowering; nil keeps
    /// the tone's.
    var symbol: String? {
        switch self {
        case .lowered: return BufferingQualityController.PillKind.undo.symbol
        case .cantLower: return nil
        }
    }
}

/// The buffering prompt or undo pill, drawn as a notice card: the symbol and
/// message, then the platform's buttons, with the pill's countdown along the
/// bottom edge. Only the buttons take hits, so a tap anywhere else on the
/// card still reaches the player.
struct PlayerBufferingPillCard<Actions: View>: View {
    let pill: BufferingQualityController.Pill
    /// The first line; the kind's own copy when nil.
    var title: String? = nil
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        layout
            .playerNoticeCard(countdown: pill)
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var layout: some View {
        #if os(tvOS)
        // One arrangement on the TV: swapping between two would rebuild the
        // buttons under the focus engine.
        VStack(alignment: .leading, spacing: PlayerNoticeCardMetrics.spacing) {
            message
            actions()
        }
        #else
        // Side by side where they fit; the actions drop below the message on
        // a portrait iPhone or a narrow window.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PlayerNoticeCardMetrics.spacing * 2) {
                message
                actions()
            }
            VStack(alignment: .leading, spacing: PlayerNoticeCardMetrics.spacing) {
                message
                actions()
            }
        }
        #endif
    }

    private var message: some View {
        PlayerNoticeCardHeader(
            symbol: pill.kind.symbol,
            tone: pill.kind.tone,
            title: title ?? pill.kind.message,
            detail: pill.kind.detail
        )
        .accessibilityElement(children: .combine)
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
