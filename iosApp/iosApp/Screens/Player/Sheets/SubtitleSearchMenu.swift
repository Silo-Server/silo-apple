//
//  SubtitleSearchMenu.swift
//  Continuum (iOS + tvOS)
//
//  In-player external subtitle search (OpenSubtitles / SubDL / Subsource via
//  silo-server). Android/web parity: pick a language (the profile's preferred
//  subtitle language floats to the top and is pre-selected), Search — no
//  free-text query, the server keys the search on the media file — then tap a
//  result to download it. The downloaded track registers on the live backend
//  and auto-selects with no session restart (the same sidecar handoff the AI
//  flow uses; see `PlayerViewModel.downloadSearchedSubtitle`).
//
//  Presented next to the "AI Subtitles…" entry — from the Audio & Subtitles
//  menu in ``MobilePlayerControls`` (iOS) and the Subtitles pane's options
//  column in ``TVPlayerInfoHUD`` (tvOS).
//  The entry row is shown per ``PlayerViewModel/subtitleSearchVisible`` (needs
//  an active server session — hidden for offline/local playback) and is only
//  actionable per ``PlayerViewModel/subtitleSearchEnabled``, which additionally
//  requires the server to have external providers configured; otherwise the row
//  renders disabled with ``PlayerViewModel/subtitleSearchUnavailableReason``
//  rather than running a search that can only come back empty.
//
//  Two-platform split mirrors ``SubtitleTranslateMenu``: iOS renders a
//  sectioned `List` in a sheet; tvOS renders a centered floating panel with a
//  single panel-level `@FocusState` (scroll-follow + nil-recovery), backdrop
//  tap + `onExitCommand` dismissal.
//

import SwiftUI

struct SubtitleSearchMenu: View {
    let viewModel: PlayerViewModel
    let onDismiss: () -> Void

    /// Called when a download succeeded and the track is registered +
    /// selected: dismisses the WHOLE subtitle UI (this menu plus the enclosing
    /// panel/sheet) down to the player, like the AI menu's `onJobStarted`.
    /// Defaults to `onDismiss` for call sites that don't distinguish the two.
    var onDownloaded: () -> Void = {}

    /// The profile's preferred subtitle language, used to pre-select and
    /// float its row. Observed so a late hydration refreshes the default.
    @ObservedObject private var profilePrefs = ProfilePrefsStore.shared

    private enum Phase: Equatable {
        /// Language list shown, no search yet (or user backed out of results).
        case picking
        /// `POST /subtitles/search` in flight — can take ~30s.
        case searching
        /// Results (possibly empty) for `searchedLanguage`.
        case results
        /// Search or download failed; message shown verbatim.
        case failed(String)
    }

    @State private var phase: Phase = .picking
    /// Selected language code; seeded from the preferred subtitle language.
    @State private var selectedLanguage: String?
    /// The language the current `results` belong to (for the empty-state copy).
    @State private var searchedLanguage: String?
    @State private var results: [SubtitleSearchResult] = []
    @State private var warnings: [String] = []
    /// The result currently downloading; non-nil disables every row.
    @State private var downloadingId: String?
    @State private var searchTask: Task<Void, Never>?

    #if os(tvOS)
    /// Panel-level focus for language rows and result rows (keys never
    /// collide: language codes vs composite `provider:id` result keys).
    /// Centralized so the list can scroll-follow and recover a dropped
    /// focus — mirrors ``SubtitleTranslateMenu``.
    @FocusState private var focusedRowID: String?
    #endif

