#if !os(tvOS)
import SwiftUI

/// Download preferences: Wi-Fi-only, requested quality, series-monitoring
/// retention defaults, and storage usage. Backed by the `DownloadSettings`
/// singleton (local `UserDefaults`, same pattern as `PlayerSettings`).
struct DownloadsSettingsView: View {
    @Bindable private var settings = DownloadSettings.shared
    private var manager: DownloadManager { DownloadManager.shared }
    @State private var showDeleteAllConfirm = false
    @State private var pendingOtherRemoval: DownloadStorageReclaim.OtherStorage?

    private var formats: [DownloadFormat] {
        let available = manager.availableFormats
        return available.isEmpty ? [.original] : available
    }

    /// Mentions the resolution only when the server reports one; an older
    /// server's presets are labelled by bitrate alone. A server without
    /// batch quality downloads seasons and series in original quality.
    private var qualityFooter: String {
        let batches = manager.canChooseBatchQuality
        let base = "Original prefers source quality and may prepare a compatibility file if this device needs one. "
            + (batches ? "Bitrate presets" : "For single items, bitrate presets")
            + " are prepared on the server when the original is larger"
        let showsResolution = manager.capability?.qualityOptions.contains { ($0.maxHeight ?? 0) > 0 } ?? false
        let monitors = manager.canChooseMonitorQuality
        let scope = batches
            ? (monitors
                ? " This is the default for every download and monitor; the Download sheet can change it."
                : " This is the default for every download; the Download sheet can change it. Monitored series download in original quality.")
            : " Series and season downloads use original quality."
        return base + (showsResolution ? ", at up to the resolution shown." : ".") + scope
    }

    private var heldProgressFooter: String {
        let count = manager.heldProgressCount
        let subject = count == 1 ? "1 offline watch position" : "\(count) offline watch positions"
        return "\(subject) may not have reached the server. Silo won't send them again. Playing the download again replaces them."
    }

    /// The server on this device the group belongs to, if any.
    private func server(for group: DownloadStorageReclaim.OtherStorage) -> ServerEntry? {
        ServerRegistry.shared.entry(with: group.folderName)
    }

    private func title(for group: DownloadStorageReclaim.OtherStorage) -> String {
        server(for: group)?.displayName ?? group.serverURL ?? "Unrecognized data"
    }

    private func detail(for group: DownloadStorageReclaim.OtherStorage) -> String {
        if group.isActiveServer { return "Other profiles on this server" }
        if server(for: group) != nil { return "Another server you've added" }
        return group.serverURL == nil ? "Not used by this version of Silo" : "A server no longer on this device"
    }

    /// Spells out when the data belongs to a profile or server the user can
    /// still switch to: its downloads go, and may download again later.
    private func removalMessage(for group: DownloadStorageReclaim.OtherStorage) -> String {
        if group.isActiveServer {
            return "Downloads saved for other profiles on this server will be deleted from this device. "
                + "Switching to one of those profiles may download its items again."
        }
        if server(for: group) != nil {
            return "Downloads saved for this server will be deleted from this device. "
                + "Switching to this server may download its items again."
        }
        return "No server on this device uses this data."
    }

    var body: some View {
        Form {
            Section {
                Toggle("Download over Wi-Fi only", isOn: $settings.wifiOnly)
                    .tint(.siloSwitchOn)
                Picker("Simultaneous Downloads", selection: $settings.simultaneousDownloads) {
                    ForEach(DownloadSettings.simultaneousDownloadChoices, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .onChange(of: settings.simultaneousDownloads) {
                    manager.applyTransferLimit()
                }
                if formats.count > 1 {
                    Picker("Quality", selection: $settings.preferredFormat) {
                        ForEach(formats, id: \.self) { format in
                            Text(manager.capability?.label(for: format) ?? format.displayName).tag(format.rawValue)
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
                    Text(qualityFooter)
                }
            }
            .listRowBackground(Color.siloGroupedCell)

            Section("Monitoring Defaults") {
                Toggle("Delete after watching", isOn: $settings.defaultDeleteWatched)
                    .tint(.siloSwitchOn)
                Stepper(
                    settings.defaultMaxStorageGB == 0
                        ? "Storage limit: Unlimited"
                        : "Storage limit: \(settings.defaultMaxStorageGB) GB",
                    value: $settings.defaultMaxStorageGB,
                    in: 0...1000,
                    step: 5
                )
            }
            .listRowBackground(Color.siloGroupedCell)

            Section {
                Toggle("Keep watched downloads", isOn: $settings.keepWatchedDownloads)
                    .tint(.siloSwitchOn)
            } header: {
                Text("Cleanup")
            } footer: {
                #if os(macOS)
                Text("When off, the Downloads page suggests freeing up space by removing items you've finished watching.")
                #else
                Text("When off, the Downloads tab suggests freeing up space by removing items you've finished watching.")
                #endif
            }
            .listRowBackground(Color.siloGroupedCell)

            Section("Storage") {
                HStack {
                    Text("Used")
                    Spacer()
                    Text(DownloadFormatting.bytes(manager.totalBytesUsed))
                        .foregroundColor(.siloSecondaryText)
                }
                if manager.hasRecords {
                    Button(role: .destructive) {
                        showDeleteAllConfirm = true
                    } label: {
                        Text("Remove All Downloads")
                    }
                }
            }
            .listRowBackground(Color.siloGroupedCell)

            if !manager.otherDownloadStorage.isEmpty {
                Section {
                    ForEach(manager.otherDownloadStorage) { group in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title(for: group))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(detail(for: group))
                                    .font(.caption)
                                    .foregroundColor(.siloSecondaryText)
                            }
                            Spacer()
                            Text(DownloadFormatting.bytes(group.bytes))
                                .foregroundColor(.siloSecondaryText)
                            Button("Remove", role: .destructive) {
                                pendingOtherRemoval = group
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text("Other Download Data")
                } footer: {
                    Text("Saved for other servers, other profiles, or by other versions of Silo. It doesn't appear in Downloads for this profile.")
                }
                .listRowBackground(Color.siloGroupedCell)
            }

            if manager.heldProgressCount > 0 {
                Section {
                    Button("Discard held change", role: .destructive) {
                        manager.discardHeldProgress()
                    }
                } header: {
                    Text("Offline Progress")
                } footer: {
                    Text(heldProgressFooter)
                }
                .listRowBackground(Color.siloGroupedCell)
            }
        }
        .navigationTitle("Downloads")
        .task {
            await manager.refreshOtherDownloadStorage()
            // The quality picker is hidden when the cached capability only
            // offers one preset; re-fetch so permission changes show up here
            // without waiting for the next app foreground.
            await manager.refreshCapability()
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .settingsListChrome()
        .siloToolbarColorSchemeDark()
        // Centered alert: a confirmation dialog anchors to the whole form
        // and appears at the top of the page.
        .alert(
            "Remove all downloaded files?",
            isPresented: $showDeleteAllConfirm
        ) {
            Button("Remove All", role: .destructive) {
                manager.deleteDownloads(ids: manager.records.map(\.id))
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            pendingOtherRemoval.map { "Remove download data for \(title(for: $0))?" } ?? "",
            isPresented: Binding(
                get: { pendingOtherRemoval != nil },
                set: { if !$0 { pendingOtherRemoval = nil } }
            ),
            presenting: pendingOtherRemoval
        ) { group in
            Button("Remove", role: .destructive) {
                Task { await manager.removeOtherDownloadStorage(group) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { group in
            Text(removalMessage(for: group))
        }
    }
}
#endif
