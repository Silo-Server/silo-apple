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
                ContinuumPageBackdrop()

                ScrollView {
                    VStack(spacing: ContinuumTheme.largePadding) {
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
                                                    ? Color.continuumPrimary.opacity(0.3)
                                                    : Color.clear
                                            )
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.top, ContinuumTheme.padding)

                        // Name field
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Name")
                                .font(.continuumCaption)
                                .foregroundColor(.continuumSecondaryText)

                            TextField("Profile name", text: $name)
                                .textFieldStyle(ContinuumTextFieldStyle())
                                .autocorrectionDisabled()
                        }

                        // PIN field
                        VStack(alignment: .leading, spacing: 6) {
                            Text("PIN (optional)")
                                .font(.continuumCaption)
                                .foregroundColor(.continuumSecondaryText)

                            TextField("4-digit PIN", text: $pin)
                                .textFieldStyle(ContinuumTextFieldStyle())
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
                                    .font(.continuumBody)
                                    .foregroundColor(.continuumOnSurface)

                                Text("Restricts content to kid-friendly ratings")
                                    .font(.continuumCaption)
                                    .foregroundColor(.continuumSecondaryText)
                            }
                        }
                        .tint(.continuumAccent)

                        // Error
                        if let error {
                            Text(error)
                                .font(.continuumCaption)
                                .foregroundColor(.continuumError)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Save button
                        Button("Save Changes") {
                            Task { await saveProfile() }
                        }
                        .siloPrimaryButton(isLoading: isLoading)
                        .disabled(isLoading || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.horizontal, ContinuumTheme.largePadding)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.continuumPrimary)
                }
            }
            .navigationTitle("Edit Profile")
            .continuumNavigationTitleDisplayMode(.inline)
            .continuumToolbarColorSchemeDark()
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