    var body: some View {
        platformBody
            // The provider probe is async and fails open, so this menu can
            // already be on screen when the server's "no providers configured"
            // answer lands — the entry row's `.disabled(...)` only gates
            // *opening* it. Catch the flip here so an idle language list stops
            // inviting a search that can't work; `search(language:)` guards the
            // action itself for the narrower race where the pick beats this.
            //
            // Keyed on the reason rather than `subtitleSearchEnabled` because
            // the reason is non-nil for exactly the unconfigured-provider case:
            // the *visibility* half of that predicate also drops when the
            // playback session momentarily has no id, and hijacking the menu
            // for that would be a false positive.
            .onChange(of: viewModel.subtitleSearchUnavailableReason) { _, _ in
                reflectUnavailabilityIfIdle()
            }
            // Covers the sliver where the probe lands between the row's tap
            // and this view appearing, which `onChange` would never see.
            .onAppear { reflectUnavailabilityIfIdle() }
    }

    @ViewBuilder
    private var platformBody: some View {
        #if os(tvOS)
        tvOSPanel
        #else
        phoneList
        #endif
    }

    // MARK: - Shared copy

    private var title: String { "Search Subtitles" }

    private var explainer: String {
        "Pick a language and Silo searches its subtitle providers for this video."
    }

    // MARK: - Languages

    /// Languages offered, deduped, preferred language floated to the top.
    private var orderedLanguages: [SubtitleLanguageChoice] {
        var result: [SubtitleLanguageChoice] = []
        var seen = Set<String>()
        func add(_ code: String, hint: String?) {
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            result.append(.init(code: trimmed, label: SubtitleLanguageChoice.displayName(trimmed), hint: hint))
        }
        if let preferred = profilePrefs.preferredSubtitleLanguage {
            add(preferred, hint: "Preferred")
        }
        for option in PlaybackLanguageOption.all {
            add(option.code, hint: nil)
        }
        return result
    }

    private var suggestedLanguages: [SubtitleLanguageChoice] { orderedLanguages.filter { $0.hint != nil } }

