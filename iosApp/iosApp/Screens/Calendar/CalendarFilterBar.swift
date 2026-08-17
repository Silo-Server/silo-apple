import SwiftUI

/// Following / Trending / All scope control.
///
/// - iOS / macOS: a contained segmented control — a visible track holding a
///   single near-white pill that slides between segments. The track is what
///   keeps the control from reading as loose, clipped text against the black
///   background (the previous glass capsule was invisible there).
/// - tvOS: capsule glass segments that draw their own focus chrome (the app
///   suppresses the system focus slab).
struct CalendarFilterBar: View {
    let selected: CalendarFilter
    let onSelect: (CalendarFilter) -> Void
    /// tvOS: programmatic focus kick from the root focus hand-down, so the
    /// remote is never dead when the Calendar tab swaps in.
    var focusRequest: Int = 0
    /// tvOS: edge-up escape back to the top menu bar.
    var onMoveUp: (() -> Void)? = nil

    #if os(tvOS)
    @FocusState private var focusedFilter: CalendarFilter?
    /// Each hand-down token claims focus exactly once; guards against
    /// `onAppear` re-fires yanking focus on scroll recycling.
    @State private var lastAppliedFocusRequest = 0
    #else
    /// Drives the sliding selected pill across segments.
    @Namespace private var pillNamespace
    #endif

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        phoneBody
        #endif
    }

    // MARK: - iOS / macOS

    #if !os(tvOS)
    private var phoneBody: some View {
        HStack(spacing: segmentSpacing) {
            ForEach(CalendarFilter.allCases) { filter in
                phoneSegment(filter)
            }
        }
        .padding(containerPadding)
        .background(
            Capsule(style: .continuous).fill(Color.white.opacity(0.07))
        )
        .overlay(
            Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .animation(SiloTheme.springAnimation, value: selected)
        .accessibilityElement(children: .contain)
    }

    private func phoneSegment(_ filter: CalendarFilter) -> some View {
        let isSelected = selected == filter
        return Button {
            onSelect(filter)
        } label: {
            Text(filter.displayLabel)
                .font(segmentFont)
                .lineLimit(1)
                .foregroundColor(isSelected ? Color.siloBackground : Color.siloOnSurface.opacity(0.6))
                .padding(.horizontal, segmentHorizontalPadding)
                .frame(height: segmentHeight)
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(Color.siloOnSurface)
                            .matchedGeometryEffect(id: "calendarFilterPill", in: pillNamespace)
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.siloFlat)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
    #endif

    // MARK: - tvOS

    #if os(tvOS)
    private var tvBody: some View {
        HStack(spacing: segmentSpacing) {
            ForEach(CalendarFilter.allCases) { filter in
                tvSegmentButton(filter)
            }
        }
        .padding(containerPadding)
        .siloGlass(in: .capsule)
        .focusSection()
        .onMoveCommand { direction in
            if direction == .up {
                onMoveUp?()
            }
        }
        .onAppear { applyFocusRequest(focusRequest) }
        .onChange(of: focusRequest) { _, request in applyFocusRequest(request) }
    }

    private func applyFocusRequest(_ request: Int) {
        guard request > 0, request != lastAppliedFocusRequest else { return }
        lastAppliedFocusRequest = request
        focusedFilter = selected
    }

    private func tvSegmentButton(_ filter: CalendarFilter) -> some View {
        let isSelected = selected == filter
        let isFocused = focusedFilter == filter

        return Button {
            onSelect(filter)
        } label: {
            Text(filter.displayLabel)
                .font(segmentFont)
                .lineLimit(1)
                .foregroundColor(foreground(isSelected: isSelected, isFocused: isFocused))
                .padding(.horizontal, segmentHorizontalPadding)
                .frame(height: segmentHeight)
                .background(
                    Capsule().fill(fill(isSelected: isSelected, isFocused: isFocused))
                )
                .scaleEffect(isFocused ? 1.05 : 1.0)
        }
        .buttonStyle(.siloFlat)
        .focused($focusedFilter, equals: filter)
        .animation(SiloTheme.springAnimation, value: isFocused)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func foreground(isSelected: Bool, isFocused: Bool) -> Color {
        if isFocused || isSelected { return .siloBackground }
        return .siloOnSurface.opacity(0.7)
    }

    private func fill(isSelected: Bool, isFocused: Bool) -> Color {
        if isFocused { return Color.siloOnSurface.opacity(0.96) }
        if isSelected { return Color.siloOnSurface.opacity(0.88) }
        return .clear
    }
    #endif

    // MARK: - Metrics

    private var segmentSpacing: CGFloat {
        #if os(tvOS)
        return 6
        #else
        return 4
        #endif
    }

    private var containerPadding: CGFloat {
        #if os(tvOS)
        return 6
        #else
        return 4
        #endif
    }

    private var segmentFont: Font {
        #if os(tvOS)
        return .system(size: 22, weight: .semibold)
        #else
        return .system(size: 13, weight: .semibold)
        #endif
    }

    private var segmentHorizontalPadding: CGFloat {
        #if os(tvOS)
        return 26
        #else
        return 16
        #endif
    }

    private var segmentHeight: CGFloat {
        #if os(tvOS)
        return 54
        #else
        return 30
        #endif
    }
}
