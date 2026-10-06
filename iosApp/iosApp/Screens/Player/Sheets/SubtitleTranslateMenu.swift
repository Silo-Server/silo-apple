//
//  SubtitleTranslateMenu.swift
//  Silo (iOS + tvOS)
//
//  In-player "AI subtitles" menu. One-tap, Ray-style: the user picks a single
//  target language and the menu picks the method automatically — translate an
//  existing text subtitle track when one is available, otherwise transcribe the
//  audio (Whisper), translating the transcript too when the language differs
//  from the spoken audio. No source-picking or transcribe-vs-translate step is
//  shown; the routing is hidden behind the language choice.
//
//  Presented from ``TrackSelectionSheet`` (iOS) / ``TVPlayerInfoHUD`` (tvOS) and
//  gated on the server's AI capabilities via ``hasActionableSource``.
//
//  Drives ``PlayerViewModel/subtitleAI`` (a ``SubtitleAIController``), which runs
//  the job over polling plus live websocket cue streaming and hands the
//  completed track back through the normal sidecar path so it appears in the
//  picker and auto-selects.
//
//  Routing (`route(to:)`):
//    - Translate: prefer an existing text subtitle track in a *different*
//      language than the target. Its combined index is `track.srcId`
//      (== `subtitle_urls[].index`); embedded-text translation is out of scope
//      for v1, so only tracks with a resolvable `srcId` qualify. Bitmap subs
//      (PGS / DVD / DVB / VobSub, detected via `track.codec`) are never a
//      translation source.
//    - Transcribe: when no translatable text source exists, transcribe the
//      default audio track (`-1`). If the target equals the spoken audio
//      language it's a plain transcribe; otherwise transcribe-and-translate.
//
//  Two-platform split: iOS renders a sectioned `List`; tvOS renders a centered
//  floating panel with `onExitCommand` / backdrop-tap dismissal. The routing
//  and language list are shared; only the container and row view differ by
//  platform. Not compiled for macOS, which has no entry point to it.
//

import SwiftUI

#if !os(macOS)
struct SubtitleTranslateMenu: View {
    let viewModel: PlayerViewModel
    let onDismiss: () -> Void

    /// Called when the AI job has started owning the player-surface preparing
    /// flow: dismisses the WHOLE subtitle UI (this menu plus the enclosing HUD /
    /// sheet) down to the player, so the "Preparing subtitles" pause → resume
    /// plays out where the user can see it. Distinct from `onDismiss`, which
    /// only backs out of this menu (returning to the container).
    let onJobStarted: () -> Void

    /// The profile's preferred subtitle language, floated to the top of the
    /// list. Observed so a late hydration (below, in `.task`) refreshes the row.
    @ObservedObject private var profilePrefs = ProfilePrefsStore.shared

    #if os(tvOS)
    /// Panel-level focus for the tvOS language list (rather than per-row
    /// `@FocusState`), so the tall list can scroll-follow focus and recover
    /// it when it falls to `nil`. Mirrors `TVSettingsPickerSheet`.
    @FocusState private var focusedLanguageID: String?
    #endif

    private var controller: SubtitleAIController { viewModel.subtitleAI }
    private var capabilities: AICapabilities { .shared }

    static func isBitmap(_ track: PlayerTrack) -> Bool {
        SubtitleCodecClassifier.isBitmap(track.codec)
    }

    /// Text subtitle tracks with a resolvable combined index — the only ones
    /// that can be AI-translated in v1.
    static func translatableSubtitleTracks(_ viewModel: PlayerViewModel) -> [PlayerTrack] {
        viewModel.subtitleTracks.filter { !isBitmap($0) && $0.srcId != nil }
    }

    /// Whether the menu would show at least one serviceable language, so the
    /// entry row doesn't open a dead menu. True when there's a translatable
    /// text track, or transcription is enabled and there's an audio track to
    /// transcribe (which also covers the bitmap-only "transcribe instead" case).
    static func hasActionableSource(_ viewModel: PlayerViewModel) -> Bool {
        let caps = AICapabilities.shared
        if caps.subtitleEnabled, !translatableSubtitleTracks(viewModel).isEmpty { return true }
        if caps.transcribeEnabled, !viewModel.audioTracks.isEmpty { return true }
        return false
    }

    private var translatableSubtitleTracks: [PlayerTrack] {
        Self.translatableSubtitleTracks(viewModel)
    }

    /// The audio track whose language is treated as the "spoken" language:
    /// the selected one, else the default, else the first.
    private var spokenAudioTrack: PlayerTrack? {
        let tracks = viewModel.audioTracks
        return tracks.first(where: { $0.isSelected })
            ?? tracks.first(where: { $0.isDefault })
            ?? tracks.first
    }

