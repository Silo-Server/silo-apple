#if os(tvOS)
import SwiftUI
import UIKit

/// Horizontal rail of trailers and extras for the tvOS movie / series
/// detail pages. Mirrors `PhoneTrailersRail` — same merged ordering from
/// `TrailerRail.entries(videos:extras:allowRemote:)` — but renders
/// landscape cards at the 10-foot scale so they read like the episode
/// rail directly above them.
///
/// Pure presentation: the entries arrive already shaped by the call site,
/// which also owns the YouTube-app availability probe that decides whether
/// remote cards exist at all. The section header lives in here (not the
/// parent) so an item with neither trailers nor extras shows nothing at
/// all rather than an orphaned title — the same arrangement `TVSimilarRail`
/// uses.
///
/// Focus follows the other detail rails exactly: one `.focusSection()`
/// around the scroll view, plus a `defaultFocus` that lands d-pad entry on
/// the first card instead of the geometrically-nearest middle one — the
/// same mechanism and `.userInitiated` priority as `TVSimilarRail` and
/// `TVDetailCastRail`. That priority only governs entry *into* this
/// section; the hero's Play button keeps page-entry focus through its own
/// `defaultFocus` on the detail scroll container.
struct TVTrailersRail: View {
    let entries: [TrailerRailEntry]
    let onSelect: (TrailerRailEntry) -> Void

    @FocusState private var focusedEntryId: String?

    private let cardSpacing: CGFloat = 48
    private let railVerticalPadding: CGFloat = 12
    /// Header-to-content gap, matching the other detail sections'
    /// `VStack(spacing: 28)` so the page rhythm stays uniform.
    private let headerSpacing: CGFloat = TVDetailLayout.sectionHeaderSpacing

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: headerSpacing) {
                TVSectionHeader(title: "Trailers & More")
                rail
            }
        }
    }

    // MARK: - Rail

    private var rail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: cardSpacing) {
                ForEach(entries) { entry in
                    TVTrailerCard(entry: entry, onSelect: { onSelect(entry) })
                        .focused($focusedEntryId, equals: entry.id)
                }
            }
            .padding(.vertical, railVerticalPadding)
        }
        .focusSection()
        // Land d-pad entry on the first card, like the cast / similar /
        // episode rails, instead of the geometrically-nearest one.
        .applyTrailerRailDefaultFocus(entries.first?.id, binding: $focusedEntryId)
        .scrollClipDisabled()
    }
}

private extension View {
    /// `.userInitiated` priority is what makes `defaultFocus` win over
    /// geometric proximity on d-pad entry — the same helper shape as
    /// `TVSimilarRail.applySimilarRailDefaultFocus`. No-op on an empty rail
    /// (first id is nil).
    @ViewBuilder
    func applyTrailerRailDefaultFocus(
        _ firstEntryId: String?,
        binding: FocusState<String?>.Binding
    ) -> some View {
        if let firstEntryId {
            self.defaultFocus(binding, firstEntryId, priority: .userInitiated)
        } else {
            self
        }
    }
}

// MARK: - Card

private struct TVTrailerCard: View {
    let entry: TrailerRailEntry
    let onSelect: () -> Void

    private let cardWidth: CGFloat = 470
    private let thumbHeight: CGFloat = 264
    private let thumbCornerRadius: CGFloat = 18

    var body: some View {
        Button(action: onSelect) {
            TrailerCardLabel(
                entry: entry,
                cardWidth: cardWidth,
                thumbHeight: thumbHeight,
                thumbCornerRadius: thumbCornerRadius
            )
        }
        .buttonStyle(TVCardFocusButtonStyle())
    }
}

