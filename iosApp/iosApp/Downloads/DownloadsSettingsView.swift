#if !os(tvOS)
import SwiftUI

/// Download preferences: Wi-Fi-only, requested quality, series-monitoring
/// retention defaults, and storage usage. Backed by the `DownloadSettings`
/// singleton (local `UserDefaults`, same pattern as `PlayerSettings`).
struct DownloadsSettingsView: View {
    @Bindable private var settings = DownloadSettings.shared
    @Environment(\.locale) private var locale
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
        let showsResolution = manager.capability?.qualityOptions.contains { ($0.maxHeight ?? 0) > 0 } ?? false
        let monitors = manager.canChooseMonitorQuality
        let presets: LocalizedStringResource = switch (batches, showsResolution) {
        case (true, true): .downloadsSettingsQualityPresetsResolution
        case (true, false): .downloadsSettingsQualityPresets
        case (false, true): .downloadsSettingsQualitySinglePresetsResolution
        case (false, false): .downloadsSettingsQualitySinglePresets
        }
        let scope: LocalizedStringResource = batches
            ? (monitors ? .downloadsSettingsQualityScopeMonitors : .downloadsSettingsQualityScopeDownloads)
            : .downloadsSettingsQualityScopeOriginalOnly
        return [LocalizedStringResource.downloadsSettingsQualityOriginal, presets, scope]
            .map { AppLanguage.string($0, locale: locale) }
            .joined(separator: " ")
    }

    /// The server on this device the group belongs to, if any.
    private func server(for group: DownloadStorageReclaim.OtherStorage) -> ServerEntry? {
        ServerRegistry.shared.entry(with: group.folderName)
    }

    private func title(for group: DownloadStorageReclaim.OtherStorage) -> String {
        server(for: group)?.displayName ?? group.serverURL
            ?? AppLanguage.string(.downloadsSettingsUnrecognizedData, locale: locale)
    }

    private func detail(for group: DownloadStorageReclaim.OtherStorage) -> LocalizedStringResource {
        if group.isActiveServer { return .downloadsSettingsOtherProfiles }
        if server(for: group) != nil { return .downloadsSettingsOtherServer }
        return group.serverURL == nil ? .downloadsSettingsOldVersion : .downloadsSettingsRemovedServer
    }

    /// Spells out when the data belongs to a profile or server the user can
    /// still switch to: its downloads go, and may download again later.
    private func removalMessage(for group: DownloadStorageReclaim.OtherStorage) -> LocalizedStringResource {
        if group.isActiveServer { return .downloadsSettingsRemoveOtherProfilesMessage }
        if server(for: group) != nil { return .downloadsSettingsRemoveOtherServerMessage }
        return .downloadsSettingsRemoveUnusedMessage
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.wifiOnly) { Text(.downloadsSettingsWifiOnly) }
                    .tint(.siloSwitchOn)
                Picker(selection: $settings.simultaneousDownloads) {
                    ForEach(DownloadSettings.simultaneousDownloadChoices, id: \.self) { count in
                        Text(verbatim: LocaleFormat.integer(count)).tag(count)
                    }
                } label: {
                    Text(.downloadsSettingsSimultaneous)
                }
                .onChange(of: settings.simultaneousDownloads) {
                    manager.applyTransferLimit()
                }
                if formats.count > 1 {
                    Picker(selection: $settings.preferredFormat) {
                        ForEach(formats, id: \.self) { format in
                            Text(manager.capability?.label(for: format) ?? format.displayName).tag(format.rawValue)
                        }
                    } label: {
                        Text(.downloadsSettingsQuality)
                    }
                }
            } header: {
                Text(.downloadsSettingsTitle)
            } footer: {
                // Quality-behavior copy only makes sense alongside the
                // quality picker, which is hidden when the server offers a
                // single preset.
                if formats.count > 1 {
                    Text(qualityFooter)
                }
            }
            .listRowBackground(Color.siloGroupedCell)

            Section {
                Toggle(isOn: $settings.defaultDeleteWatched) { Text(.downloadsSettingsDeleteWatched) }
                    .tint(.siloSwitchOn)
                Stepper(
                    value: $settings.defaultMaxStorageGB,
                    in: 0...1000,
                    step: 5
                ) {
                    if settings.defaultMaxStorageGB == 0 {
                        Text(.downloadsSettingsStorageLimitUnlimited)
                    } else {
                        Text(.downloadsSettingsStorageLimitGb(LocaleFormat.integer(settings.defaultMaxStorageGB)))
                    }
                }
            } header: {
                Text(.downloadsSettingsMonitoringDefaults)
            }
            .listRowBackground(Color.siloGroupedCell)

            Section {
                Toggle(isOn: $settings.keepWatchedDownloads) { Text(.downloadsSettingsKeepWatched) }
                    .tint(.siloSwitchOn)
            } header: {
                Text(.downloadsSettingsCleanup)
            } footer: {
                #if os(macOS)
                Text(.downloadsSettingsCleanupFooterMac)
                #else
                Text(.downloadsSettingsCleanupFooter)
                #endif
            }
            .listRowBackground(Color.siloGroupedCell)

            Section {
                HStack {
                    Text(.downloadsSettingsUsed)
                    Spacer()
                    Text(DownloadFormatting.bytes(manager.totalBytesUsed))
                        .foregroundColor(.siloSecondaryText)
                }
                if manager.hasRecords {
                    Button(role: .destructive) {
                        showDeleteAllConfirm = true
                    } label: {
                        Text(.downloadsSettingsRemoveAll)
                    }
                }
            } header: {
                Text(.downloadsSettingsStorage)
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
                            Button(role: .destructive) {
                                pendingOtherRemoval = group
                            } label: {
                                Text(.downloadsSettingsRemove)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text(.downloadsSettingsOtherData)
                } footer: {
                    Text(.downloadsSettingsOtherDataFooter)
                }
                .listRowBackground(Color.siloGroupedCell)
            }

            if manager.heldProgressCount > 0 {
                Section {
                    Button(role: .destructive) {
                        manager.discardHeldProgress()
                    } label: {
                        Text(.downloadsSettingsDiscardHeld)
                    }
                } header: {
                    Text(.downloadsSettingsOfflineProgress)
                } footer: {
                    Text(.downloadsSettingsHeldProgressFooter(count: manager.heldProgressCount, LocaleFormat.integer(manager.heldProgressCount)))
                }
                .listRowBackground(Color.siloGroupedCell)
            }
        }
        .navigationTitle(Text(.downloadsSettingsTitle))
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
            Text(.downloadsSettingsRemoveAllTitle),
            isPresented: $showDeleteAllConfirm
        ) {
            Button(role: .destructive) {
                manager.deleteDownloads(ids: manager.records.map(\.id))
            } label: {
                Text(.downloadsSettingsRemoveAllConfirm)
            }
            Button(role: .cancel) {} label: { Text(.commonCancel) }
        }
        .alert(
            pendingOtherRemoval.map { Text(.downloadsSettingsRemoveOtherTitle(title(for: $0))) } ?? Text(verbatim: ""),
            isPresented: Binding(
                get: { pendingOtherRemoval != nil },
                set: { if !$0 { pendingOtherRemoval = nil } }
            ),
            presenting: pendingOtherRemoval
        ) { group in
            Button(role: .destructive) {
                Task { await manager.removeOtherDownloadStorage(group) }
            } label: {
                Text(.downloadsSettingsRemove)
            }
            Button(role: .cancel) {} label: { Text(.commonCancel) }
        } message: { group in
            Text(removalMessage(for: group))
        }
    }
}
#endif
