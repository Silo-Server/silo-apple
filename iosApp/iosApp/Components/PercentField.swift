import SwiftUI

/// A typed percentage value (min...100). A slider makes the low end — where a
/// few percent is the difference between legible and invisible — fiddly to
/// hit; typing the number directly doesn't have that problem.
///
/// Shared by the Settings subtitle-appearance screen (iOS + macOS) and the
/// in-player subtitle-appearance sheet (iOS) so the two never drift on the
/// clamp, commit, or accessibility behavior.
struct PercentField: View {
    let label: String
    let accessibilityLabelText: String
    let min: Int
    let value: Int
    let onCommit: (Int) -> Void

    @State private var draft: String = ""
    /// True once the user has typed since the last commit or resync. Only a
    /// typed draft is committed: onSubmit, focus loss and onDisappear can all
    /// fire for one edit, and the later ones must neither repeat the write nor
    /// put an untouched draft back over a value synced in the meantime.
    @State private var isDirty = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
            Spacer()
            TextField("", text: Binding(
                get: { draft },
                set: { newDraft in
                    draft = newDraft
                    isDirty = true
                }
            ))
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
                #if os(iOS)
                // The number pad has no return key, so without this there is
                // no way to finish an edit short of tapping elsewhere.
                .toolbar {
                    if focused {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") {
                                commit()
                                focused = false
                            }
                        }
                    }
                }
                #endif
            Text("%")
                .foregroundStyle(Color.siloSecondaryText)
        }
        .onAppear { draft = String(value) }
        .onChange(of: value) { _, newValue in
            // A synced value replaces the draft unless the user is typing.
            if !focused || !isDirty {
                draft = String(newValue)
                isDirty = false
            }
        }
        // Dismissing the sheet or navigating away while this field is still
        // focused (swipe-away, back navigation) never fires onSubmit or the
        // focus-change commit above — it just tears the view down with a
        // typed-but-uncommitted draft. onDisappear is the safety net.
        .onDisappear { commit() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityValue("\(value) percent")
    }

    private func commit() {
        guard isDirty else { return }
        isDirty = false
        guard let parsed = Self.parse(draft) else {
            draft = String(value)
            return
        }
        let clamped = Swift.min(100, Swift.max(min, parsed))
        draft = String(clamped)
        if clamped != value {
            onCommit(clamped)
        }
    }

    /// Accepts what a user plausibly types into a percent field: surrounding
    /// whitespace and a trailing "%" (macOS has no number pad to prevent it).
    static func parse(_ text: String) -> Int? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("%") {
            trimmed = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return Int(trimmed)
    }
}