private struct TrailerCardLabel: View {
    let entry: TrailerRailEntry
    let cardWidth: CGFloat
    let thumbHeight: CGFloat
    let thumbCornerRadius: CGFloat

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .center, spacing: 14) {
            thumbnail
            VStack(alignment: .center, spacing: 5) {
                Text(entry.title)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(titleColor)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)

                if let secondaryLine {
                    Text(secondaryLine)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.continuumSecondaryText)
                        .lineLimit(1)
                }
            }
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
        }
        .frame(width: cardWidth, alignment: .leading)
    }

    private var titleColor: Color {
        isFocused ? .continuumOnSurface : Color.continuumOnSurface.opacity(0.92)
    }

    /// `TrailerRailEntry.title` already falls back to this label when the
    /// server has no name for the entry — in that case the eyebrow alone
    /// says everything and repeating it below would read as a bug.
    private var kindLabel: String {
        ExtraKindLabels.label(for: entry.kind)
    }

    /// Remote cards say where they go — selecting one leaves the app for
    /// the YouTube app. Local extras show their runtime instead.
    private var secondaryLine: String? {
        switch entry {
        case .remote:
            return "YouTube"
        case .local(let extra):
            guard let seconds = extra.durationSeconds, seconds > 0 else { return nil }
            return PlayerTimeFormatter.formatHMS(Double(seconds))
        }
    }

    private var thumbnail: some View {
        ZStack {
            Color.continuumSurfaceElevated
                .frame(width: cardWidth, height: thumbHeight)

            artwork

            playBadge
        }
        .frame(width: cardWidth, height: thumbHeight)
        .clipShape(RoundedRectangle(cornerRadius: thumbCornerRadius))
        .tvFocusRing(isFocused: isFocused, cornerRadius: thumbCornerRadius)
    }

    /// YouTube stills exist for every remote video; local extras have no
    /// artwork at all server-side, so they keep the surface tile plus a
    /// glyph rather than an empty frame.
    @ViewBuilder
    private var artwork: some View {
        switch entry {
        case .remote(let video):
            if let url = TrailerRail.thumbnailURL(siteKey: video.siteKey)?.absoluteString {
                CachedAsyncImage(
                    url: url,
                    targetSize: CGSize(width: cardWidth, height: thumbHeight),
                    contentMode: .fill
                )
                .frame(width: cardWidth, height: thumbHeight)
            }
        case .local:
            Image(systemName: "film")
                .font(.system(size: 48))
                .foregroundColor(.continuumSecondaryText)
                .frame(width: cardWidth, height: thumbHeight)
        }
    }

    private var playBadge: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(isFocused ? 0.72 : 0.55))
                .frame(width: 60, height: 60)
            Image(systemName: "play.fill")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
        }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }
}

// MARK: - Fetch status pill

/// Feedback for the "Find Trailers" action, shown under the hero's action
/// column. The 10-foot counterpart of `PhoneTrailerStatusPill`, with the
/// same behavior: the copy comes from `TrailerFetchCoordinator
/// .statusMessage`, and the terminal outcomes (cooldown / disabled /
/// nothing found) clear themselves after a beat so a dead end never becomes
/// permanent furniture on the page. While the fetch runs the pill persists,
/// because the poll can take a while and the spinner is the only sign
/// anything is happening.
///
/// Explicitly non-focusable: it renders inside the hero's action focus
/// section and must never become a stop on the way down from Play.
struct TVTrailerStatusPill: View {
    let message: String
    /// True while the request or poll is in flight — spinner instead of a
    /// glyph, and no auto-dismiss.
    let isFetching: Bool
    /// Invoked once a terminal message has been visible long enough; the
    /// owner acknowledges it on the coordinator.
    let onAutoDismiss: () -> Void

    /// Matches the phone pill's terminal floor — full sentences need longer
    /// than `RefreshStatusPill`'s one-word status.
    private static let terminalVisibleDuration: TimeInterval = 3

    var body: some View {
        HStack(spacing: 14) {
            if isFetching {
                ProgressView()
                    .tint(.continuumOnSurface)
            } else {
                Image(systemName: "info.circle")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.continuumOnSurface)
            }

            Text(message)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.continuumOnSurface)
                .lineLimit(1)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.18), lineWidth: 1.2)
        )
        .focusable(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        // Keyed on the copy *and* the phase so the timer restarts when
        // "Finding trailers…" is replaced by its outcome.
        .task(id: dismissKey) {
            guard !isFetching else { return }
            try? await Task.sleep(for: .seconds(Self.terminalVisibleDuration))
            guard !Task.isCancelled else { return }
            onAutoDismiss()
        }
    }

    private var dismissKey: String {
        "\(isFetching)|\(message)"
    }
}

// MARK: - YouTube app bridge

/// Deep-link bridge to the installed YouTube app — the only remote-trailer
/// playback path on tvOS, which has no browser to fall back on (iOS falls
/// back to the public watch page in the default browser).
///
/// Plain (non-isolated) statics, matching `PlatformScreen` and
/// `TVFocusDebugOverlay`'s `UIApplication` accessors; every call site is a
/// view-body / `onAppear` closure on the main thread.
enum TVTrailerLaunch {
    /// Whether remote cards may be shown at all.
    ///
    /// `canOpenURL` needs `youtube` listed in the tvOS Info.plist's
    /// `LSApplicationQueriesSchemes` or it returns false regardless of what
    /// is installed. It is also always false on the simulator, which has no
    /// YouTube app — the rail then correctly degrades to local extras only.
    static func isYouTubeAppInstalled() -> Bool {
        guard let probe = URL(string: "youtube://") else { return false }
        return UIApplication.shared.canOpenURL(probe)
    }

    /// Hand a video off to the YouTube app and report whether the system
    /// accepted the launch. Only ever called for cards that exist, i.e. after
    /// ``isYouTubeAppInstalled()`` returned true, but the app can disappear
    /// or reject the URL between that probe and this request.
    static func open(siteKey: String, completion: @escaping (Bool) -> Void) {
        guard let url = TrailerRail.youtubeDeepLinkURL(siteKey: siteKey) else {
            completion(false)
            return
        }
        UIApplication.shared.open(url, options: [:], completionHandler: completion)
    }
}
#endif
