#if !os(tvOS)
import SwiftUI

/// "Video" and "Audiobooks" skip-interval groups for the iOS and macOS
/// playback settings. The values belong to the profile on the server, so
/// they follow the profile to every device and are not touched by the
/// device-override reset below them.
struct SeekIntervalSettingsSections: View {
    @State private var store = SeekIntervalPreferences.shared
    /// The app language, so a switch re-renders the footers.
    @Environment(\.locale) private var locale

    /// The Mac has no touch gestures or remote, so its footer names only
    /// the inputs it has.
    private static var videoFooter: LocalizedStringResource {
        #if os(macOS)
        .settingsSkipIntervalsFooterVideoMac
        #else
        .settingsSkipIntervalsFooterVideoApple
        #endif
    }

    var body: some View {
        Group {
            section(
                title: .settingsSectionVideo,
                media: .video,
                surface: .videoPlayer,
                footer: Self.videoFooter
            )
            // On one child: some SwiftUI releases apply a Group's modifiers to
            // every child, which would refresh once per section.
            .task { await store.refresh() }
            section(
                title: .settingsSeekIntervalsAudiobooks,
                media: .audiobook,
                surface: .audiobook,
                footer: .settingsSkipIntervalsFooterAudiobook
            )
        }
    }

    private func section(
        title: LocalizedStringResource,
        media: SeekMedia,
        surface: SeekIntervalSurface,
        footer: LocalizedStringResource
    ) -> some View {
        Section {
            picker(.settingsControlSkipBack, media: media, direction: .backward, surface: surface)
            picker(.settingsControlSkipForward, media: media, direction: .forward, surface: surface)
        } header: {
            Text(title)
                .foregroundStyle(Color.siloSecondaryText)
        } footer: {
            Text(verbatim: footerText(footer, media: media))
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    private func picker(
        _ label: LocalizedStringResource,
        media: SeekMedia,
        direction: SeekDirection,
        surface: SeekIntervalSurface
    ) -> some View {
        Picker(label, selection: Binding(
            get: { store.seconds(direction, for: surface) },
            set: { store.setInterval($0, media: media, direction: direction) }
        )) {
            ForEach(SeekIntervalContract.choices, id: \.self) { seconds in
                Text(SeekIntervalLabel.choiceLabel(seconds)).tag(seconds)
            }
        }
        .foregroundStyle(Color.siloOnSurface)
        .disabled(!store.allowsEditing)
        .settingsPickerStyle()
    }

    /// The usage note, then whatever keeps the pickers from saving, then any
    /// failed save for this group, one line per direction.
    private func footerText(_ usage: LocalizedStringResource, media: SeekMedia) -> String {
        var lines = [AppLanguage.string(usage, locale: locale)]
        if let status = store.statusMessage {
            lines.append(status)
        }
        for direction in SeekDirection.allCases {
            if let error = store.writeErrors[SeekIntervalContract.key(media, direction)] {
                lines.append(error)
            }
        }
        return lines.joined(separator: "\n")
    }
}
#endif