    private var otherLanguages: [SubtitleLanguageChoice] {
        orderedLanguages
            .filter { $0.hint == nil }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// Seed the selection from the preferred language once hydrated.
    private func seedSelectedLanguage() {
        guard selectedLanguage == nil else { return }
        selectedLanguage = profilePrefs.preferredSubtitleLanguage ?? orderedLanguages.first?.code
    }

    // MARK: - Actions

    /// Terminal copy for a search the server can't service. Reuses the entry
    /// row's own string so the two surfaces can't drift. The fallback covers
    /// only the case where the *visibility* half of the gate dropped too (the
    /// playback session went away under an open sheet), which nils the reason
    /// while leaving search just as unrunnable.
    private var unavailableMessage: String {
        viewModel.subtitleSearchUnavailableReason ?? "Subtitle search isn't available right now."
    }

    /// Show the unavailable state if the server has since told us it has no
    /// providers. Only rewrites an *idle* language list: an in-flight search
    /// or a result list the user is reading is left alone, since yanking
    /// either away mid-read is more disruptive than the stale state — and
    /// `search(language:)` guards the action, so nothing new can be launched
    /// from them either.
    private func reflectUnavailabilityIfIdle() {
        guard phase == .picking,
              let reason = viewModel.subtitleSearchUnavailableReason else { return }
        searchedLanguage = nil
        phase = .failed(reason)
    }

    /// Selecting a language IS the search trigger (one-tap, like the AI
    /// menu routes on language pick) — no separate Search button.
    private func search(language: String) {
        guard downloadingId == nil, phase != .searching else { return }
        // The entry row's `.disabled(...)` gates opening this menu, not acting
        // inside it: `SubtitleProvidersStore` fails open, so the sheet can be
        // presented before the probe returns `{"enabled": false}`. Without
        // this the pick would still start the provider fan-out and deliver the
        // 20–30s empty search this feature exists to avoid. Route it to the
        // menu's existing terminal failure state instead of silently ignoring
        // the press, which on both platforms would read as a dead row.
        //
        // `searchedLanguage` stays nil deliberately: it is what makes the
        // failure panel offer "Try Again", and retrying is pointless here —
        // only "Back" applies.
        guard viewModel.subtitleSearchEnabled else {
            selectedLanguage = language
            searchedLanguage = nil
            phase = .failed(unavailableMessage)
            return
        }
        selectedLanguage = language
        searchedLanguage = language
        phase = .searching
        searchTask?.cancel()
        searchTask = Task {
            do {
                let response = try await viewModel.searchSubtitles(languages: [language])
                guard !Task.isCancelled else { return }
                results = response.results
                warnings = response.warnings
                phase = .results
            } catch {
                guard !Task.isCancelled else { return }
                // Verbatim server error — "no providers configured" arrives
                // here as plain error text (no capability probe exists).
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func download(_ result: SubtitleSearchResult) {
        guard downloadingId == nil else { return }
        downloadingId = result.uniqueKey
        Task {
            let ok = await viewModel.downloadSearchedSubtitle(result)
            if ok {
                // Track registered + auto-selected on the live player;
                // collapse the whole subtitle UI down to the video.
                onDownloaded()
            } else {
                downloadingId = nil
                phase = .failed("Couldn't add that subtitle. Try another result.")
            }
        }
    }

    /// Back out of results/failure to the language list (keeps the menu up).
    private func backToLanguages() {
        searchTask?.cancel()
        results = []
        warnings = []
        phase = .picking
    }

    // MARK: - Result presentation

    private func scoreColor(_ score: Double) -> Color {
        switch SubtitleSearchScoreTier(score: score) {
        case .good: return .continuumSuccess
        case .fair: return .continuumWarning
        case .poor: return .continuumError
        }
    }

    /// Short provider tag for the row badge (parity with Android/web).
    private func providerBadge(_ provider: String) -> String {
        switch provider.lowercased() {
        case "opensubtitles": return "OS"
        case "subdl": return "SDL"
        case "subsource": return "SS"
        default: return provider.uppercased()
        }
    }

    /// Second row of a result: language • downloads • HI.
    private func resultDetail(_ result: SubtitleSearchResult) -> String {
        var parts: [String] = []
        // Canonical-key check filters junk codes; display goes through the
        // same `displayName` as the picker so the strings stay consistent.
        if SubtitleDisplayOrder.canonicalLanguageKey(result.language) != nil {
            parts.append(SubtitleLanguageChoice.displayName(result.language))
        }
        if result.downloads > 0 {
            parts.append("\(result.downloads) downloads")
        }
        if result.hearingImpaired {
            parts.append("HI")
        }
        return parts.joined(separator: " • ")
    }

    private var emptyResultsText: String {
        let language = searchedLanguage.map(SubtitleLanguageChoice.displayName) ?? "that language"
        return "No subtitles found for \(language)."
    }

    // MARK: - tvOS

    #if os(tvOS)
    /// Rows in display order for focus recovery.
    private var displayLanguages: [SubtitleLanguageChoice] { suggestedLanguages + otherLanguages }

    private func focusFirstRow() {
        switch phase {
        case .picking:
            focusedRowID = selectedLanguage ?? displayLanguages.first?.code
        case .results:
            // Empty result set: land focus on the fallback row so the remote
            // isn't left with nothing focused.
            focusedRowID = results.first?.uniqueKey ?? "back-to-languages"
        case .searching, .failed:
            break
        }
    }

    private func scrollToFocusedRow(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let target = focusedRowID else { return }
        if animated {
            withAnimation(.easeOut(duration: ContinuumTheme.fastDuration)) {
                proxy.scrollTo(target, anchor: .center)
            }
        } else {
            proxy.scrollTo(target, anchor: .center)
        }
    }

    private var tvOSPanel: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title.uppercased())
                        .font(.system(size: 18, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.7))
                    if phase == .picking {
                        Text(explainer)
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 12)

                switch phase {
                case .searching:
                    searchingPanel
                case .failed(let message):
                    failurePanel(message)
                case .picking, .results:
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                if phase == .picking {
                                    tvLanguageRows
                                } else {
                                    tvResultRows
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .focusSection()
                        .onAppear {
                            focusFirstRow()
                            scrollToFocusedRow(proxy, animated: false)
                        }
                        .onChange(of: focusedRowID) { _, value in
                            // Focus fell off the list — pull it back rather
                            // than letting it vanish; else keep it visible.
                            if value == nil { focusFirstRow() }
                            else { scrollToFocusedRow(proxy) }
                        }
                        .onChange(of: phase) { _, _ in focusFirstRow() }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1100, maxHeight: 720)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(Color.black.opacity(0.35))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
        }
        .onExitCommand {
            // First back-press from results returns to the language list;
            // from the language list it dismisses the menu. Back is inert
            // while a download is in flight (mirrors iOS's disabled
            // "Language" button) so the resolving download can't later yank
            // the user off the language list or force-dismiss the menu.
            switch phase {
            case .results, .failed, .searching:
                if downloadingId == nil { backToLanguages() }
            case .picking:
                onDismiss()
            }
        }
        .task { await profilePrefs.hydrateIfNeeded() }
        .onAppear { seedSelectedLanguage() }
        .onChange(of: profilePrefs.preferredSubtitleLanguage) { _, _ in seedSelectedLanguage() }
    }

    @ViewBuilder
    private var tvLanguageRows: some View {
        if !suggestedLanguages.isEmpty {
            sectionHeader("Suggested")
            ForEach(suggestedLanguages) { tvLanguageRow($0) }
        }
        sectionHeader(suggestedLanguages.isEmpty ? "Language" : "All Languages")
        ForEach(otherLanguages) { tvLanguageRow($0) }
    }

    @ViewBuilder
    private func tvLanguageRow(_ choice: SubtitleLanguageChoice) -> some View {
        SubtitleSheetTVRow(
            rowID: choice.code,
            focusedID: $focusedRowID,
            action: { search(language: choice.code) }
        ) {
            Image(systemName: choice.hint == "Preferred" ? "star.fill" : "globe")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(choice.label)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let hint = choice.hint {
                    Text(hint)
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
        }
        .id(choice.code)
    }

    /// Per-provider soft failures, shown above the results in amber.
    @ViewBuilder
    private var warningRows: some View {
        ForEach(warnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(.system(size: 16))
                .foregroundStyle(Color.continuumWarning)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var tvResultRows: some View {
        warningRows
        if results.isEmpty {
            Text(emptyResultsText)
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            SubtitleSheetTVRow(
                rowID: "back-to-languages",
                focusedID: $focusedRowID,
                action: { backToLanguages() }
            ) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 34)
                Text("Choose another language")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
            }
            .id("back-to-languages")
        } else {
            sectionHeader(searchedLanguage.map { SubtitleLanguageChoice.displayName($0) } ?? "Results")
            ForEach(results, id: \.uniqueKey) { result in
                tvResultRow(result)
            }
        }
    }

    @ViewBuilder
    private func tvResultRow(_ result: SubtitleSearchResult) -> some View {
        let isDownloadingThis = downloadingId == result.uniqueKey
        SubtitleSheetTVRow(
            rowID: result.uniqueKey,
            isDisabled: downloadingId != nil && !isDownloadingThis,
            focusedID: $focusedRowID,
            action: { download(result) }
        ) {
            scoreBadge(result.score, fontSize: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(result.releaseName.isEmpty ? "Untitled release" : result.releaseName)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(resultDetail(result))
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isDownloadingThis {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                providerTag(result.provider, fontSize: 15)
            }
        }
        .id(result.uniqueKey)
    }

    @ViewBuilder
    private var searchingPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ProgressView()
                Text("Searching providers…")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
            }
            Text("This can take up to half a minute.")
                .font(.system(size: 17))
                .foregroundStyle(.white.opacity(0.5))
            Button("Cancel") { backToLanguages() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func failurePanel(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 12) {
                if let language = searchedLanguage {
                    Button("Try Again") { search(language: language) }
                        .buttonStyle(.bordered)
                }
                Button("Back") { backToLanguages() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 14, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 12)
            .padding(.top, 10)
    }
    #endif

    // MARK: - iOS

    #if !os(tvOS)
    private var phoneList: some View {
        NavigationStack {
            Group {
                switch phase {
                case .searching:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Searching providers…")
                            .font(.headline)
                        Text("This can take up to half a minute.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Cancel") { backToLanguages() }
                            .buttonStyle(.bordered)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 16) {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            if let language = searchedLanguage {
                                Button("Try Again") { search(language: language) }
                                    .buttonStyle(.bordered)
                            }
                            Button("Back") { backToLanguages() }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                case .picking:
                    languagePickingList
                case .results:
                    resultsList
                }
            }
            .navigationTitle(phase == .results ? "Results" : title)
            .continuumNavigationTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDismiss() }
                }
                if phase == .results {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Language") { backToLanguages() }
                            .disabled(downloadingId != nil)
                    }
                }
            }
            .task { await profilePrefs.hydrateIfNeeded() }
            .onAppear { seedSelectedLanguage() }
            .onChange(of: profilePrefs.preferredSubtitleLanguage) { _, _ in seedSelectedLanguage() }
        }
    }