    private var spokenLanguageCode: String? {
        spokenAudioTrack?.normalizedLanguageCode
    }

    var body: some View {
        #if os(tvOS)
        tvOSPanel
        #else
        phoneList
        #endif
    }

    // MARK: - Shared content

    /// True while a job is in flight — the menu collapses to a progress view.
    private var isBusy: Bool { controller.isBusy }

    private var title: String { "AI Subtitles" }

    /// One-line explainer under the title / list — sets the expectation that the
    /// single language tap does everything, without a wizard.
    private var explainer: String {
        "Pick a language. Silo translates an existing subtitle when it can, or transcribes the audio."
    }

    // MARK: - Language routing

    /// The best existing text subtitle to translate into `target`: a track in a
    /// *different* language (or one with an unknown language, which the server
    /// detects). An **English** source is preferred when available — AI
    /// translation is highest-quality from English, and English subs are
    /// usually the most complete track — then the selected / default / first.
    /// Nil when only the target language itself is available, or translation is
    /// disabled.
    private func bestTranslationSource(excluding target: String) -> PlayerTrack? {
        guard capabilities.subtitleEnabled else { return nil }
        let targetKey = SubtitleDisplayOrder.canonicalLanguageKey(target)
        let candidates = translatableSubtitleTracks.filter { track in
            // Keep unknown-language tracks (the server detects the language);
            // exclude any track already in the target language. Compare on the
            // canonical key so "eng"/"en" (and regional variants) collapse, so
            // we never pick a pointless same-language "translation" source.
            guard let key = SubtitleDisplayOrder.canonicalLanguageKey(track.normalizedLanguageCode) else {
                return true
            }
            return key != targetKey
        }
        // English first as the translation base, then selected / default / first.
        return candidates.first(where: { SubtitleDisplayOrder.canonicalLanguageKey($0.normalizedLanguageCode) == "en" })
            ?? candidates.first(where: { $0.isSelected })
            ?? candidates.first(where: { $0.isDefault })
            ?? candidates.first
    }

    /// Whether serving `target` would consume an ASR job (no translatable
    /// source ⇒ transcription).
    private func requiresTranscription(for target: String) -> Bool {
        bestTranslationSource(excluding: target) == nil
    }

    /// Whether the menu can produce subtitles in `target` right now. A
    /// translation path is always serviceable; a transcription path needs ASR
    /// enabled, an audio track, and remaining quota.
    private func canServe(_ target: String) -> Bool {
        if !requiresTranscription(for: target) { return true }
        guard capabilities.transcribeEnabled, !viewModel.audioTracks.isEmpty else { return false }
        return !isQuotaExhausted
    }

    /// Submit the job for `target`, choosing translate-existing vs transcribe
    /// (± translate) automatically. Guarded against re-entry while busy.
    private func route(to target: String) {
        guard !isBusy else { return }
        if let source = bestTranslationSource(excluding: target) {
            viewModel.startSubtitleTranslation(track: source, to: target)
        } else {
            guard capabilities.transcribeEnabled, !viewModel.audioTracks.isEmpty else { return }
            let translateTo: String? =
                spokenLanguageCode?.caseInsensitiveCompare(target) == .orderedSame ? nil : target
            viewModel.startSubtitleTranscription(audioIndex: -1, translateTo: translateTo)
        }
        // The controller enters the player-surface preparing state on submit.
        // Close the whole subtitle UI so the pause/notice handoff plays out
        // over the video on both platforms.
        guard controller.phase != .failed, controller.livePresentationActive else { return }
        onJobStarted()
    }

    /// Languages offered, with the profile's preferred language and the
    /// spoken/original language floated to the top in that order.
    private var languageChoices: SubtitleLanguageChoices {
        SubtitleLanguageChoices(
            preferred: profilePrefs.preferredSubtitleLanguage,
            original: spokenLanguageCode
        )
    }

    /// Show the ASR quota gauge whenever at least one offered target would rely
    /// on transcription. A file can have a translatable subtitle for most targets
    /// while same-language targets still fall back to ASR.
    private var showsQuota: Bool {
        capabilities.transcribeEnabled
            && !viewModel.audioTracks.isEmpty
            && languageChoices.all.contains { requiresTranscription(for: $0.code) }
            && quotaText != nil
    }

    #if os(tvOS)
    /// First row the user can act on, in display order.
    private var firstServiceableLanguageID: String? {
        languageChoices.all.first(where: { canServe($0.code) })?.code
    }

    /// Recover focus when it falls to `nil`.
    private func focusFirstServiceableLanguage() {
        guard !isBusy, controller.phase != .failed else { return }
        focusedLanguageID = firstServiceableLanguageID
    }

