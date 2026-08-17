import SwiftUI

/// New-profile flow. Matches the web app's "Profile Editor" UX: pick a
/// DiceBear avatar style, then pick a seed from a grid of 18 previews
/// (re-shuffleable), then set name / PIN / child flag. The chosen preset
/// is serialised as `preset:dicebear:<style>:<seed>` on the wire so the
/// same avatar renders identically on web, Android, and iOS.
///
/// On tvOS this is a full-screen two-column takeover (live preview on the
/// left, form on the right). On iOS it renders as a sheet-friendly
/// single-column scroll view.
struct CreateProfileView: View {
    let onCreated: () -> Void

    @State private var name: String = ""
    @State private var selectedStyleId: String = ProfileAvatarPresets.defaultStyleId
    @State private var selectedSeed: String?
    @State private var presetBatch: Int = 0
    @State private var pin: String = ""
    @State private var isChild: Bool = false
    @State private var maxContentRating: String = "PG"
    @State private var libraryRestrictionsEnabled: Bool = false
    @State private var allowedLibraryIds: Set<Int> = []
    @State private var libraries: [Library] = []
    @State private var isLoading: Bool = false
    @State private var formError: FormError?
    @Environment(\.dismiss) private var dismiss

    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case name, pin }

    private struct FormError: Equatable {
        var title: String = "Couldn't Create Profile"
        var message: String
    }

    private var presets: [ProfileAvatarPresets.Preset] {
        ProfileAvatarPresets.batch(styleId: selectedStyleId, batch: presetBatch)
    }

    /// Initials draw their display text from the `seed`, so a random word-pair
    /// seed like "cosmic-otter" produces avatars reading "CO" — useless. For
    /// this style we skip the preset grid and derive the seed from the name
    /// the user is typing, so the preview updates live as they type.
    private var isInitialsStyle: Bool { selectedStyleId == "initials" }

    private var initialsSeed: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "You" : trimmed
    }

    /// The preset that drives both the live preview tile and the submit
    /// payload. Falls back to the first preset in the current batch when
    /// the user hasn't explicitly picked one yet, so the preview never
    /// shows an empty avatar.
    private var activePreset: ProfileAvatarPresets.Preset? {
        if isInitialsStyle {
            return ProfileAvatarPresets.Preset(styleId: "initials", seed: initialsSeed)
        }
        if let seed = selectedSeed {
            return ProfileAvatarPresets.Preset(styleId: selectedStyleId, seed: seed)
        }
        return presets.first
    }

    var body: some View {
        Group {
            #if os(tvOS)
            tvOSLayout
            #else
            iOSLayout
            #endif
        }
        .alert(
            formError?.title ?? "",
            isPresented: Binding(
                get: { formError != nil },
                set: { if !$0 { formError = nil } }
            ),
            presenting: formError
        ) { _ in
            Button("OK", role: .cancel) { formError = nil }
        } message: { err in
            Text(err.message)
        }
        .task {
            libraries = (try? await SiloAPI.shared.libraries().libraries) ?? []
        }
        .onChange(of: isChild) { _, child in
            if child {
                if maxContentRating.isEmpty { maxContentRating = "PG" }
                libraryRestrictionsEnabled = true
            } else {
                maxContentRating = ""
                libraryRestrictionsEnabled = false
                allowedLibraryIds.removeAll()
            }
        }
    }

    // MARK: - tvOS

    #if os(tvOS)
    private var tvOSLayout: some View {
        ZStack {
            Color.siloBackground.ignoresSafeArea()
            RadialGradient(
                colors: [Color.white.opacity(0.06), Color.black.opacity(0)],
                center: .center,
                startRadius: 0,
                endRadius: 900
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                tvOSHeader
                    .padding(.top, 60)
                    .padding(.horizontal, 80)

                HStack(alignment: .top, spacing: 80) {
                    previewColumn

                    // Scroll the control column so focus can reach the PIN field,
                    // Child toggle, and Create button when they extend past the
                    // safe area — the focus engine auto-scrolls focusable rows
                    // into view inside a ScrollView.
                    ScrollView(.vertical, showsIndicators: false) {
                        pickerColumn
                            .padding(.bottom, 40)
                    }
                    .scrollClipDisabled()
                }
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 80)
                .padding(.top, 32)
            }
        }
        .onExitCommand { dismiss() }
    }

    private var tvOSHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Profile")
                    .font(.system(size: 48, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(.white)
                Text("Pick a look and give it a name.")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Button { dismiss() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Cancel")
                        .font(.system(size: 18, weight: .medium))
                }
            }
            .buttonStyle(GhostChipButtonStyle())
        }
    }

    private var previewColumn: some View {
        VStack(spacing: 24) {
            ProfileTile(profile: previewProfile, action: {})
                .allowsHitTesting(false)
                .disabled(true)

            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Your tile will look like this.")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 8)
            }
        }
        .frame(width: 360)
        .padding(.top, 8)
    }

    private var pickerColumn: some View {
        VStack(alignment: .leading, spacing: 32) {
            section(title: "Style") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(ProfileAvatarPresets.styles) { style in
                            StyleChip(
                                style: style,
                                isSelected: style.id == selectedStyleId,
                                onSelect: { pickStyle(style.id) }
                            )
                        }
                    }
                    // Buffer so the chip's rounded corners don't sit flush
                    // against the ScrollView's clip boundary.
                    .padding(.vertical, 4)
                }
                .scrollClipDisabled()
            }

            if isInitialsStyle {
                section(title: "Avatar") {
                    initialsHint
                }
            } else {
                section(title: "Avatar", trailing: AnyView(shuffleButton)) {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 6),
                        spacing: 14
                    ) {
                        ForEach(presets) { preset in
                            PresetCell(
                                preset: preset,
                                isSelected: preset.seed == activePreset?.seed,
                                onSelect: { selectedSeed = preset.seed }
                            )
                        }
                    }
                }
            }

            section(title: "Name") {
                TextField("Profile name", text: $name)
                    .textFieldStyle(SiloTextFieldStyle())
                    .focused($focusedField, equals: .name)
                    .autocorrectionDisabled()
                    #if !os(macOS)
                    .textInputAutocapitalization(.words)
                    #endif
                    .submitLabel(.next)
            }

            section(title: "PIN (optional)") {
                TextField("4-digit PIN", text: $pin)
                    .textFieldStyle(SiloTextFieldStyle())
                    .focused($focusedField, equals: .pin)
                    .autocorrectionDisabled()
                    .onChange(of: pin) { _, newValue in
                        let filtered = String(newValue.prefix(4).filter(\.isNumber))
                        if filtered != newValue { pin = filtered }
                    }
            }

            ChildProfileRow(isOn: $isChild)

            if isChild {
                childAccessControls
            }

            Button("Create Profile") {
                guard !isLoading else { return }
                Task { await createProfile() }
            }
            .buttonStyle(SiloPrimaryButtonStyle(isLoading: isLoading))
            // Gate validity via .disabled, but not the in-flight state: disabling
            // the focused button mid-create bounces focus to a neighbour. The
            // spinner label signals progress and re-entry is guarded above.
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        trailing: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text(title.uppercased())
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                if let trailing { trailing }
            }
            content()
        }
    }
    #endif

    // MARK: - iOS

    #if !os(tvOS)
    private var iOSLayout: some View {
        NavigationStack {
            ZStack {
                Color.siloBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: SiloTheme.largePadding) {
                        ProfileTile(profile: previewProfile, action: {})
                            .allowsHitTesting(false)
                            .disabled(true)

                        stylePickerRow

                        if isInitialsStyle {
                            initialsHint
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Avatar")
                                        .font(.siloCaption)
                                        .foregroundColor(.siloSecondaryText)
                                    Spacer()
                                    shuffleButton
                                }
                                presetGrid
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Name")
                                .font(.siloCaption)
                                .foregroundColor(.siloSecondaryText)
                            TextField("Profile name", text: $name)
                                .textFieldStyle(SiloTextFieldStyle())
                                .focused($focusedField, equals: .name)
                                .autocorrectionDisabled()
                                #if !os(macOS)
                                .textInputAutocapitalization(.words)
                                #endif
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("PIN (optional)")
                                .font(.siloCaption)
                                .foregroundColor(.siloSecondaryText)
                            TextField("4-digit PIN", text: $pin)
                                .textFieldStyle(SiloTextFieldStyle())
                                .focused($focusedField, equals: .pin)
                                #if !os(macOS)
                                .keyboardType(.numberPad)
                                #endif
                                .onChange(of: pin) { _, newValue in
                                    let filtered = String(newValue.prefix(4).filter(\.isNumber))
                                    if filtered != newValue { pin = filtered }
                                }
                        }

                        Toggle(isOn: $isChild) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Child Profile")
                                    .font(.siloBody)
                                    .foregroundColor(.siloOnSurface)
                                Text("Restricts content to kid-friendly ratings")
                                    .font(.siloCaption)
                                    .foregroundColor(.siloSecondaryText)
                            }
                        }
                        .tint(.siloAccent)

                        if isChild {
                            childAccessControls
                        }

                        Button("Create Profile") {
                            Task { await createProfile() }
                        }
                        .siloPrimaryButton(isLoading: isLoading)
                        .disabled(isLoading || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.horizontal, SiloTheme.largePadding)
                    .padding(.vertical, SiloTheme.largePadding)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.siloPrimary)
                }
            }
            .navigationTitle("New Profile")
            .siloNavigationTitleDisplayMode(.inline)
            .siloToolbarColorSchemeDark()
        }
    }

    private var stylePickerRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Style")
                .font(.siloCaption)
                .foregroundColor(.siloSecondaryText)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ProfileAvatarPresets.styles) { style in
                        StyleChip(
                            style: style,
                            isSelected: style.id == selectedStyleId,
                            onSelect: { pickStyle(style.id) }
                        )
                    }
                }
                // Buffer so the chip's rounded corners don't sit flush
                // against the ScrollView's clip boundary.
                .padding(.vertical, 4)
            }
            .scrollClipDisabled()
        }
    }

    private var presetGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6),
            spacing: 10
        ) {
            ForEach(presets) { preset in
                PresetCell(
                    preset: preset,
                    isSelected: preset.seed == activePreset?.seed,
                    onSelect: { selectedSeed = preset.seed }
                )
            }
        }
    }
    #endif

    // MARK: - Shared bits

    private static let contentRatings: [(value: String, label: String)] = [
        ("G", "G / TV-G"),
        ("PG", "PG / TV-PG / TV-Y7"),
        ("PG-13", "PG-13 / TV-14"),
        ("R", "R / TV-MA / NC-17"),
    ]

    private var childAccessControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Maximum content rating")
                    .font(.siloCaption)
                    .foregroundStyle(Color.siloSecondaryText)
                Picker("Maximum content rating", selection: $maxContentRating) {
                    ForEach(Self.contentRatings, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.menu)
            }

            Toggle("Restrict libraries", isOn: $libraryRestrictionsEnabled)
                .tint(.siloAccent)

            if libraryRestrictionsEnabled {
                if libraries.isEmpty {
                    Text("No libraries are available to assign.")
                        .font(.siloCaption)
                        .foregroundStyle(Color.siloSecondaryText)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Allowed libraries")
                            .font(.siloCaption)
                            .foregroundStyle(Color.siloSecondaryText)
                        ForEach(libraries) { library in
                            Toggle(
                                library.name,
                                isOn: Binding(
                                    get: { allowedLibraryIds.contains(library.id) },
                                    set: { allowed in
                                        if allowed {
                                            allowedLibraryIds.insert(library.id)
                                        } else {
                                            allowedLibraryIds.remove(library.id)
                                        }
                                    }
                                )
                            )
                            .tint(.siloAccent)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color.siloSurfaceElevated, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Drive the preview tile from a synthetic `UserProfile`. The avatar
    /// carries the DiceBear preset ref (same wire format the server stores),
    /// so `ProfileTile` renders it via the shared `ProfileAvatarResolver`
    /// without any bespoke preview logic.
    private var previewProfile: UserProfile {
        UserProfile(
            id: "preview-\(selectedStyleId)",
            name: name.isEmpty ? "Your Name" : name,
            avatarEmoji: activePreset?.ref,
            hasPin: !pin.isEmpty,
            isChild: isChild
        )
    }

    /// Shown in place of the preset grid when the user picks the "Initials"
    /// style. The preview tile already shows the derived initials live as
    /// they type, so this only needs to explain the connection to the name
    /// field.
    private var initialsHint: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "textformat")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            VStack(alignment: .leading, spacing: 4) {
                Text("Uses your profile name")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Text("The first letters of the name below appear on your tile.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var shuffleButton: some View {
        Button {
            presetBatch += 1
            selectedSeed = nil
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Shuffle")
            }
            #if os(tvOS)
            .font(.system(size: 18, weight: .medium))
            #else
            .font(.siloCaption)
            #endif
        }
        .buttonStyle(GhostChipButtonStyle())
        .accessibilityLabel("Shuffle avatars")
    }

    /// Selecting a new style resets the seed so the preview jumps to the
    /// first option of the new style — otherwise the user keeps seeing a
    /// seed that doesn't belong to the freshly-picked style.
    private func pickStyle(_ styleId: String) {
        guard selectedStyleId != styleId else { return }
        selectedStyleId = styleId
        selectedSeed = nil
    }

    // MARK: - Submit

    private func createProfile() async {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            formError = FormError(title: "Name Required", message: "Please enter a name.")
            return
        }
        guard !libraryRestrictionsEnabled || !allowedLibraryIds.isEmpty else {
            formError = FormError(
                title: "Choose a Library",
                message: "Select at least one library for this child profile."
            )
            return
        }

        isLoading = true
        formError = nil
        defer { isLoading = false }

        do {
            _ = try await AuthService.shared.createProfile(
                name: name,
                avatarEmoji: activePreset?.ref,
                pin: pin.isEmpty ? nil : pin,
                isChild: isChild,
                maxContentRating: isChild ? maxContentRating : nil,
                libraryRestrictionsEnabled: isChild && libraryRestrictionsEnabled,
                allowedLibraryIds: isChild && libraryRestrictionsEnabled
                    ? allowedLibraryIds.sorted()
                    : []
            )
            onCreated()
        } catch {
            formError = Self.mapSubmitError(error)
        }
    }

    /// Translate a submit failure into a user-facing title/message.
    ///
    /// Detection is layered so the dialog degrades gracefully:
    /// 1. Prefer the server's machine-readable `error` code from the JSON
    ///    envelope (parsed inside `HTTPError`).
    /// 2. Fall back to the raw HTTP status — on this endpoint the server
    ///    only returns 409 for `profile_limit_reached`, so we can trust
    ///    the status even when the body didn't parse (e.g. a proxy
    ///    rewrote it).
    /// 3. Otherwise surface whatever message the server sent.
    private static func mapSubmitError(_ error: Error) -> FormError {
        if let http = error as? HTTPError {
            let fallback = http.errorDescription ?? "Something went wrong."

            if http.serverErrorCode == "profile_limit_reached"
                || http.statusCode == 409 {
                return FormError(
                    title: "Profile Limit Reached",
                    message: "You've reached the maximum number of profiles for this account."
                )
            }
            if http.serverErrorCode == "bad_request" {
                return FormError(title: "Can't Create Profile", message: fallback)
            }
            return FormError(message: fallback)
        }
        return FormError(message: error.localizedDescription)
    }
}

