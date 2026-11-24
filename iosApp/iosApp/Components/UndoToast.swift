#if !os(tvOS)
import SwiftUI

/// A short-lived floating glass capsule near the bottom of a page that
/// confirms something just went away ("Rating removed") and offers to put it
/// back. It hugs its text, like the system's own transient pills, instead of
/// spanning the screen. Show one with `undoToast(_:)`.
struct UndoToast: View {
    let message: String
    let actionTitle: String
    var actionColor: Color = .white
    let action: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Text(message)
                .siloScaledFont(size: 15, weight: .medium, relativeTo: .subheadline)
                .foregroundStyle(Color.white.opacity(0.86))
                .lineLimit(2)
                .padding(.leading, 20)
                .padding(.trailing, 14)
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 20)
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 13, weight: .semibold))
                    Text(actionTitle)
                        .siloScaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                }
                .foregroundStyle(actionColor)
                .padding(.leading, 14)
                .padding(.trailing, 20)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(minHeight: 48)
        .siloGlass(in: Capsule(), interactive: true)
        .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
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
    /// above a mini player) until a swipe down, `onTimeout` after five seconds, or ten
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
                    .frame(maxWidth: 440)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    .gesture(
                        DragGesture(minimumDistance: 12).onEnded { drag in
                            if drag.translation.height > 16 { onTimeout(content.id) }
                        }
                    )
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .scale(scale: 0.86, anchor: .bottom)
                                .combined(with: .offset(y: 24))
                                .combined(with: .opacity)
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
