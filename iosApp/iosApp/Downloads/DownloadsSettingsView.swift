#if !os(tvOS)
import SwiftUI

/// Download preferences: Wi-Fi-only, requested quality, series-monitoring
/// retention defaults, and storage usage. Backed by the `DownloadSettings`
/// singleton (local `UserDefaults`, same pattern as `PlayerSettings`).
struct DownloadsSettingsView: View {
    @Bindable private var settings = DownloadSettings.shared
    private var manager: DownloadManager { DownloadManager.shared }
    @State private var showDeleteAllConfirm = false

    private var formats: [DownloadFormat] {
        let available = manager.availableFormats
        return available.isEmpty ? [.original] : available
    }

    var body: some View {
        Form {
            Section {
                Toggle("Download over Wi-Fi only", isOn: $settings.wifiOnly)
                if formats.count > 1 {
                    Picker("Quality", selection: $settings.preferredFormat) {
                        ForEach(formats, id: \.self) { format in
                            Text(format.displayName).tag(format.rawValue)
                        }
                    }
                }
            } header: {
                Text("Downloads")
            } footer: {
                // Quality-behavior copy only makes sense alongside the
                // quality picker, which is hidden when the server offers a
                // single preset.
                if formats.count > 1 {
                    Text("Original prefers source quality and may prepare a compatibility file if this device needs one. Bitrate presets are prepared on the server before download starts.")
                }
            }

            Section("Series Monitoring Defaults") {
                Toggle("Delete watched episodes", isOn: $settings.defaultDeleteWatched)
                Stepper(
                    settings.defaultMaxStorageGB == 0
                        ? "Storage limit: Unlimited"
                        : "Storage limit: \(settings.defaultMaxStorageGB) GB",
                    value: $settings.defaultMaxStorageGB,
                    in: 0...1000,
                    step: 5
                )
            }

            Section {
                Toggle("Keep watched downloads", isOn: $settings.keepWatchedDownloads)
            } header: {
                Text("Cleanup")
            } footer: {
                Text("When off, the Downloads tab suggests freeing up space by removing items you've finished watching.")
            }

            Section("Storage") {
                HStack {
                    Text("Used")
                    Spacer()
                    Text(DownloadFormatting.bytes(manager.totalBytesUsed))
                        .foregroundColor(.continuumSecondaryText)
                }
                if !manager.records.isEmpty {
                    Button(role: .destructive) {
                        showDeleteAllConfirm = true
                    } label: {
                        Text("Remove All Downloads")
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .continuumScrollContentBackgroundHidden()
        .background(Color.continuumBackground)
        .continuumToolbarColorSchemeDark()
        .confirmationDialog(
            "Remove all downloaded files?",
            isPresented: $showDeleteAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove All", role: .destructive) {
                manager.deleteDownloads(ids: manager.records.map(\.id))
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
#endif
