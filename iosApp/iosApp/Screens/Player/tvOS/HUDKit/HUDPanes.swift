#if os(tvOS)
import SwiftUI

// Pane scaffolding shared by every `TVPlayerInfoHUD` content pane: the
// column header, the composite-focus scrollable pane, and the read-only
// label/value row. Extracted from TVPlayerInfoHUD.swift; behavior unchanged.

// MARK: - Shared column header

struct PaneColumn<Content: View>: View {
    let header: String
    let content: () -> Content

    init(_ header: String, @ViewBuilder content: @escaping () -> Content) {
        self.header = header
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(header.uppercased())
                .font(.system(size: 14, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(.white.opacity(0.5))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HUDScrollablePane<Content: View>: View {
    let accessibilityLabel: String
    let scrollTargetIDs: [String]
    @Binding var isAtTop: Bool
    let onMoveToTabs: () -> Void
    let content: () -> Content

    @State private var scrollTargetIndex: Int = 0
    @FocusState private var isFocused: Bool

    init(
        accessibilityLabel: String,
        scrollTargetIDs: [String] = [],
        isAtTop: Binding<Bool>,
        onMoveToTabs: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.scrollTargetIDs = scrollTargetIDs
        self._isAtTop = isAtTop
        self.onMoveToTabs = onMoveToTabs
        self.content = content
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                content()
                    .padding(.trailing, 8)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .focusable(true)
            .focused($isFocused)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isFocused ? Color.white.opacity(0.86) : Color.clear, lineWidth: 2)
                    .padding(-10)
            )
            .scaleEffect(isFocused ? 1.01 : 1)
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
            .accessibilityLabel(accessibilityLabel)
            .onMoveCommand { direction in
                handleMove(direction, proxy: proxy)
            }
            .onChange(of: scrollTargetIDs) { _, targets in
                scrollTargetIndex = min(scrollTargetIndex, max(targets.count - 1, 0))
            }
            .onChange(of: scrollTargetIndex) { _, index in
                isAtTop = index == 0
            }
            .onAppear {
                isAtTop = scrollTargetIndex == 0
            }
            .onDisappear {
                isAtTop = true
            }
        }
    }

    private func handleMove(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
        guard isFocused else { return }

        let nextIndex: Int
        switch direction {
        case .up:
            guard !scrollTargetIDs.isEmpty, scrollTargetIndex > 0 else {
                onMoveToTabs()
                return
            }
            nextIndex = max(scrollTargetIndex - 1, 0)
        case .down:
            guard !scrollTargetIDs.isEmpty else { return }
            nextIndex = min(scrollTargetIndex + 1, scrollTargetIDs.count - 1)
        default:
            return
        }

        guard nextIndex != scrollTargetIndex else { return }
        scrollTargetIndex = nextIndex

        withAnimation(.easeOut(duration: SiloTheme.fastDuration)) {
            proxy.scrollTo(scrollTargetIDs[nextIndex], anchor: .top)
        }
    }
}

/// Right-aligned "label — value" row used in the Info and options columns.
struct LabelValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
            Spacer(minLength: 16)
            Text(value)
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.7))
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}
#endif