    private var languagePickingList: some View {
        List {
            if !suggestedLanguages.isEmpty {
                Section("Suggested") {
                    ForEach(suggestedLanguages) { languageRow($0) }
                }
            }
            Section {
                ForEach(otherLanguages) { languageRow($0) }
            } header: {
                Text(suggestedLanguages.isEmpty ? "Language" : "All Languages")
            } footer: {
                Text(explainer)
            }
        }
        .continuumGroupedListStyle()
    }

    @ViewBuilder
    private func languageRow(_ choice: SubtitleLanguageChoice) -> some View {
        Button {
            search(language: choice.code)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: choice.hint == "Preferred" ? "star.fill" : "globe")
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.label)
                        .foregroundStyle(.primary)
                    if let hint = choice.hint {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
    }

    private var resultsList: some View {
        List {
            if !warnings.isEmpty {
                Section {
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(Color.continuumWarning)
                    }
                }
            }
            if results.isEmpty {
                Section {
                    Text(emptyResultsText)
                        .foregroundStyle(.secondary)
                    Button("Choose another language") { backToLanguages() }
                }
            } else {
                Section(searchedLanguage.map { SubtitleLanguageChoice.displayName($0) } ?? "Results") {
                    ForEach(results, id: \.uniqueKey) { result in
                        resultRow(result)
                    }
                }
            }
        }
        .continuumGroupedListStyle()
    }

    @ViewBuilder
    private func resultRow(_ result: SubtitleSearchResult) -> some View {
        let isDownloadingThis = downloadingId == result.uniqueKey
        Button {
            download(result)
        } label: {
            HStack(spacing: 12) {
                scoreBadge(result.score, fontSize: 13)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.releaseName.isEmpty ? "Untitled release" : result.releaseName)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(resultDetail(result))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isDownloadingThis {
                    ProgressView()
                } else {
                    providerTag(result.provider, fontSize: 11)
                }
            }
        }
        .disabled(downloadingId != nil && !isDownloadingThis)
    }
    #endif

    // MARK: - Shared badges

    /// Rounded score chip, tier-colored (≥70 green / ≥40 amber / else red).
    @ViewBuilder
    private func scoreBadge(_ score: Double, fontSize: CGFloat) -> some View {
        Text("\(Int(score.rounded()))")
            .font(.system(size: fontSize, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(scoreColor(score).opacity(0.85))
            )
    }

    /// Small capsule with the provider abbreviation.
    @ViewBuilder
    private func providerTag(_ provider: String, fontSize: CGFloat) -> some View {
        if !provider.isEmpty {
            Text(providerBadge(provider))
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().strokeBorder(.secondary.opacity(0.45), lineWidth: 1))
        }
    }
}
