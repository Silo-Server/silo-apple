import SwiftUI

func calendarEventAccessibilityLabel(_ event: CalendarEvent) -> String {
    var components = [event.title]
    components.append(contentsOf: [
        event.episodeSubtitle,
        event.episodeTitle,
    ].compactMap { value in
        guard let value, !value.isEmpty else { return nil }
        return value
    })
    if event.type == "movie" {
        components.append("Movie")
    }
    if let displayAirTime = event.displayAirTime {
        components.append(displayAirTime)
    }
    components.append(contentsOf: event.displayBadges.map(\.label))
    if event.isWatched {
        components.append("Watched")
    }
    return components.joined(separator: ", ")
}

/// Poster card for a single calendar event: badge pills, watched check,
/// air-time caption, and an episode subtitle line. Purpose-built rather
/// than wrapping `MediaCard` so badge overlays live inside the tvOS
/// focus-lifted button and scale with the poster.
struct CalendarEventCard: View {
    let event: CalendarEvent
    let action: () -> Void
    /// tvOS-only: parent shelf's focus tracking, so the shelf can route
    /// default focus to a specific card.
    var focusedItemId: FocusState<String?>.Binding? = nil
    @State private var uiCustomization = UICustomizationPreferences.shared

    private var cardWidth: CGFloat {
        SiloTheme.posterCardWidth * uiCustomization.cardPresentation.posterSize.scale
    }
    private var cardHeight: CGFloat {
        cardWidth * (SiloTheme.posterCardHeight / SiloTheme.posterCardWidth)
    }

