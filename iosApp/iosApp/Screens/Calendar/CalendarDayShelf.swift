import SwiftUI

/// One day's row in the calendar agenda: a "Today" / "Monday, June 9"
/// heading over a horizontal shelf of event cards, or a compact
/// "Nothing scheduled" stub for event-less days so the week keeps its
/// shape and day-strip taps always have a scroll target.
struct CalendarDayShelf: View {
    let heading: String
    let events: [CalendarEvent]
    let onEventTap: (CalendarEvent) -> Void
    /// tvOS: route default focus to the first card on d-pad entry.
    var prefersDefaultFocusOnFirstItem: Bool = false
    /// tvOS: programmatic focus kick — when this changes to a new
    /// non-zero token, focus jumps to the shelf's first card. Used by
    /// the week strip's day selection to hand focus down to the row it
    /// just scrolled to.
    var focusRequest: Int = 0
    /// tvOS: called when focus enters this shelf from outside it.
    var onFocusGained: (() -> Void)? = nil

    #if os(tvOS)
    @FocusState private var focusedItemId: String?
    /// Each kick token claims focus exactly once, so `onAppear` re-fires
    /// (returning from a detail page) can't yank focus back to a
    /// previously-selected row while the user is browsing elsewhere.
    @State private var lastAppliedFocusRequest = 0
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: rowVerticalSpacing) {
            Text(heading)
                .font(.siloHeadline)
                .foregroundColor(events.isEmpty ? .siloSecondaryText : .siloOnSurface)
                .padding(.horizontal, SiloTheme.safePadding)

            if events.isEmpty {
                emptyRow
            } else {
                shelfContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(tvOS)
        .focusSection()
        // `onAppear` covers a shelf created after the request (a new
        // week's shelves); `onChange` covers shelves already mounted.
        .onAppear { applyFocusRequest(focusRequest) }
        .onChange(of: focusRequest) { _, request in applyFocusRequest(request) }
        .onChange(of: focusedItemId) { oldId, newId in
            if oldId == nil, newId != nil { onFocusGained?() }
        }
        #endif
    }

    #if os(tvOS)
    private func applyFocusRequest(_ request: Int) {
        guard request > 0, request != lastAppliedFocusRequest else { return }
        lastAppliedFocusRequest = request
        guard let firstId = events.first?.contentId else { return }
        // Defer one runloop tick so a freshly-created shelf's cards are
        // attached to the focus system before we claim focus.
        DispatchQueue.main.async {
            focusedItemId = firstId
        }
    }
    #endif

    private var shelfContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: HorizontalMediaRailLayout.cardAlignment, spacing: cardSpacing) {
                ForEach(events) { event in
                    CalendarEventCard(
                        event: event,
                        action: { onEventTap(event) },
                        focusedItemId: shelfFocusBinding
                    )
                }
            }
            .padding(.horizontal, SiloTheme.safePadding)
            .padding(.vertical, verticalCardPadding)
            .phoneMediaRailBounds()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(tvOS)
        .scrollClipDisabled()
        .applyDefaultFirstEventFocus(
            enabled: prefersDefaultFocusOnFirstItem,
            binding: $focusedItemId,
            firstItemId: events.first?.contentId
        )
        #endif
    }

    private var emptyRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.stars")
                .font(.siloCaption)
                .foregroundColor(.siloSecondaryText.opacity(0.5))
            Text("Nothing scheduled")
                .font(.siloCaption)
                .foregroundColor(.siloSecondaryText)
        }
        .padding(.horizontal, SiloTheme.safePadding)
    }

    private var shelfFocusBinding: FocusState<String?>.Binding? {
        #if os(tvOS)
        return $focusedItemId
        #else
        return nil
        #endif
    }

    // MARK: - Metrics

    private var rowVerticalSpacing: CGFloat {
        #if os(tvOS)
        return 20
        #else
        return SiloTheme.smallPadding
        #endif
    }

    private var cardSpacing: CGFloat {
        #if os(tvOS)
        return 40
        #else
        return SiloTheme.spacing
        #endif
    }

    /// Vertical breathing room so the tvOS focus lift doesn't clip.
    private var verticalCardPadding: CGFloat {
        #if os(tvOS)
        return 24
        #else
        return 0
        #endif
    }
}

#if os(tvOS)
private extension View {
    /// Routes both initial and d-pad-entry focus to the shelf's first
    /// card — same `.userInitiated` defaultFocus pattern as `MediaRow`.
    @ViewBuilder
    func applyDefaultFirstEventFocus(
        enabled: Bool,
        binding: FocusState<String?>.Binding,
        firstItemId: String?
    ) -> some View {
        if enabled, let firstItemId {
            self.defaultFocus(binding, firstItemId, priority: .userInitiated)
        } else {
            self
        }
    }
}
#endif
