import SwiftUI

/// Sheet for editing an existing user profile.
struct EditProfileView: View {
    let profile: UserProfile
    let onSaved: () -> Void

    @State private var name: String = ""
    @State private var avatarEmoji: String = ""
    @State private var pin: String = ""
    @State private var isChild: Bool = false
    @State private var isLoading: Bool = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private let emojiOptions = ["😀", "😎", "🤖", "👾", "🎬", "🍿", "🎮", "🎵",
                                 "🦊", "🐱", "🐶", "🦁", "🐼", "🦄", "🐸", "🦋"]

    var body: some View {
        NavigationStack {
            ZStack {
                SiloPageBackdrop()

                ScrollView {
                    VStack(spacing: SiloTheme.largePadding) {
                        // Avatar picker
                        VStack(spacing: 12) {
                            ProfileAvatarView(
                                avatar: avatarEmoji.isEmpty ? nil : avatarEmoji,
                                name: name,
                                size: 96
                            )

                            // Emoji grid
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible()), count: 8),
                                spacing: 8
                            ) {
                                ForEach(emojiOptions, id: \.self) { emoji in
                                    Button {
                                        avatarEmoji = (avatarEmoji == emoji) ? "" : emoji
                                    } label: {
                                        Text(emoji)
                                            .font(.system(size: 28))
                                            .frame(width: 40, height: 40)
                                            .background(
                                                avatarEmoji == emoji
                                                    ? Color.siloPrimary.opacity(0.3)
                                                    : Color.clear
                                            )
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.top, SiloTheme.padding)

                        // Name field
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Name")
                                .font(.siloCaption)
                                .foregroundColor(.siloSecondaryText)

                            TextField("Profile name", text: $name)
                                .textFieldStyle(SiloTextFieldStyle())
                                .autocorrectionDisabled()
                        }

                        // PIN field
                        VStack(alignment: .leading, spacing: 6) {
                            Text("PIN (optional)")
                                .font(.siloCaption)
                                .foregroundColor(.siloSecondaryText)

                            TextField("4-digit PIN", text: $pin)
                                .textFieldStyle(SiloTextFieldStyle())
                                #if !os(macOS)
                                .keyboardType(.numberPad)
                                #endif
                                .onChange(of: pin) { _, newValue in
                                    let filtered = String(newValue.prefix(4).filter(\.isNumber))
                                    if filtered != newValue { pin = filtered }
                                }
                        }

                        // Child profile toggle
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

                        // Error
                        if let error {
                            Text(error)
                                .font(.siloCaption)
                                .foregroundColor(.siloError)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Save button
                        Button("Save Changes") {
                            Task { await saveProfile() }
                        }
                        .siloPrimaryButton(isLoading: isLoading)
                        .disabled(isLoading || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.horizontal, SiloTheme.largePadding)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.siloPrimary)
                }
            }
            .navigationTitle("Edit Profile")
            .siloNavigationTitleDisplayMode(.inline)
            .siloToolbarColorSchemeDark()
        }
        .onAppear {
            name = profile.name
            avatarEmoji = profile.avatarEmoji ?? ""
            isChild = profile.isChild
        }
    }

    private func saveProfile() async {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            error = "Please enter a name."
            return
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        // TODO: Implement PUT /api/v1/profiles/{id} when shared module is linked
        // For now, just dismiss to unblock UI development.
        onSaved()
    }
}