// MARK: - Style chip

/// Horizontal chip that represents a DiceBear style. The chip itself shows
/// the style's label and a small icon — we don't render a preview avatar
/// inside the chip because the style's "look" is already communicated by
/// the grid of 18 avatars below it.
private struct StyleChip: View {
    let style: ProfileAvatarPresets.Style
    let isSelected: Bool
    let onSelect: () -> Void

    @FocusState private var isFocused: Bool

    #if os(tvOS)
    private let verticalPadding: CGFloat = 12
    private let horizontalPadding: CGFloat = 18
    private let fontSize: CGFloat = 18
    private let cornerRadius: CGFloat = 14
    #else
    private let verticalPadding: CGFloat = 9
    private let horizontalPadding: CGFloat = 14
    private let fontSize: CGFloat = 14
    private let cornerRadius: CGFloat = 12
    #endif

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        Text(style.label)
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(shape.fill(background))
            .overlay(
                shape.stroke(
                    isSelected ? Color.white : Color.white.opacity(0.18),
                    lineWidth: isSelected ? 1.5 : 1
                )
            )
            .scaleEffect(isFocused ? 1.06 : 1.0)
            .contentShape(shape)
            .focusable(true)
            .focused($isFocused)
            .onTapGesture(perform: onSelect)
            #if os(tvOS)
            .focusEffectDisabled()
            #endif
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isSelected)
            .accessibilityLabel(style.label)
            .accessibilityHint(style.summary)
            .accessibilityAddTraits(.isButton)
    }

    private var foreground: Color {
        if isSelected { return Color.siloBackground }
        return Color.white.opacity(isFocused ? 1.0 : 0.75)
    }

    private var background: Color {
        if isSelected { return Color.white }
        return Color.white.opacity(isFocused ? 0.12 : 0.06)
    }
}