    /// Keep the focused row visible as the user navigates the tall list.
    private func scrollToFocusedLanguage(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let target = focusedLanguageID ?? firstServiceableLanguageID else { return }
        SubtitleLanguageChoices.scroll(proxy, to: target, animated: animated)
    }
    #endif

    // MARK: - tvOS

    #if os(tvOS)
    private var tvOSPanel: some View {
        TVSubtitleDialog(
            title: title,
            subtitle: isBusy ? "Preparing your subtitles"
                : controller.phase == .failed ? "AI subtitles could not finish"
                : "Choose a language. Silo translates existing subtitles or transcribes the audio.",
            backHint: "Back to Subtitles",
            onDismiss: onDismiss
        ) {
            if isBusy || controller.phase == .failed {
                progressPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            languageRows
                        }
                        .padding(8)
                    }
                    .focusSection()
                    .defaultFocus($focusedLanguageID, firstServiceableLanguageID ?? "")
                    .onChange(of: focusedLanguageID) { _, value in
                        // Focus fell off the list (scrolled past an edge) —
                        // pull it back to a serviceable row instead of letting
                        // it vanish. Otherwise just keep the focused row visible.
                        if value == nil { focusFirstServiceableLanguage() }
                        else { scrollToFocusedLanguage(proxy) }
                    }
                }
            }
        }
        .onExitCommand { onDismiss() }
        .task { await controller.refreshQuota() }
        .task { await profilePrefs.hydrateIfNeeded() }
        .onChange(of: controller.phase) { _, newPhase in
            // Auto-dismiss once the handoff is done — the completed track is
            // now in the picker and selected. Attached to the always-mounted
            // root so it fires even as the progress panel is torn down.
            if newPhase == .completed { onDismiss() }
        }
    }

    @ViewBuilder
    private var languageRows: some View {
        if showsQuota {
            quotaRow
            if isQuotaExhausted {
                Text(Self.quotaExhaustedFooter)
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }
        }
        let choices = languageChoices
        if !choices.suggested.isEmpty {
            sectionHeader("Suggested languages")
            ForEach(choices.suggested) { tvLanguageRow($0) }
        }
        sectionHeader(choices.suggested.isEmpty ? "Language" : "All Languages")
        ForEach(choices.other) { tvLanguageRow($0) }
    }

    @ViewBuilder
    private func tvLanguageRow(_ choice: SubtitleLanguageChoices.Choice) -> some View {
        TVLanguageRow(
            name: choice.label,
            detail: choice.hint,
            systemImage: choice.hint == "Preferred" ? "star.fill" : "globe",
            code: choice.code,
            isDisabled: !canServe(choice.code),
            focusedID: $focusedLanguageID
        ) {
            route(to: choice.code)
        }
        .id(choice.code)
    }
    #endif

    // MARK: - iOS

    #if !os(tvOS)
    private var phoneList: some View {
        NavigationStack {
            Group {
                if isBusy || controller.phase == .failed {
                    progressPanel
                } else {
                    let choices = languageChoices
                    List {
                        if showsQuota {
                            Section {
                                quotaRow
                            } footer: {
                                if isQuotaExhausted { Text(Self.quotaExhaustedFooter) }
                            }
                        }
                        if !choices.suggested.isEmpty {
                            Section("Suggested") {
                                ForEach(choices.suggested) { languageRow($0) }
                            }
                        }
                        Section {
                            ForEach(choices.other) { languageRow($0) }
                        } header: {
                            Text(choices.suggested.isEmpty ? "Language" : "All Languages")
                        } footer: {
                            Text(explainer)
                        }
                    }
                    .siloGroupedListStyle()
                }
            }
            .navigationTitle(title)
            .siloNavigationTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDismiss() }
                }
            }
            .task { await controller.refreshQuota() }
            .task { await profilePrefs.hydrateIfNeeded() }
            .onChange(of: controller.phase) { _, newPhase in
                // Auto-dismiss once the handoff is done — the completed track
                // is now in the picker and selected.
                if newPhase == .completed { onDismiss() }
            }
        }
    }
    #endif

    // MARK: - iOS row builder

    #if !os(tvOS)
    @ViewBuilder
    private func languageRow(_ choice: SubtitleLanguageChoices.Choice) -> some View {
        MenuRow(
            name: choice.label,
            detail: choice.hint,
            systemImage: choice.hint == "Preferred" ? "star.fill" : "globe",
            isDisabled: !canServe(choice.code)
        ) {
            route(to: choice.code)
        }
    }
    #endif

    // MARK: - Progress / failure panel

    @ViewBuilder
    private var progressPanel: some View {
        let job = controller.activeJob
        VStack(alignment: .leading, spacing: 16) {
            if controller.phase == .failed {
                Label(controller.errorMessage ?? "Subtitle translation failed.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                progressButton(title: "Dismiss") { onDismiss() }
                if controller.hasHeldRequest {
                    // The request may have started a job, so it is not sent
                    // again until the user lets it go.
                    progressButton(title: "Discard held request", focusID: "progress-discard",
                                   seedsFocus: false) {
                        controller.discardHeldRequest()
                    }
                }
            } else {
                Text(progressTitle(for: job))
                    .font(.headline)
                ProgressView(value: clampedProgress(job))
                    .progressViewStyle(.linear)
                if let message = job?.progressMessage, !message.isEmpty {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                progressButton(title: "Cancel") {
                    controller.cancelActiveJob()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func progressTitle(for job: SubtitleJob?) -> String {
        switch job?.kind {
        case .transcribe: return "Transcribing audio…"
        case .transcribeTranslate: return "Transcribing & translating…"
        case .translate, .none: return "Translating subtitles…"
        }
    }

    private func clampedProgress(_ job: SubtitleJob?) -> Double {
        guard let p = job?.progress else { return 0 }
        return min(max(p, 0), 1)
    }

    // MARK: - Quota gauge

    private var isQuotaExhausted: Bool {
        guard let quota = controller.quota, quota.limited else { return false }
        if let remaining = quota.remaining { return remaining <= 0 }
        return false
    }

    private var quotaText: String? {
        guard let quota = controller.quota, quota.limited else { return nil }
        if isQuotaExhausted { return "Transcription limit reached" }
        let used = quota.used ?? 0
        if let limit = quota.limit {
            let period = quota.period.map { " / \($0)" } ?? ""
            return "\(used) of \(limit) used\(period)"
        }
        if let remaining = quota.remaining {
            return "\(remaining) remaining"
        }
        return nil
    }

    /// Footer shown when ASR quota is exhausted and the file relies on it.
    /// Hoisted so the iOS `List` footer and the tvOS inline footer render the
    /// identical copy from one source.
    private static let quotaExhaustedFooter =
        "You've used all your transcription credits for this period. Translating an existing subtitle track still works."
}

// MARK: - Section header (tvOS inline) + quota row

private extension SubtitleTranslateMenu {
    @ViewBuilder
    func sectionHeader(_ text: String) -> some View {
        #if os(tvOS)
        Text(text.uppercased())
            .font(.system(size: 14, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 12)
            .padding(.top, 10)
        #else
        EmptyView()
        #endif
    }

    @ViewBuilder
    var quotaRow: some View {
        if let quotaText {
            #if os(tvOS)
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .foregroundStyle(.white.opacity(0.5))
                Text(quotaText)
                    .font(.system(size: 16))
                    .foregroundStyle(isQuotaExhausted ? Color.siloWarning : .white.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            #else
            HStack {
                Label("Transcription quota", systemImage: "gauge.with.dots.needle.33percent")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(quotaText)
                    .foregroundStyle(isQuotaExhausted ? Color.siloWarning : .secondary)
            }
            .font(.footnote)
            #endif
        }
    }

    @ViewBuilder
    func progressButton(title: String, focusID: String = "progress-action", seedsFocus: Bool = true,
                        action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        Button(title, action: action)
            .buttonStyle(.bordered)
            .focused($focusedLanguageID, equals: focusID)
            .onAppear { if seedsFocus { focusedLanguageID = focusID } }
        #else
        Button(title, action: action)
            .buttonStyle(.bordered)
        #endif
    }
}

// MARK: - Menu rows

#if os(tvOS)
/// AI routing hints within the shared subtitle menu row.
private struct TVLanguageRow: View {
    let name: String
    let detail: String?
    let systemImage: String
    let code: String
    var isDisabled: Bool = false
    @FocusState.Binding var focusedID: String?
    let action: () -> Void

    var body: some View {
        TVSubtitleMenuRow(
            rowID: code,
            isDisabled: isDisabled,
            focusedID: $focusedID,
            action: action
        ) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .regular))
                .opacity(0.8)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(size: 24, weight: .medium))
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 18, weight: .regular))
                        .opacity(0.65)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 18, weight: .semibold))
                .opacity(0.55)
        }
        .accessibilityLabel(name)
        .accessibilityValue(detail ?? "")
    }
}
#else
/// iOS menu row: standard List row with a leading icon and a chevron.
private struct MenuRow: View {
    let name: String
    let detail: String?
    let systemImage: String
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
        .disabled(isDisabled)
    }
}
#endif
#endif
