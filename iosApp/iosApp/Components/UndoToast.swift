#if !os(tvOS)
import SwiftUI

/// A short-lived bar at the bottom of a page that confirms something just
/// went away ("Rating removed") and offers to put it back. Show one with
/// `undoToast(_:)`.
struct UndoToast: View {
    let message: String
    let actionTitle: String
    var actionColor: Color = .white
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(message)
                .siloScaledFont(size: 15, weight: .regular, relativeTo: .subheadline)
                .foregroundStyle(Color.white)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: action) {
                Text(actionTitle)
                    .siloScaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                    .foregroundStyle(actionColor)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(hex: "#23262E"))
                .shadow(color: .black.opacity(0.5), radius: 15, y: 10)
        )
        .accessibilityElement(children: .contain)
    }
}

/// One toast to show: `id` changes for each new one, which restarts its
/// timer and announces it again.
struct UndoToastContent: Equatable {
    let id: Int
    let message: String
    let actionTitle: String
    var actionColor: Color = .white
}

extension View {
    /// Shows `content` as an `UndoToast` above the bottom safe area (and so
    /// above a mini player) until `onTimeout` after five seconds, or ten
    /// with VoiceOver on, which also hears it announced. `onAction` runs for
    /// the button; the caller then clears `content`.
    func undoToast(
        _ content: UndoToastContent?,
        onAction: @escaping () -> Void,
        onTimeout: @escaping (_ id: Int) -> Void
    ) -> some View {
        modifier(UndoToastHost(content: content, onAction: onAction, onTimeout: onTimeout))
    }
}

private struct UndoToastHost: ViewModifier {
    let content: UndoToastContent?
    let onAction: () -> Void
    let onTimeout: (Int) -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content page: Content) -> some View {
        page.overlay(alignment: .bottom) {
            ZStack {
                if let content {
                    UndoToast(
                        message: content.message,
                        actionTitle: content.actionTitle,
                        actionColor: content.actionColor,
                        action: onAction
                    )
                    .frame(maxWidth: horizontalSizeClass == .regular ? 440 : .infinity)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
                    .task(id: content.id) {
                        AccessibilityNotification.Announcement(content.message).post()
                        try? await Task.sleep(for: .seconds(voiceOverEnabled ? 10 : 5))
                        guard !Task.isCancelled else { return }
                        onTimeout(content.id)
                    }
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : SiloTheme.springAnimation, value: content?.id)
        }
    }
}
#endif
