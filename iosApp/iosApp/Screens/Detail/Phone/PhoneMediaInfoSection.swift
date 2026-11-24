#if !os(tvOS)
import SwiftUI

/// "Media Info" on the phone, tablet and Mac title pages: the technical
/// details of the file version the page's selectors show.
///
/// It is the last section of the page and stays collapsed to its header
/// until the viewer opens it, so it never pushes another section down. The
/// rows follow the selected version, and on a series page the selected
/// episode.
struct PhoneMediaInfoSection: View {
    /// Nil while the page has no version to describe; the section then
    /// draws nothing.
    let version: FileVersion?
    /// The episode the version belongs to on a series page, named in the
    /// header. Nil on a movie page.
    var episode: EpisodeListItem? = nil
    /// Owned by the page, so the section stays open when the page changes
    /// between its one-column and split layouts, and while an episode loads.
    @Binding var isExpanded: Bool

    @Environment(\.locale) private var locale

    var body: some View {
        let facts = version.map { DetailMediaInfo.videoAndFileFacts($0, locale: locale) } ?? []
        let hasAudio = !(version?.audioTracks ?? []).isEmpty
        if let version, !facts.isEmpty || hasAudio {
            VStack(alignment: .leading, spacing: 14) {
                header
                // The audio rows are built only while the section is open:
                // cleaning each track's title is the costly part.
                if isExpanded {
                    if !facts.isEmpty {
                        PhoneDetailFactList(facts: facts, readsRowsWhole: true)
                    }
                    if hasAudio {
                        Text(.detailAudio)
                            .siloScaledFont(size: 16, weight: .semibold, relativeTo: .headline)
                            .foregroundColor(.siloOnSurface)
                            .padding(.top, 8)
                        PhoneDetailFactList(facts: DetailMediaInfo.audioFacts(version), readsRowsWhole: true)
                    }
                }
            }
            .padding(.horizontal, SiloTheme.safePadding)
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                PhoneSectionHeader(title: title, trailingText: episodeCode)
                Image(systemName: "chevron.down")
                    .siloScaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                    .foregroundColor(.siloSecondaryText)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: [title, spokenEpisode].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityValue(Text(isExpanded ? LocalizedStringResource.setupAdvancedExpanded : .setupAdvancedCollapsed))
    }

    private var title: String {
        AppLanguage.string(.webDetailMediaInfoTitle, locale: locale)
    }

    /// "S1·E3", as the page's Play button names the episode.
    private var episodeCode: String? {
        guard let episode else { return nil }
        return AppLanguage.string(
            .detailEpisodeCode(
                LocaleFormat.codeNumber(episode.seasonNumber),
                LocaleFormat.codeNumber(episode.episodeNumber)
            ),
            locale: locale
        )
    }

    private var spokenEpisode: String? {
        guard let episode else { return nil }
        return EpisodeCardCaption.spokenCode(
            season: episode.seasonNumber,
            episode: episode.episodeNumber,
            locale: locale
        )
    }
}
#endif
