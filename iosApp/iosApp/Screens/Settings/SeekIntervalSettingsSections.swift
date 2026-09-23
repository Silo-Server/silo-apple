#if !os(tvOS)
import SwiftUI

/// "Video" and "Audiobooks" skip-interval groups for the iOS and macOS
/// playback settings. The values belong to the profile on the server, so
/// they follow the profile to every device and are not touched by the
/// device-override reset below them.
struct SeekIntervalSettingsSections: View {
    @State private var store = SeekIntervalPreferences.shared

    var body: some View {
        Group {
            section(
                title: "Video",
                media: .video,
                surface: .videoPlayer,
                footer: "Used by the on-screen skip buttons, double-tap, arrow keys, and remote clicks."
            )
            section(
                title: "Audiobooks",
                media: .audiobook,
                surface: .audiobook,
                footer: "Used by the audiobook player's skip buttons."
            )
        }
        .task { await store.refresh() }
    }

    private func section(
        title: String,
        media: SeekMedia,
        surface: SeekIntervalSurface,
        footer: String
    ) -> some View {
        Section {
            picker("Skip Back", media: media, direction: .backward, surface: surface)
            picker("Skip Forward", media: media, direction: .forward, surface: surface)
        } header: {
            Text(title)
                .foregroundStyle(Color.siloSecondaryText)
        } footer: {
            Text(footerText(footer, media: media))
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloSurfaceElevated)
    }

    private func picker(
        _ label: String,
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
        #if os(macOS)
        .pickerStyle(.menu)
        #else
        .pickerStyle(.navigationLink)
        #endif
    }

    /// The usage note, then whatever keeps the pickers from saving, then any
    /// failed save for this group, one line per direction.
    private func footerText(_ usage: String, media: SeekMedia) -> String {
        var lines = [usage + " Applies to every device signed in to this profile."]
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