    var body: some View {
        #if os(tvOS)
        FocusableCalendarCard(
            event: event,
            cardWidth: cardWidth,
            captionStyle: uiCustomization.cardPresentation.caption,
            action: action,
            focusedItemId: focusedItemId
        ) {
            posterImage
        }
        #else
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                posterImage
                if uiCustomization.cardPresentation.caption.showsTitle {
                    captionText
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: cardWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        #endif
    }

    // MARK: - Poster

    private var posterImage: some View {
        ZStack {
            AsyncImageView(
                url: event.posterUrl ?? "",
                thumbhash: event.posterThumbhash,
                targetSize: CGSize(width: cardWidth, height: cardHeight),
                contentMode: .fill
            )
            .frame(width: cardWidth, height: cardHeight)
            .clipped()

            // Badge pills (top-leading) and watched check (top-trailing)
            // share the top edge; the server never sends more than two
            // badges for one event.
            VStack(alignment: .leading, spacing: badgeSpacing) {
                ForEach(event.displayBadges, id: \.rawValue) { badge in
                    CalendarBadgePill(badge: badge)
                }
            }
            .padding(overlayPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if event.isWatched {
                ZStack {
                    Circle()
                        .fill(Color.siloOnSurface)
                        .frame(width: checkBadgeSize, height: checkBadgeSize)
                        .shadow(color: .black.opacity(0.3), radius: 4)
                    Image(systemName: "checkmark")
                        .font(.system(size: checkIconSize, weight: .bold))
                        .foregroundColor(.siloBackground)
                }
                .padding(overlayPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            if let time = event.displayAirTime {
                Text(time)
                    .font(.system(size: timeFontSize, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, timePillHorizontalPadding)
                    .padding(.vertical, timePillVerticalPadding)
                    .background(Capsule().fill(Color.black.opacity(0.62)))
                    .padding(overlayPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: SiloTheme.cornerRadius))
    }

    // MARK: - Caption (shared layout, used directly on iOS)

    @ViewBuilder
    fileprivate var captionText: some View {
        CalendarCardCaption(
            event: event,
            cardWidth: cardWidth,
            showsMetadata: uiCustomization.cardPresentation.caption.showsMetadata
        )
    }

    private var accessibilityDescription: String {
        calendarEventAccessibilityLabel(event)
    }

    // MARK: - Metrics

    private var badgeSpacing: CGFloat {
        #if os(tvOS)
        return 8
        #else
        return 4
        #endif
    }

    private var overlayPadding: CGFloat {
        #if os(tvOS)
        return 12
        #else
        return 6
        #endif
    }

    private var checkBadgeSize: CGFloat {
        #if os(tvOS)
        return 40
        #else
        return 20
        #endif
    }

    private var checkIconSize: CGFloat {
        #if os(tvOS)
        return 20
        #else
        return 10
        #endif
    }

    private var timeFontSize: CGFloat {
        #if os(tvOS)
        return 20
        #else
        return 10
        #endif
    }

    private var timePillHorizontalPadding: CGFloat {
        #if os(tvOS)
        return 12
        #else
        return 6
        #endif
    }

    private var timePillVerticalPadding: CGFloat {
        #if os(tvOS)
        return 5
        #else
        return 2
        #endif
    }
}

// MARK: - Badge pill

/// Monochrome editorial pill — white fill, black text — consistent with
/// the app's Plezy mono palette (no accent colors).
private struct CalendarBadgePill: View {
    let badge: CalendarBadge

    var body: some View {
        Text(badge.label)
            .font(.system(size: fontSize, weight: .bold))
            .tracking(0.8)
            .lineLimit(1)
            .foregroundColor(.siloBackground)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(Capsule().fill(Color.siloOnSurface.opacity(0.92)))
    }

    private var fontSize: CGFloat {
        #if os(tvOS)
        return 18
        #else
        return 8
        #endif
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        return 12
        #else
        return 6
        #endif
    }

    private var verticalPadding: CGFloat {
        #if os(tvOS)
        return 5
        #else
        return 2.5
        #endif
    }
}

// MARK: - Caption

/// Title + context line under the poster. Reserves two title lines so
/// cards in a shelf stay top-aligned regardless of wrapping.
private struct CalendarCardCaption: View {
    let event: CalendarEvent
    let cardWidth: CGFloat
    var showsMetadata: Bool = true
    var isFocused: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(event.title)
                .font(.siloSubheadline)
                .foregroundColor(isFocused ? .siloOnSurface : .siloOnSurface.opacity(0.85))
                .lineLimit(2, reservesSpace: true)

            if showsMetadata, let subtitle {
                Text(subtitle)
                    .font(.siloCaption)
                    .foregroundColor(.siloSecondaryText)
                    .lineLimit(1)
            }
        }
        .frame(width: cardWidth, alignment: .leading)
    }

    /// "S5 · E14 · Ozymandias" for episodes, "Season 2" for premieres,
    /// "Movie" for film releases — mirrors the web calendar card.
    private var subtitle: String? {
        var parts: [String] = []
        if let episodeSubtitle = event.episodeSubtitle {
            parts.append(episodeSubtitle)
        }
        if event.type == "episode", let episodeTitle = event.episodeTitle, !episodeTitle.isEmpty {
            parts.append(episodeTitle)
        }
        if event.type == "movie" {
            parts.append("Movie")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - tvOS focusable wrapper

#if os(tvOS)
/// Mirrors `MediaCard`'s tvOS structure: the poster lives inside a
/// `.card`-styled button (native focus lift + parallax) and the caption
/// sits outside, brightening when the card is focused.
private struct FocusableCalendarCard<Content: View>: View {
    let event: CalendarEvent
    let cardWidth: CGFloat
    let captionStyle: CardCaptionStyle
    let action: () -> Void
    let focusedItemId: FocusState<String?>.Binding?
    @ViewBuilder var content: () -> Content

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: action) {
                content()
            }
            .buttonStyle(.card)
            .focused($isFocused)
            .applyShelfFocus(focusedItemId, itemId: event.contentId)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityDescription)

            if captionStyle.showsTitle {
                CalendarCardCaption(
                    event: event,
                    cardWidth: cardWidth,
                    showsMetadata: captionStyle.showsMetadata,
                    isFocused: isFocused
                )
                .animation(.easeOut(duration: 0.15), value: isFocused)
            }
        }
        .frame(width: cardWidth)
    }

    private var accessibilityDescription: String {
        calendarEventAccessibilityLabel(event)
    }
}

private extension View {
    /// Conditionally binds the card to the parent shelf's `@FocusState`
    /// so the shelf's `defaultFocus(... priority: .userInitiated)` can
    /// land focus here. No-op when the shelf doesn't manage focus.
    @ViewBuilder
    func applyShelfFocus(
        _ binding: FocusState<String?>.Binding?,
        itemId: String
    ) -> some View {
        if let binding {
            self.focused(binding, equals: itemId)
        } else {
            self
        }
    }
}
#endif
