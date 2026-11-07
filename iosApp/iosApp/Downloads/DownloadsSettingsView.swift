#if !os(tvOS)
import SwiftUI
#if os(iOS)
import UniformTypeIdentifiers
#endif

/// Download preferences: Wi-Fi-only, requested quality, series-monitoring
/// retention defaults, and storage usage. Backed by the `DownloadSettings`
/// singleton (local `UserDefaults`, same pattern as `PlayerSettings`).
struct DownloadsSettingsView: View {
    @Bindable private var settings = DownloadSettings.shared
    private var manager: DownloadManager { DownloadManager.shared }
    @State private var showDeleteAllConfirm = false
    @State private var pendingOtherRemoval: DownloadStorageReclaim.OtherStorage?
    #if os(iOS)
    private var storage: ExternalDownloadStorage { ExternalDownloadStorage.shared }
    @State private var showFolderPicker = false
    @State private var locationError: String?
    @State private var moveOffer: MoveOffer?

    /// Asks whether finished downloads follow a new download location.
    struct MoveOffer: Identifiable {
        let id = UUID()
        let destination: String
        let count: Int
        let bytes: Int64
    }
    #endif

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
        if group.isActiveServer { return "Other profiles and accounts on this server" }
        if server(for: group) != nil { return "Another server you've added" }
        return group.serverURL == nil ? "Not used by this version of Silo" : "A server no longer on this device"
    }

    /// Spells out when the data belongs to a profile or server the user can
    /// still switch to: its downloads go, and may download again later.
    private func removalMessage(for group: DownloadStorageReclaim.OtherStorage) -> String {
        if group.isActiveServer {
            return "Downloads saved for other profiles and accounts on this server will be deleted from this device. "
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

            #if os(iOS)
            storageLocationSection
            #endif

            Section("Storage") {
                HStack {
                    Text("Used")
                    Spacer()
                    Text(DownloadFormatting.bytes(manager.totalBytesUsed))
                        .foregroundColor(.siloSecondaryText)
                }
                if manager.externalBytesUsed > 0 {
                    HStack {
                        Text("On External Drives")
                        Spacer()
                        Text(DownloadFormatting.bytes(manager.externalBytesUsed))
                            .foregroundColor(.siloSecondaryText)
                    }
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
            #if os(iOS)
            manager.requestMediaTransfers()
            #endif
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
        #if os(iOS)
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            chooseFolder(result)
        }
        .alert(
            "Couldn't use that folder",
            isPresented: Binding(get: { locationError != nil }, set: { if !$0 { locationError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(locationError ?? "")
        }
        .alert(
            moveOffer.map { "Move downloads to \u{201C}\($0.destination)\u{201D}?" } ?? "",
            isPresented: Binding(get: { moveOffer != nil }, set: { if !$0 { moveOffer = nil } }),
            presenting: moveOffer
        ) { _ in
            Button("Move Downloads") {
                manager.applyDownloadLocation(moveExisting: true)
            }
            Button("Only New Downloads", role: .cancel) {
                manager.applyDownloadLocation(moveExisting: false)
            }
        } message: { offer in
            Text(moveOfferMessage(offer))
        }
        #endif
    }

    #if os(iOS)
    // MARK: - Download location

    private var currentVolume: DownloadMediaVolume { storage.newDownloadVolume }

    private var storageLocationSection: some View {
        Section {
            HStack {
                Text("Save Downloads To")
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(storage.displayName(for: currentVolume))
                        .foregroundColor(.siloSecondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !storage.isAvailable(currentVolume) {
                        Text("Not connected")
                            .font(.caption)
                            .foregroundColor(.siloSecondaryText)
                    }
                }
            }
            Button(storage.currentLocationId == nil ? "Choose External Drive\u{2026}" : "Choose Another Folder\u{2026}") {
                showFolderPicker = true
            }
            if storage.currentLocationId != nil {
                Button("Save to \(ExternalDownloadStorage.deviceName)") {
                    storage.useDeviceStorage()
                    offerMove()
                }
            }
            if let status = transferStatus {
                HStack(spacing: 8) {
                    if manager.movingMediaRecordId != nil { ProgressView() }
                    Text(status)
                        .font(.subheadline)
                        .foregroundColor(.siloSecondaryText)
                }
            }
            if let failure = manager.mediaTransferFailure {
                Text(failure)
                    .font(.subheadline)
                    .foregroundColor(.siloSecondaryText)
            }
        } header: {
            Text("Download Location")
        } footer: {
            Text(locationFooter)
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    private var transferStatus: String? {
        let count = manager.pendingMediaTransferCount
        guard count > 0 else { return nil }
        let subject = count == 1 ? "1 download" : "\(count) downloads"
        if manager.movingMediaRecordId != nil { return "Moving \(subject)\u{2026}" }
        return "\(subject) waiting to move. Connect the drive to finish."
    }

    private var locationFooter: String {
        let device = ExternalDownloadStorage.deviceNoun
        var footer = "Downloads finish on this \(device), then move to the drive while it's connected. "
            + "Artwork and download details stay on this \(device)."
        if case .external(let id) = currentVolume, storage.smallFileLimitIds.contains(id) {
            footer += " This drive can't hold files over 4 GB. Reformat it as exFAT or APFS to save larger downloads."
        }
        return footer
    }

    private func chooseFolder(_ result: Result<URL, Error>) {
        switch result {
        case .success(let folder):
            Task {
                do {
                    try await storage.choose(folder: folder)
                    offerMove()
                } catch {
                    locationError = error.localizedDescription
                }
            }
        case .failure(let error):
            locationError = error.localizedDescription
        }
    }

    /// Offers to move finished downloads saved elsewhere; with none, just
    /// points the waiting ones at the new location.
    private func offerMove() {
        let outside = manager.mediaOutside(currentVolume)
        guard outside.count > 0 else {
            manager.applyDownloadLocation(moveExisting: false)
            return
        }
        moveOffer = MoveOffer(destination: storage.displayName(for: currentVolume),
                              count: outside.count, bytes: outside.bytes)
    }

    private func moveOfferMessage(_ offer: MoveOffer) -> String {
        let subject = offer.count == 1 ? "1 download" : "\(offer.count) downloads"
        return "\(subject) (\(DownloadFormatting.bytes(offer.bytes))) for this profile are saved somewhere else. "
            + "New downloads go to \u{201C}\(offer.destination)\u{201D} either way. "
            + "Other profiles' downloads stay where they are."
    }
    #endif
}
#endif
