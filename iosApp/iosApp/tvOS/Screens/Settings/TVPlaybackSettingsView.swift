#if os(tvOS)
import SwiftUI

/// Playback pane of tvOS Settings, rendered inline in the right pane of
/// the two-pane `TVSettingsView`. The root view owns modal picker
/// presentation so only one focus graph is active at a time.
struct TVPlaybackSettingsPane: View {
    @Bindable var viewModel: SettingsViewModel
    let detailFocus: FocusState<TVSettingsDetailFocus?>.Binding
    let presentPicker: (TVSettingsPickerRequest) -> Void
    /// The app language, so a switch re-renders the labels.
    @Environment(\.locale) private var locale
    @State private var seekIntervals = SeekIntervalPreferences.shared
    @State private var spoilers = EpisodeSpoilerPreferences.shared
    @State private var showUseProfileSettingsConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            qualitySection
            if viewModel.showsConnectionGroup {
                connectionSection
            }
            streamingSection
            episodesSection
            // Hidden entirely on servers that do not serve the two keys.
            if spoilers.showsSettings {
                spoilersSection
            }
            if viewModel.hasHeldPlaybackChanges {
                TVHeldSettingChangesRows(
                    retry: { await viewModel.retryHeldPlaybackChanges() },
                    discard: { await viewModel.discardHeldPlaybackChanges() },
                    message: viewModel.heldPlaybackChangesMessage
                )
            }
            if viewModel.playbackChangeWasRejected {
                rejectedChangeRows
            }
            skipIntervalSection(media: .video)
            skipIntervalSection(media: .audiobook)
            resetSection
        }
        .task { await seekIntervals.refresh() }
        .task { await spoilers.refresh() }
        // Reloads on another network, whose speed and limit differ.
        .task(id: BandwidthProbeScheduler.shared.connectionRevision) { await viewModel.loadPlaybackConnection() }
        .alert(
            Text(SettingsViewModel.useProfileSettingsTitle),
            isPresented: $showUseProfileSettingsConfirmation
        ) {
            Button(.settingsProfileSettingsUseAll, role: .destructive) {
                Task { await viewModel.resetPlaybackDeviceSettings() }
            }
            Button(.commonCancel, role: .cancel) {}
        } message: {
            Text(verbatim: viewModel.useProfileSettingsMessage)
        }
    }

    // MARK: - Sections

    /// Resolution and bitrate are two pickers: someone may want only 1080p on
    /// a fast connection, and a 1080p file can carry a higher bitrate than a
    /// 4K one. Each writes and clears only its own setting, as on the web.
    @ViewBuilder
    private var qualitySection: some View {
        TVSettingsSectionHeader(.settingsPlaybackTvHeaderQuality)

        TVSettingsPickerRow(
            title: .settingsControlResolution,
            value: .verbatim(viewModel.qualityResolutionLabel)
        ) { showPicker(.resolution) }
        .focused(detailFocus, equals: .top)

        TVSettingsPickerRow(
            title: .settingsControlBitrate,
            value: viewModel.maxBitrateLabel
        ) { showPicker(.maxBitrate) }
        .focused(detailFocus, equals: .playbackMaxBitrate)

        if viewModel.showsBufferingQualityMode {
            TVSettingsPickerRow(
                title: SettingsViewModel.bufferingQualityTitle,
                value: .verbatim(viewModel.bufferingQualityMode.label)
            ) { showPicker(.bufferingQualityMode) }
            .focused(detailFocus, equals: .playbackBufferingQualityMode)
        }

        if let limit = viewModel.learnedConnectionLimitText {
            Button {
                Task { await resetLearnedLimit() }
            } label: {
                HStack(spacing: 16) {
                    Text(verbatim: limit)
                        .font(.system(size: 26))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 16)
                    Text(.settingsLearnedLimitReset)
                        .font(.system(size: 24, weight: .semibold))
                }
            }
            .buttonStyle(TVSettingsPaneRowStyle())
            .focused(detailFocus, equals: .playbackLearnedLimitReset)
        }

        TVSettingsFooter(.verbatim(
            viewModel.showsBufferingQualityMode
                ? "\(viewModel.qualityFooterText) \(AppLanguage.string(SettingsViewModel.bufferingQualityDescription, locale: locale))"
                : viewModel.qualityFooterText
        ))
        if let error = viewModel.learnedLimitResetError {
            TVSettingsWarningFooter(error)
        }
    }

    /// Resets the limit. The row then disappears, so focus moves up to the
    /// row above instead of being left on nothing.
    private func resetLearnedLimit() async {
        await viewModel.resetLearnedConnectionLimit()
        if viewModel.learnedConnectionLimit == nil,
           detailFocus.wrappedValue == .playbackLearnedLimitReset {
            detailFocus.wrappedValue = viewModel.showsBufferingQualityMode
                ? .playbackBufferingQualityMode
                : .playbackMaxBitrate
        }
    }

    /// The speed the bandwidth probe measured on this connection, a test on
    /// demand, and what Auto plays as-is at that speed. Apple TV is never on
    /// cellular, so the row always offers the test unless the network is
    /// metered.
    @ViewBuilder
    private var connectionSection: some View {
        TVSettingsSectionHeader(.settingsPlaybackTvHeaderConnection)

        Button {
            Task { await viewModel.testConnectionSpeed() }
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(SettingsViewModel.connectionSpeedTitle)
                        .font(.system(size: 26))
                    // "measured 3 minutes ago" moves on while the page is open.
                    TimelineView(.everyMinute) { context in
                        Text(verbatim: viewModel.connectionSpeedLine(at: context.date))
                            .font(.system(size: 22))
                            .opacity(0.7)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                Spacer(minLength: 16)
                if viewModel.connectionSpeedSkippedText == nil {
                    Text(viewModel.isTestingConnectionSpeed
                         ? SettingsViewModel.testingSpeedLabel
                         : SettingsViewModel.testSpeedAction)
                        .font(.system(size: 24, weight: .semibold))
                }
            }
        }
        .buttonStyle(TVSettingsPaneRowStyle())
        .disabled(viewModel.connectionSpeedSkippedText != nil)
        .focused(detailFocus, equals: .playbackConnectionSpeedTest)

        if let budget = viewModel.autoBudgetText {
            TVSettingsFooter(.verbatim(budget))
        }
        if let message = viewModel.connectionSpeedMessage {
            TVSettingsWarningFooter(message)
        }
    }

    @ViewBuilder
    private var streamingSection: some View {
        TVSettingsSectionHeader(.settingsPlaybackTvHeaderStreaming)

        TVSettingsPickerRow(
            title: .settingsControlAudioLanguage,
            value: TVSettingsOptions.label(
                for: viewModel.preferredAudioLanguage,
                in: TVSettingsOptions.audioLanguage(viewModel.audioLanguageOptions, language: AppLanguage.language(of: locale))
            )
        ) { showPicker(.audioLanguage) }
        .focused(detailFocus, equals: .playbackAudioLanguage)

        TVSettingsToggleRow(
            title: .settingsManifestPlayerHdrEnabledLabel,
            isOn: viewModel.hdrEnabled
        ) {
            let value = !viewModel.hdrEnabled
            viewModel.hdrEnabled = value
        }

        TVSettingsToggleRow(
            title: .settingsManifestPlayerDolbyVisionEnabledLabel,
            isOn: viewModel.dolbyVisionEnabled
        ) {
            let value = !viewModel.dolbyVisionEnabled
            viewModel.dolbyVisionEnabled = value
        }
        // Skipped by focus while HDR is off, like the skip-interval rows
        // below when the server cannot store them.
        .disabled(!viewModel.hdrEnabled)

        TVSettingsToggleRow(
            title: .settingsPlaybackSeekCache,
            isOn: viewModel.seekCacheEnabled
        ) {
            let value = !viewModel.seekCacheEnabled
            viewModel.seekCacheEnabled = value
        }

        TVSettingsPickerRow(
            title: .settingsPlaybackBufferAhead,
            value: .verbatim(viewModel.bufferAhead.label)
        ) { showPicker(.bufferAhead) }
        .focused(detailFocus, equals: .playbackBufferAhead)

        TVSettingsToggleRow(
            title: .settingsPlaybackLosslessAudio,
            isOn: viewModel.losslessAudioEnabled
        ) {
            let value = !viewModel.losslessAudioEnabled
            viewModel.losslessAudioEnabled = value
        }

        if AetherObjectAudioPolicy.isAvailable {
            TVSettingsToggleRow(
                title: .settingsPlaybackTrueHdAtmos,
                isOn: viewModel.trueHDAtmosEnabled
            ) {
                let value = !viewModel.trueHDAtmosEnabled
                viewModel.trueHDAtmosEnabled = value
            }
        }

        TVSettingsPickerRow(
            title: .settingsPlaybackDeinterlacing,
            value: .verbatim(viewModel.deinterlaceMode.label)
        ) { showPicker(.deinterlaceMode) }
        .focused(detailFocus, equals: .playbackDeinterlaceMode)

        TVSettingsPickerRow(
            title: .settingsPlaybackDeinterlacingFieldRate,
            value: .verbatim(viewModel.deinterlaceFieldRate.label)
        ) { showPicker(.deinterlaceFieldRate) }
        .focused(detailFocus, equals: .playbackDeinterlaceFieldRate)

        TVSettingsFooter(.verbatim(streamingFooterText))
    }

    private var streamingFooterText: String {
        var text = SettingsViewModel.hdrFooterText
        text += " " + AppLanguage.string(.settingsPlaybackSurroundFooter, locale: locale)
        if AetherObjectAudioPolicy.isAvailable {
            text += " " + AppLanguage.string(.settingsPlaybackAtmosFooter, locale: locale)
            text += " " + AppLanguage.string(.settingsPlaybackAtmosReceiverFooter, locale: locale)
        }
        return text
    }

    @ViewBuilder
    private var episodesSection: some View {
        TVSettingsSectionHeader(.settingsPlaybackTvHeaderEpisodes)

        // A picker rather than a one-press toggle: a toggle has no third
        // position for going back to the profile's choice.
        TVSettingsPickerRow(
            title: .settingsControlAutoplay,
            value: viewModel.autoPlayNext ? .settingsOn : .settingsOff
        ) { showPicker(.autoPlayNext) }
        .focused(detailFocus, equals: .playbackAutoPlayNext)

        TVSettingsPickerRow(
            title: .settingsManifestPlayerPassoutThresholdLabel,
            value: SettingsViewModel.stillWatchingLabel(viewModel.stillWatchingThreshold)
        ) { showPicker(.stillWatching) }
        .focused(detailFocus, equals: .playbackStillWatching)

        TVSettingsPickerRow(
            title: .settingsNextUpTitle,
            value: TVSettingsOptions.label(for: String(viewModel.nextUpPromptSeconds), in: TVSettingsOptions.nextUpPrompt)
        ) { showPicker(.nextUpPrompt) }
        .focused(detailFocus, equals: .playbackNextUpPrompt)

        TVSettingsPickerRow(
            title: .settingsControlIntros,
            value: .verbatim(viewModel.introSkipMode.label)
        ) { showPicker(.introSkipMode) }
        .focused(detailFocus, equals: .playbackIntroSkipMode)

        TVSettingsPickerRow(
            title: .settingsControlCredits,
            value: viewModel.skipCredits ? .settingsOn : .settingsOff
        ) { showPicker(.skipCredits) }
        .focused(detailFocus, equals: .playbackSkipCredits)
    }

    /// Profile-wide spoiler switches. The row has no description slot, so the
    /// footer carries both descriptions and the scope note.
    @ViewBuilder
    private var spoilersSection: some View {
        TVSettingsSectionHeader(.settingsPlaybackTvHeaderSpoilers)

        ForEach(EpisodeSpoilerSetting.allCases, id: \.self) { setting in
            TVSettingsToggleRow(
                title: setting == .images
                    ? .settingsManifestCatalogHideUnwatchedEpisodeImagesLabel
                    : .settingsManifestCatalogHideUnwatchedEpisodeOverviewsLabel,
                isOn: spoilers.settings[setting]
            ) {
                spoilers.set(setting, to: !spoilers.settings[setting])
            }
            .disabled(!spoilers.allowsEditing)
        }

        TVSettingsFooter(.verbatim(spoilersFooter))
    }

    private var spoilersFooter: String {
        var lines = [
            LocalizedStringResource.settingsManifestCatalogHideUnwatchedEpisodeImagesDescription,
            .settingsManifestCatalogHideUnwatchedEpisodeOverviewsDescription,
            .settingsSpoilersFooter,
        ].map { AppLanguage.string($0, locale: locale) }
        if let status = spoilers.statusMessage {
            lines.append(status)
        }
        for setting in EpisodeSpoilerSetting.allCases {
            if let error = spoilers.writeErrors[setting.key] {
                lines.append(error)
            }
        }
        return lines.joined(separator: " ")
    }

    /// "Video" and "Audiobooks" groups. The values belong to the profile on
    /// the server; the rows stay visible but unfocusable when this server
    /// cannot store them, and show the interval playback uses instead.
    @ViewBuilder
    private func skipIntervalSection(media: SeekMedia) -> some View {
        TVSettingsSectionHeader(media == .video ? .settingsPlaybackTvHeaderVideo : .settingsPlaybackTvHeaderAudiobooks)

        ForEach(SeekDirection.allCases, id: \.self) { direction in
            TVSettingsPickerRow(
                title: direction == .backward ? .settingsControlSkipBack : .settingsControlSkipForward,
                value: .verbatim(SeekIntervalLabel.choiceLabel(
                    seekIntervals.seconds(direction, for: Self.surface(media))
                ))
            ) { showPicker(.skipInterval(media, direction)) }
            .focused(detailFocus, equals: Self.focus(media, direction))
            .disabled(!seekIntervals.allowsEditing)
        }

        TVSettingsFooter(.verbatim(skipIntervalFooter(media: media)))
    }

    private func skipIntervalFooter(media: SeekMedia) -> String {
        var lines = [
            AppLanguage.string(
                media == .video ? .settingsSkipIntervalsFooterVideoAppleTv : .settingsSkipIntervalsFooterAudiobook,
                locale: locale
            ),
        ]
        if let status = seekIntervals.statusMessage {
            lines.append(status)
        }
        for direction in SeekDirection.allCases {
            if let error = seekIntervals.writeErrors[SeekIntervalContract.key(media, direction)] {
                lines.append(error)
            }
        }
        return lines.joined(separator: " ")
    }

    private static func surface(_ media: SeekMedia) -> SeekIntervalSurface {
        media == .video ? .videoPlayer : .audiobook
    }

    private static func skipIntervalPickerTitle(_ media: SeekMedia, _ direction: SeekDirection) -> LocalizedStringResource {
        switch (media, direction) {
        case (.video, .backward): return .settingsSkipIntervalsPickerVideoBack
        case (.video, .forward): return .settingsSkipIntervalsPickerVideoForward
        case (.audiobook, .backward): return .settingsSkipIntervalsPickerAudiobookBackApple
        case (.audiobook, .forward): return .settingsSkipIntervalsPickerAudiobookForwardApple
        }
    }

    private static func focus(_ media: SeekMedia, _ direction: SeekDirection) -> TVSettingsDetailFocus {
        switch (media, direction) {
        case (.video, .backward): return .playbackVideoSkipBack
        case (.video, .forward): return .playbackVideoSkipForward
        case (.audiobook, .backward): return .playbackAudiobookSkipBack
        case (.audiobook, .forward): return .playbackAudiobookSkipForward
        }
    }

    @ViewBuilder
    private var rejectedChangeRows: some View {
        TVSettingsSectionHeader(.settingsHeldChangeHeaderTv)

        Button {
            Task { await viewModel.acknowledgeRejectedPlaybackChange() }
        } label: {
            HStack(spacing: 16) {
                Text(.settingsPlaybackRejectedOk)
                    .font(.system(size: 26))
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(TVSettingsPaneRowStyle())

        TVSettingsWarningFooter(SettingsViewModel.rejectedPlaybackChangeMessage)
    }

    @ViewBuilder
    private var resetSection: some View {
        TVSettingsSectionHeader(.settingsPlaybackTvHeaderReset)

        Button {
            showUseProfileSettingsConfirmation = true
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 22, weight: .medium))
                Text(.settingsProfileSettingsUseAll)
                    .font(.system(size: 26))
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(TVSettingsPaneRowStyle(isDestructive: true))

        TVSettingsFooter(.settingsProfileSettingsResetFooterAppleTv)
    }

    // MARK: - Pickers

    private func showPicker(_ kind: PickerKind) {
        presentPicker(pickerRequest(for: kind))
    }

    private func pickerRequest(for kind: PickerKind) -> TVSettingsPickerRequest {
        switch kind {
        case .resolution:
            TVSettingsPickerRequest(
                title: .settingsControlResolution,
                options: [TVSettingsOptions.useProfileSetting] + TVSettingsOptions.resolution,
                selection: selection(.resolution),
                returnFocus: .top
            )
        case .maxBitrate:
            TVSettingsPickerRequest(
                title: .settingsControlBitrate,
                // A stored cap no choice covers is listed in its place, so
                // the sheet highlights what is actually stored.
                options: [TVSettingsOptions.useProfileSetting]
                    + TVSettingsOptions.maxBitrate(viewModel.maxBitrateChoicesKbps),
                selection: selection(.maxBitrate),
                returnFocus: .playbackMaxBitrate
            )
        case .bufferingQualityMode:
            TVSettingsPickerRequest(
                title: SettingsViewModel.bufferingQualityTitle,
                options: [TVSettingsOptions.useProfileSetting] + TVSettingsOptions.bufferingQualityMode,
                selection: selection(.bufferingQualityMode),
                returnFocus: .playbackBufferingQualityMode
            )
        case .audioLanguage:
            TVSettingsPickerRequest(
                title: .settingsControlAudioLanguage,
                options: TVSettingsOptions.deviceAudioLanguage(
                    viewModel.audioLanguageOptions,
                    includingNoPreference: viewModel.hasStoredNoAudioLanguagePreference,
                    language: AppLanguage.language(of: locale)
                ),
                selection: selection(.audioLanguage),
                returnFocus: .playbackAudioLanguage
            )
        case .bufferAhead:
            TVSettingsPickerRequest(
                title: .settingsPlaybackBufferAhead,
                options: TVSettingsOptions.bufferAhead,
                selection: Binding(
                    get: { viewModel.bufferAhead.rawValue },
                    set: { value in
                        guard let mode = BufferAheadMode(rawValue: value) else { return }
                        viewModel.bufferAhead = mode
                    }
                ),
                returnFocus: .playbackBufferAhead
            )
        case .deinterlaceMode:
            TVSettingsPickerRequest(
                title: .settingsPlaybackDeinterlacing,
                options: TVSettingsOptions.deinterlaceMode,
                selection: Binding(
                    get: { viewModel.deinterlaceMode.rawValue },
                    set: { value in
                        guard let mode = DeinterlacePreference(rawValue: value) else { return }
                        viewModel.deinterlaceMode = mode
                    }
                ),
                returnFocus: .playbackDeinterlaceMode
            )
        case .deinterlaceFieldRate:
            TVSettingsPickerRequest(
                title: .settingsPlaybackDeinterlacingFieldRate,
                options: TVSettingsOptions.deinterlaceFieldRate,
                selection: Binding(
                    get: { viewModel.deinterlaceFieldRate.rawValue },
                    set: { value in
                        guard let rate = DeinterlaceFieldRatePreference(rawValue: value) else {
                            return
                        }
                        viewModel.deinterlaceFieldRate = rate
                    }
                ),
                returnFocus: .playbackDeinterlaceFieldRate
            )
        case .stillWatching:
            TVSettingsPickerRequest(
                title: .settingsManifestPlayerPassoutThresholdLabel,
                options: SettingsViewModel.stillWatchingChoices.map { TVSettingsOption(id: $0.id, label: $0.label) },
                selection: $viewModel.stillWatchingSelection,
                returnFocus: .playbackStillWatching
            )
        case .nextUpPrompt:
            TVSettingsPickerRequest(
                title: .settingsNextUpTitle,
                options: [TVSettingsOptions.useProfileSetting] + TVSettingsOptions.nextUpPrompt,
                selection: selection(.nextUpPrompt),
                returnFocus: .playbackNextUpPrompt
            )
        case .introSkipMode:
            TVSettingsPickerRequest(
                title: .settingsControlIntros,
                options: [TVSettingsOptions.useProfileSetting] + TVSettingsOptions.introSkipMode,
                selection: selection(.introSkipMode),
                returnFocus: .playbackIntroSkipMode
            )
        case .autoPlayNext:
            TVSettingsPickerRequest(
                title: .settingsControlAutoplay,
                options: [TVSettingsOptions.useProfileSetting] + TVSettingsOptions.onOff,
                selection: selection(.autoPlayNext),
                returnFocus: .playbackAutoPlayNext
            )
        case .skipCredits:
            TVSettingsPickerRequest(
                title: .settingsControlCredits,
                options: [TVSettingsOptions.useProfileSetting] + TVSettingsOptions.onOff,
                selection: selection(.autoSkipCredits),
                returnFocus: .playbackSkipCredits
            )
        case .skipInterval(let media, let direction):
            TVSettingsPickerRequest(
                title: Self.skipIntervalPickerTitle(media, direction),
                options: SeekIntervalContract.choices.map {
                    TVSettingsOption(id: String($0), label: .verbatim(SeekIntervalLabel.choiceLabel($0)))
                },
                selection: Binding(
                    get: { String(seekIntervals.seconds(direction, for: Self.surface(media))) },
                    set: { value in
                        guard let seconds = Int(value) else { return }
                        seekIntervals.setInterval(seconds, media: media, direction: direction)
                    }
                ),
                returnFocus: Self.focus(media, direction)
            )
        }
    }

    private func selection(_ setting: ProfileBackedPlaybackSetting) -> Binding<String> {
        Binding(
            get: { viewModel.playbackSelectionTag(setting) },
            set: { viewModel.selectPlayback($0, for: setting) }
        )
    }

    enum PickerKind {
        case resolution
        case maxBitrate
        case bufferingQualityMode
        case audioLanguage
        case autoPlayNext
        case skipCredits
        case bufferAhead
        case deinterlaceMode
        case deinterlaceFieldRate
        case stillWatching
        case nextUpPrompt
        case introSkipMode
        case skipInterval(SeekMedia, SeekDirection)
    }
}
#endif