// MARK: - Preset cell

/// A square DiceBear preview tile. Loads the avatar PNG from DiceBear —
/// cheap to cache (same URL for the same seed) and reasonably fast over
/// Wi-Fi. Selection draws a white ring; focus adds a subtle scale + halo.
private struct PresetCell: View {
    let preset: ProfileAvatarPresets.Preset
    let isSelected: Bool
    let onSelect: () -> Void

    @FocusState private var isFocused: Bool

    #if os(tvOS)
    private let cellSize: CGFloat = 96
    private let radius: CGFloat = 18
    #else
    private let cellSize: CGFloat = 48
    private let radius: CGFloat = 12
    #endif

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.white.opacity(0.04))
            .frame(height: cellSize)
            .overlay(
                DiceBearAvatarImage(url: preset.previewURL)
                    .padding(4)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(
                        isSelected ? Color.white : Color.white.opacity(isFocused ? 0.5 : 0.12),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .shadow(color: Color.white.opacity(isFocused ? 0.18 : 0),
                    radius: isFocused ? 16 : 0)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .focusable(true)
            .focused($isFocused)
            .onTapGesture(perform: onSelect)
            #if os(tvOS)
            .focusEffectDisabled()
            #endif
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isSelected)
            .accessibilityLabel("Avatar \(preset.seed)")
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Child profile row

/// Replaces SwiftUI's `Toggle` because on tvOS the default toggle inverts
/// its entire surface to white on focus — which buries the label text on
/// our dark background and looks nothing like the rest of the form's
/// focus treatment (subtle background + white outline). This version
/// keeps the row readable at all times, with focus signalled by a soft
/// highlight + a prominent switch puck.
private struct ChildProfileRow: View {
    @Binding var isOn: Bool

    @FocusState private var isFocused: Bool

    #if os(tvOS)
    private let titleSize: CGFloat = 20
    private let subtitleSize: CGFloat = 16
    private let switchWidth: CGFloat = 58
    private let switchHeight: CGFloat = 34
    private let puckSize: CGFloat = 26
    #else
    private let titleSize: CGFloat = 16
    private let subtitleSize: CGFloat = 13
    private let switchWidth: CGFloat = 44
    private let switchHeight: CGFloat = 26
    private let puckSize: CGFloat = 20
    #endif

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Child Profile")
                    .font(.system(size: titleSize, weight: .medium))
                    .foregroundStyle(.white)
                Text("Restricts content to kid-friendly ratings")
                    .font(.system(size: subtitleSize))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 16)
            switchView
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isFocused ? Color.white.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isFocused ? Color.white.opacity(0.35) : Color.clear,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .focusable(true)
        .focused($isFocused)
        .onTapGesture { isOn.toggle() }
        #if os(tvOS)
        .focusEffectDisabled()
        #endif
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: isOn)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Child profile")
        .accessibilityValue(isOn ? "On" : "Off")
    }

    private var switchView: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color.white : Color.white.opacity(0.2))
                .frame(width: switchWidth, height: switchHeight)
            Circle()
                .fill(isOn ? Color.siloBackground : Color.white)
                .frame(width: puckSize, height: puckSize)
                .padding(4)
        }
    }
}

// `GhostChipButtonStyle` now lives in `Theme/SiloButtonStyles.swift`
// (shared with `ProfileSelectionView`).
