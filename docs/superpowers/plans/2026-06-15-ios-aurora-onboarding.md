# iOS First-Run Flow → Aurora — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reskin the iOS first-run flow (server setup, sign-in, profile, sign-up) to the shipped tvOS "Aurora" visual language, promote the Aurora design system to shared code, hide protocol/port behind an "Advanced options" disclosure on both iOS and tvOS, and replace the in-app Create-Admin screen with a "finish setup in your browser" state.

**Architecture:** A view-layer reskin. The auth/session logic (`AuthService`, `ServerRegistry`, `TokenStore`), the view models, and the `AppRouter` state machine are unchanged. The Aurora design system (currently `#if os(tvOS)` under `iosApp/iosApp/tvOS/Aurora/`) moves to a shared `DesignSystem/Aurora/` folder so iOS and macOS can use it; the only UIKit-coupled piece (`AuroraInputField`, the tvOS controlled-overlay field) stays tvOS-only and iOS gets a real editable `AuroraTextField`.

**Tech Stack:** Swift 5, SwiftUI, XcodeGen (`project.yml` → `Silo.xcodeproj`). Targets: `Silo` (iOS), `SiloTV` (tvOS), `SiloMac` (macOS). Deployment: iOS 18, tvOS 26, macOS 15.

**Testing note (per `CLAUDE.md`):** This is UI work — do **not** add XCTest cases. Each task is verified by compiling the affected targets and, at the end, a simulator smoke test. The build commands assume the project has been regenerated with `xcodegen generate` whenever files are added/moved/deleted.

**Reference build commands:**
- Regenerate project: `cd iosApp && xcodegen generate`
- iOS: `cd iosApp && xcodebuild build -project Silo.xcodeproj -scheme Silo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO`
- tvOS: `cd iosApp && xcodebuild build -project Silo.xcodeproj -scheme SiloTV -destination 'platform=tvOS Simulator,name=Apple TV' CODE_SIGNING_ALLOWED=NO`
- macOS: `cd iosApp && xcodebuild build -project Silo.xcodeproj -scheme SiloMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`

**Source-path note:** `project.yml` lives at `iosApp/project.yml` and globs `path: iosApp`, so all app sources are under `iosApp/iosApp/…`. The iOS and tvOS targets include the whole tree; **`SiloMac` excludes `tvOS/**`** — this is why Aurora must leave `tvOS/`.

---

## File Structure

**Created**
- `iosApp/iosApp/DesignSystem/Aurora/AuroraStyle.swift` — moved from `tvOS/Aurora/`, cross-platform (tokens, eyebrow, glass, buttons, step row, segment, control metrics)
- `iosApp/iosApp/DesignSystem/Aurora/AuroraBackdrop.swift` — moved from `tvOS/Aurora/`, cross-platform
- `iosApp/iosApp/tvOS/Aurora/AuroraInputField.swift` — extracted tvOS-only controlled field (UIKit)
- `iosApp/iosApp/DesignSystem/Aurora/AuroraTextField.swift` — new iOS/macOS editable field + form helpers (`AuroraFieldLabel`, `AuroraErrorLabel`, `AuroraScreen`)
- `iosApp/iosApp/Screens/Auth/ServerNeedsSetupView.swift` — new "finish setup in your browser" screen

**Modified**
- `iosApp/iosApp/Screens/Auth/ServerSetupView.swift` — Aurora reskin
- `iosApp/iosApp/Screens/Auth/LoginView.swift` — Aurora reskin (password-first; already no QR)
- `iosApp/iosApp/Screens/Auth/SignupView.swift` — Aurora reskin
- `iosApp/iosApp/Screens/Profiles/ProfileSelectionView.swift` — iOS branch onto Aurora backdrop
- `iosApp/iosApp/Screens/Auth/TVServerSetupView.swift` — Advanced-options disclosure
- `iosApp/iosApp/Screens/Auth/ServerSetupViewModel.swift` — route to `.serverNeedsSetup`
- `iosApp/iosApp/Navigation/Route.swift` — `-.setup` `+.serverNeedsSetup`
- `iosApp/iosApp/ContentView.swift` — route switches updated + platform-gated

**Deleted**
- `iosApp/iosApp/Screens/Auth/SetupView.swift`
- `iosApp/iosApp/Screens/Auth/SetupViewModel.swift`

---

## Task 1: Promote Aurora to a cross-platform design system

**Files:**
- Move: `iosApp/iosApp/tvOS/Aurora/AuroraStyle.swift` → `iosApp/iosApp/DesignSystem/Aurora/AuroraStyle.swift`
- Move: `iosApp/iosApp/tvOS/Aurora/AuroraBackdrop.swift` → `iosApp/iosApp/DesignSystem/Aurora/AuroraBackdrop.swift`
- Create: `iosApp/iosApp/tvOS/Aurora/AuroraInputField.swift`

- [ ] **Step 1: Move the two Aurora files with git**

```bash
cd iosApp/iosApp
mkdir -p DesignSystem/Aurora
git mv tvOS/Aurora/AuroraStyle.swift DesignSystem/Aurora/AuroraStyle.swift
git mv tvOS/Aurora/AuroraBackdrop.swift DesignSystem/Aurora/AuroraBackdrop.swift
```

- [ ] **Step 2: Un-gate `AuroraBackdrop.swift`**

In `iosApp/iosApp/DesignSystem/Aurora/AuroraBackdrop.swift`, delete the first line `#if os(tvOS)` and the final line `#endif`. The file is pure SwiftUI and compiles on every platform. Leave everything else unchanged. The file should now start:

```swift
import SwiftUI

// MARK: - Variants
```

…and end with the closing brace of `SeededRNG` (no `#endif`).

- [ ] **Step 3: Extract the tvOS field into `AuroraInputField.swift`**

Create `iosApp/iosApp/tvOS/Aurora/AuroraInputField.swift` with the `AuroraInputField` struct cut verbatim from `AuroraStyle.swift` (lines that currently define `// MARK: - Aurora text field` through the end of `struct AuroraInputField`). It keeps the tvOS gate and the UIKit import:

```swift
#if os(tvOS)
import SwiftUI
import UIKit

// MARK: - Aurora text field
//
// A controlled field so we own the placeholder contrast and focus treatment
// in both states. On tvOS a focused TextField gets a light system platter, so
// the focused state is deliberately a warm cream fill with dark text + a gold
// ring (reads as intentional, high contrast) rather than fighting it.

struct AuroraInputField<F: Hashable>: View {
    @Binding var text: String
    var placeholder: String
    var focus: FocusState<F?>.Binding
    var equals: F
    var isSecure: Bool = false
    var height: CGFloat = AuroraControl.height
    var contentType: UITextContentType? = nil
    var keyboard: UIKeyboardType = .default

    private var isFocused: Bool { focus.wrappedValue == equals }

    var body: some View {
        ZStack(alignment: .leading) {
            Text(displayString)
                .foregroundStyle(displayColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)

            fieldView
                .textFieldStyle(.plain)
                .focused(focus, equals: equals)
                .textContentType(contentType)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .tint(.clear)
                .opacity(0.02)
                .accessibilityLabel(placeholder)
        }
        .font(.system(size: 26))
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: AuroraControl.corner, style: .continuous)
                .fill(isFocused ? AuroraControl.activeFill : Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AuroraControl.corner, style: .continuous)
                .stroke(isFocused ? Color.auroraAccent : Color.white.opacity(0.16),
                        lineWidth: isFocused ? 3 : 1.5)
        )
        .shadow(color: isFocused ? Color.auroraAccent.opacity(0.4) : .clear,
                radius: isFocused ? 20 : 0, y: 0)
        .animation(SiloTheme.springAnimation, value: isFocused)
    }

    private var displayString: String {
        if text.isEmpty { return placeholder }
        return isSecure ? String(repeating: "•", count: text.count) : text
    }

    private var displayColor: Color {
        if text.isEmpty {
            return isFocused ? AuroraControl.activePlaceholder : Color.auroraInkTertiary
        }
        return isFocused ? AuroraControl.activeInk : Color.auroraInk
    }

    @ViewBuilder
    private var fieldView: some View {
        if isSecure {
            SecureField("", text: $text)
        } else {
            TextField("", text: $text)
        }
    }
}
#endif
```

- [ ] **Step 4: Un-gate and trim `AuroraStyle.swift`**

In `iosApp/iosApp/DesignSystem/Aurora/AuroraStyle.swift`:
1. Replace the first three lines (`#if os(tvOS)` / `import SwiftUI` / `import UIKit`) with just `import SwiftUI`.
2. Delete the entire `// MARK: - Aurora text field` section and the `AuroraInputField` struct (now in the tvOS file from Step 3).
3. Delete the final `#endif`.
4. Make the shared control height platform-aware so iOS fields/segments aren't TV-sized. Replace the `AuroraControl` enum's `height` line:

```swift
enum AuroraControl {
    /// Shared height for inputs + segmented options so they line up on a row.
    #if os(tvOS)
    static let height: CGFloat = 72
    #else
    static let height: CGFloat = 52
    #endif
    static let corner: CGFloat = 14
    /// Warm cream fill used when a field/segment is focused.
    static let activeFill = Color(hex: "#F4EEE2")
    static let activeInk = Color(hex: "#1A1206")
    static let activePlaceholder = Color(hex: "#4A4035")
}
```

Everything else (the `Color` palette extension, `AuroraEyebrow`, `AuroraGlassPanel`/`auroraGlass`, `AuroraPrimaryButtonStyle`, `AuroraGhostButtonStyle`, `AuroraStepRow`, `AuroraSegment`) stays exactly as-is. None of it imports or uses UIKit.

- [ ] **Step 5: Regenerate the project**

Run: `cd iosApp && xcodegen generate`
Expected: `Created project at .../Silo.xcodeproj` with no errors.

- [ ] **Step 6: Build all three targets**

Run each and expect `** BUILD SUCCEEDED **`:
```bash
cd iosApp
xcodebuild build -project Silo.xcodeproj -scheme SiloTV -destination 'platform=tvOS Simulator,name=Apple TV' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Silo.xcodeproj -scheme Silo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Silo.xcodeproj -scheme SiloMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
tvOS exercises `AuroraInputField` + the moved files; iOS/macOS prove the un-gated Aurora compiles where it previously didn't.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Promote Aurora design system to shared cross-platform code"
```

---

## Task 2: iOS/macOS Aurora form kit

**Files:**
- Create: `iosApp/iosApp/DesignSystem/Aurora/AuroraTextField.swift`

- [ ] **Step 1: Create the form kit**

Create `iosApp/iosApp/DesignSystem/Aurora/AuroraTextField.swift`. It is gated `#if !os(tvOS)` (tvOS uses `AuroraInputField`). It defines: a platform-neutral content-type/keyboard enum (so macOS — which has no `UITextContentType` — still compiles), the editable `AuroraTextField`, an `AuroraFieldLabel`, an `AuroraErrorLabel`, and the `AuroraScreen` scaffold.

```swift
#if !os(tvOS)
import SwiftUI

// MARK: - Field content classification (platform-neutral)

/// Mirrors the small enum pattern in the old Silo forms so the shared
/// component carries no UIKit types in its signature — macOS has no
/// `UITextContentType`.
enum AuroraFieldContentType { case username, password, email, oneTimeCode, url }
enum AuroraFieldKeyboard { case `default`, url, email, number }

// MARK: - Field label (mono caps)

struct AuroraFieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .tracking(1.6)
            .foregroundStyle(Color.auroraInkTertiary)
    }
}

// MARK: - Inline error row

struct AuroraErrorLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.siloCaption)
        .foregroundStyle(Color.siloError)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }
}

// MARK: - Editable Aurora field (iOS/macOS)
//
// A real, editable field styled with the Aurora chrome. The placeholder is a
// controlled overlay so we own its contrast on the plum background; the live
// `TextField`/`SecureField` carries the caret, selection, and keyboard. When
// focused it flips to the warm cream fill + gold ring used across the flow.

struct AuroraTextField<F: Hashable>: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var focus: FocusState<F?>.Binding
    var equals: F
    var isSecure: Bool = false
    var showsRevealToggle: Bool = false
    var contentType: AuroraFieldContentType? = nil
    var keyboard: AuroraFieldKeyboard = .default
    var submitLabel: SubmitLabel = .next
    var onSubmit: () -> Void = {}

    @State private var reveal = false
    private var isFocused: Bool { focus.wrappedValue == equals }
    private var effectiveSecure: Bool { isSecure && !reveal }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AuroraFieldLabel(label)
            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(isFocused ? AuroraControl.activePlaceholder : Color.auroraInkTertiary)
                            .allowsHitTesting(false)
                    }
                    inputField
                        .focused(focus, equals: equals)
                        .foregroundStyle(isFocused ? AuroraControl.activeInk : Color.auroraInk)
                        .tint(isFocused ? AuroraControl.activeInk : Color.auroraAccent)
                        .submitLabel(submitLabel)
                        .onSubmit(onSubmit)
                        #if !os(macOS)
                        .textContentType(uiContentType)
                        .keyboardType(uiKeyboard)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }
                if showsRevealToggle {
                    Button {
                        reveal.toggle()
                    } label: {
                        Image(systemName: reveal ? "eye.slash.fill" : "eye.fill")
                            .foregroundStyle(isFocused ? AuroraControl.activeInk.opacity(0.7) : Color.auroraInkTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(reveal ? "Hide password" : "Show password")
                }
            }
            .font(.system(size: 17))
            .padding(.horizontal, 16)
            .frame(height: AuroraControl.height)
            .background(
                RoundedRectangle(cornerRadius: AuroraControl.corner, style: .continuous)
                    .fill(isFocused ? AuroraControl.activeFill : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AuroraControl.corner, style: .continuous)
                    .stroke(isFocused ? Color.auroraAccent : Color.white.opacity(0.16),
                            lineWidth: isFocused ? 2 : 1.5)
            )
            .shadow(color: isFocused ? Color.auroraAccent.opacity(0.35) : .clear,
                    radius: isFocused ? 16 : 0)
            .animation(SiloTheme.springAnimation, value: isFocused)
        }
    }

    @ViewBuilder
    private var inputField: some View {
        if effectiveSecure {
            SecureField("", text: $text)
        } else {
            TextField("", text: $text)
        }
    }

    #if !os(macOS)
    private var uiContentType: UITextContentType? {
        switch contentType {
        case .username: .username
        case .password: .password
        case .email: .emailAddress
        case .oneTimeCode: .oneTimeCode
        case .url: .URL
        case .none: nil
        }
    }
    private var uiKeyboard: UIKeyboardType {
        switch keyboard {
        case .default: .default
        case .url: .URL
        case .email: .emailAddress
        case .number: .numberPad
        }
    }
    #endif
}

// MARK: - Screen scaffold

/// Aurora backdrop + a vertically scrollable, keyboard-friendly column capped
/// to a comfortable reading width. Callers supply the wordmark + content.
struct AuroraScreen<Content: View>: View {
    var variant: AuroraVariant
    var scrim: AuroraScrim = .soft
    var maxContentWidth: CGFloat = 480
    @ViewBuilder var content: () -> Content

    init(variant: AuroraVariant,
         scrim: AuroraScrim = .soft,
         maxContentWidth: CGFloat = 480,
         @ViewBuilder content: @escaping () -> Content) {
        self.variant = variant
        self.scrim = scrim
        self.maxContentWidth = maxContentWidth
        self.content = content
    }

    var body: some View {
        ZStack {
            AuroraBackdrop(variant: variant, scrim: scrim)
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 0) { content() }
                        .frame(maxWidth: maxContentWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 32)
                        .frame(minHeight: geo.size.height)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .preferredColorScheme(.dark)
    }
}
#endif
```

- [ ] **Step 2: Regenerate the project (new file)**

Run: `cd iosApp && xcodegen generate`
Expected: success.

- [ ] **Step 3: Build iOS + macOS**

Run (expect `** BUILD SUCCEEDED **`):
```bash
cd iosApp
xcodebuild build -project Silo.xcodeproj -scheme Silo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Silo.xcodeproj -scheme SiloMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "Add iOS/macOS Aurora form kit (field, labels, screen scaffold)"
```

---

## Task 3: Reskin `ServerSetupView` (iOS/macOS)

**Files:**
- Modify (full replace): `iosApp/iosApp/Screens/Auth/ServerSetupView.swift`

Note: the iOS server screen already keeps Advanced collapsed (`viewModel.showsAdvancedOptions == false`) and has no "set up a TV" footnote, so this task is purely the Aurora skin + gating the view to `#if !os(tvOS)`.

- [ ] **Step 1: Replace the file**

```swift
import SwiftUI

#if !os(tvOS)
/// First screen when no server is configured (Aurora). A single centered glass
/// form over the plum backdrop — no phone-pairing card, because on iPhone the
/// phone *is* the companion (the pairing card auto-overlays from `ContentView`
/// when a TV is nearby). Protocol + port stay tucked under "Advanced options".
struct ServerSetupView: View {
    var router: AppRouter
    @State private var viewModel = ServerSetupViewModel()
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case host, port }

    var body: some View {
        AuroraScreen(variant: .server, scrim: .soft) {
            SiloWordmarkView(width: 132)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 30)

            VStack(spacing: 12) {
                AuroraEyebrow(text: "Step 01 — Connect", centered: true)
                Text("Add your server")
                    .font(.siloTitle)
                    .foregroundStyle(Color.auroraInk)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 18) {
                AuroraTextField(
                    label: "Server address",
                    text: $viewModel.host,
                    placeholder: "media.example.com",
                    focus: $focusedField,
                    equals: .host,
                    contentType: .url,
                    keyboard: .url,
                    submitLabel: .go,
                    onSubmit: { connect() }
                )

                advancedDisclosure

                if let error = viewModel.error {
                    AuroraErrorLabel(error)
                }

                Button {
                    connect()
                } label: {
                    Text(viewModel.isLoading ? "Connecting…" : "Connect")
                }
                .buttonStyle(AuroraPrimaryButtonStyle(isLoading: viewModel.isLoading))
                .disabled(viewModel.isLoading)
                .padding(.top, 4)
            }
            .padding(22)
            .auroraGlass(cornerRadius: 24, emphasized: true)
            .animation(.easeInOut(duration: 0.2), value: viewModel.error)
        }
    }

    private func connect() {
        guard !viewModel.isLoading else { return }
        Task { await viewModel.connect(router: router) }
    }

    @ViewBuilder
    private var advancedDisclosure: some View {
        Button {
            withAnimation(SiloTheme.springAnimation) {
                viewModel.showsAdvancedOptions.toggle()
            }
        } label: {
            HStack(spacing: 7) {
                Text("Advanced options")
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .rotationEffect(.degrees(viewModel.showsAdvancedOptions ? 180 : 0))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(AuroraGhostButtonStyle())

        if viewModel.showsAdvancedOptions {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    AuroraFieldLabel("Protocol")
                    HStack(spacing: 8) {
                        ForEach(ServerSetupScheme.allCases) { scheme in
                            Button {
                                viewModel.selectedScheme = scheme
                            } label: {
                                AuroraSegment(
                                    title: scheme.rawValue,
                                    isSelected: viewModel.selectedScheme == scheme,
                                    isFocused: false
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                AuroraTextField(
                    label: "Port",
                    text: $viewModel.port,
                    placeholder: "8096",
                    focus: $focusedField,
                    equals: .port,
                    keyboard: .number
                )
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}
#endif
```

- [ ] **Step 2: Build iOS + macOS**

Run (expect `** BUILD SUCCEEDED **`):
```bash
cd iosApp
xcodebuild build -project Silo.xcodeproj -scheme Silo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Silo.xcodeproj -scheme SiloMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
(`ServerSetupView` is now `#if !os(tvOS)`. ContentView already only references it under `#else`/non-tvOS branches, so tvOS is unaffected — but the tvOS build is verified in Task 8 after the ContentView edits land.)

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "Reskin iOS ServerSetupView to Aurora"
```

---

## Task 4: Add Advanced-options disclosure to tvOS `TVServerSetupView`

**Files:**
- Modify: `iosApp/iosApp/Screens/Auth/TVServerSetupView.swift`

Goal: on tvOS the manual card should show only the address field + Connect by default; protocol + port move behind a focusable "Advanced options" toggle bound to the shared `viewModel.showsAdvancedOptions`.

- [ ] **Step 1: Add an `advanced` focus case**

In the `Field` enum (currently `case host`, `case scheme(...)`, `case port`, `case connect`) add `advanced`:

```swift
    private enum Field: Hashable {
        case host
        case advanced
        case scheme(ServerSetupScheme)
        case port
        case connect
    }
```

- [ ] **Step 2: Replace the protocol/port block in `manualCard` with a disclosure**

In `manualCard`, replace this block:

```swift
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    fieldLabel("Protocol")
                    protocolSegments
                }
                VStack(alignment: .leading, spacing: 10) {
                    fieldLabel("Port")
                    AuroraInputField(
                        text: $viewModel.port,
                        placeholder: "8096",
                        focus: $focusedField,
                        equals: .port,
                        keyboard: .numberPad
                    )
                }
                .frame(width: 190)
            }
```

with:

```swift
            Button {
                withAnimation(SiloTheme.springAnimation) {
                    viewModel.showsAdvancedOptions.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Text("Advanced options")
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(viewModel.showsAdvancedOptions ? 180 : 0))
                }
            }
            .buttonStyle(AuroraGhostButtonStyle())
            .focused($focusedField, equals: .advanced)

            if viewModel.showsAdvancedOptions {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        fieldLabel("Protocol")
                        protocolSegments
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        fieldLabel("Port")
                        AuroraInputField(
                            text: $viewModel.port,
                            placeholder: "8096",
                            focus: $focusedField,
                            equals: .port,
                            keyboard: .numberPad
                        )
                    }
                    .frame(width: 190)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
```

- [ ] **Step 3: Animate the card on disclosure changes**

On `manualCard`, add an animation for the toggle next to the existing error animation. Change:

```swift
        .animation(.easeInOut(duration: 0.2), value: viewModel.error)
```
to:
```swift
        .animation(.easeInOut(duration: 0.2), value: viewModel.error)
        .animation(SiloTheme.springAnimation, value: viewModel.showsAdvancedOptions)
```

- [ ] **Step 4: Build tvOS**

Run (expect `** BUILD SUCCEEDED **`):
```bash
cd iosApp
xcodebuild build -project Silo.xcodeproj -scheme SiloTV -destination 'platform=tvOS Simulator,name=Apple TV' CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Hide protocol/port behind Advanced options on tvOS server setup"
```

---

## Task 5: Reskin `LoginView` (iOS/macOS, password-first)

**Files:**
- Modify (full replace): `iosApp/iosApp/Screens/Auth/LoginView.swift`

- [ ] **Step 1: Replace the file**

```swift
import SwiftUI

#if !os(tvOS)
/// Password-first sign-in (Aurora). iOS/macOS only — tvOS uses `TVLoginView`,
/// which leads with QR device-login. Here the phone *is* the device, so we go
/// straight to username/password over the plum backdrop.
struct LoginView: View {
    var router: AppRouter
    @State private var viewModel = LoginViewModel()
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case username, password }

    var body: some View {
        AuroraScreen(variant: .signIn, scrim: .soft) {
            SiloWordmarkView(width: 132)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 30)

            VStack(spacing: 12) {
                AuroraEyebrow(text: "Step 02 — Sign in", centered: true)
                Text("Welcome back")
                    .font(.siloTitle)
                    .foregroundStyle(Color.auroraInk)
                if let host = hostLabel {
                    Text(host)
                        .font(.system(size: 14, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.auroraInkTertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 18) {
                AuroraTextField(
                    label: "Username",
                    text: $viewModel.username,
                    placeholder: "yourname",
                    focus: $focusedField,
                    equals: .username,
                    contentType: .username,
                    submitLabel: .next,
                    onSubmit: { focusedField = .password }
                )

                AuroraTextField(
                    label: "Password",
                    text: $viewModel.password,
                    placeholder: "••••••",
                    focus: $focusedField,
                    equals: .password,
                    isSecure: true,
                    showsRevealToggle: true,
                    contentType: .password,
                    submitLabel: .go,
                    onSubmit: { signIn() }
                )

                if let error = viewModel.error {
                    AuroraErrorLabel(error)
                }

                Button {
                    signIn()
                } label: {
                    Text(viewModel.isLoading ? "Signing in…" : "Sign in")
                }
                .buttonStyle(AuroraPrimaryButtonStyle(isLoading: viewModel.isLoading))
                .disabled(viewModel.isLoading)
                .padding(.top, 4)

                HStack(spacing: 14) {
                    if viewModel.signupEnabled {
                        Button("Create account") { router.navigate(to: .signup) }
                            .buttonStyle(AuroraGhostButtonStyle())
                    }
                    Button("Change server") { router.resetToServerSetup() }
                        .buttonStyle(AuroraGhostButtonStyle())
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
            .padding(22)
            .auroraGlass(cornerRadius: 24, emphasized: true)
            .animation(.easeInOut(duration: 0.2), value: viewModel.error)
        }
        .navigationBarBackButtonHidden()
        .task { await viewModel.checkSignupStatus() }
    }

    private func signIn() {
        guard !viewModel.isLoading else { return }
        Task { await viewModel.login(router: router) }
    }

    /// Host pulled out of the active server URL so the user sees which server
    /// they're signing into. Mirrors `TVLoginView.hostLabel`.
    private var hostLabel: String? {
        let url = AuthService.shared.serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        if let parsed = URL(string: url), let host = parsed.host, !host.isEmpty {
            return host
        }
        return url.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }
}
#endif
```

- [ ] **Step 2: Build iOS + macOS**

Run (expect `** BUILD SUCCEEDED **`):
```bash
cd iosApp
xcodebuild build -project Silo.xcodeproj -scheme Silo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Silo.xcodeproj -scheme SiloMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "Reskin iOS LoginView to Aurora (password-first)"
```

---

## Task 6: Reskin `SignupView` (iOS/macOS)

**Files:**
- Modify (full replace): `iosApp/iosApp/Screens/Auth/SignupView.swift`

- [ ] **Step 1: Replace the file**

```swift
import SwiftUI

#if !os(tvOS)
/// Account registration (Aurora). Shown when signup is enabled on the server.
struct SignupView: View {
    var router: AppRouter
    @State private var viewModel = SignupViewModel()
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case username, email, password, confirm, invite }

    var body: some View {
        AuroraScreen(variant: .signIn, scrim: .soft) {
            SiloWordmarkView(width: 132)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 30)

            VStack(spacing: 12) {
                AuroraEyebrow(text: "Create account", centered: true)
                Text("Create your account")
                    .font(.siloTitle)
                    .foregroundStyle(Color.auroraInk)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 16) {
                AuroraTextField(
                    label: "Username", text: $viewModel.username, placeholder: "yourname",
                    focus: $focusedField, equals: .username,
                    contentType: .username, onSubmit: { focusedField = .email }
                )
                AuroraTextField(
                    label: "Email", text: $viewModel.email, placeholder: "you@example.com",
                    focus: $focusedField, equals: .email,
                    contentType: .email, keyboard: .email, onSubmit: { focusedField = .password }
                )
                AuroraTextField(
                    label: "Password", text: $viewModel.password, placeholder: "••••••",
                    focus: $focusedField, equals: .password,
                    isSecure: true, showsRevealToggle: true,
                    contentType: .password, onSubmit: { focusedField = .confirm }
                )
                AuroraTextField(
                    label: "Confirm password", text: $viewModel.confirmPassword, placeholder: "••••••",
                    focus: $focusedField, equals: .confirm,
                    isSecure: true, contentType: .password, onSubmit: { focusedField = .invite }
                )
                AuroraTextField(
                    label: "Invite code", text: $viewModel.inviteCode, placeholder: "ABCD-1234",
                    focus: $focusedField, equals: .invite,
                    contentType: .oneTimeCode, submitLabel: .go, onSubmit: { createAccount() }
                )

                if let error = viewModel.error {
                    AuroraErrorLabel(error)
                }

                Button {
                    createAccount()
                } label: {
                    Text(viewModel.isLoading ? "Creating…" : "Create account")
                }
                .buttonStyle(AuroraPrimaryButtonStyle(isLoading: viewModel.isLoading))
                .disabled(viewModel.isLoading)
                .padding(.top, 4)

                Button("Back to sign in") { router.goBack() }
                    .buttonStyle(AuroraGhostButtonStyle())
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
            }
            .padding(22)
            .auroraGlass(cornerRadius: 24, emphasized: true)
            .animation(.easeInOut(duration: 0.2), value: viewModel.error)
        }
        .navigationBarBackButtonHidden()
    }

    private func createAccount() {
        guard !viewModel.isLoading else { return }
        Task { await viewModel.signup(router: router) }
    }
}
#endif
```

- [ ] **Step 2: Build iOS + macOS**

Run (expect `** BUILD SUCCEEDED **`):
```bash
cd iosApp
xcodebuild build -project Silo.xcodeproj -scheme Silo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Silo.xcodeproj -scheme SiloMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "Reskin iOS SignupView to Aurora"
```

---

## Task 7: Converge `ProfileSelectionView` iOS branch onto the Aurora backdrop

**Files:**
- Modify: `iosApp/iosApp/Screens/Profiles/ProfileSelectionView.swift`

This file is shared; only the iOS/macOS (`#else`) branches change. The tvOS branch already uses `AuroraBackdrop` + `auroraInk`.

- [ ] **Step 1: Swap the iOS background to the Aurora backdrop**

In `background`, replace the `#else` branch:

```swift
        #else
        ZStack {
            Color.siloBackground.ignoresSafeArea()
            RadialGradient(
                colors: [Color.white.opacity(0.07), Color.black.opacity(0)],
                center: .center,
                startRadius: 0,
                endRadius: 900
            )
            .ignoresSafeArea()
            .blendMode(.plusLighter)
        }
        #endif
```
with:
```swift
        #else
        AuroraBackdrop(variant: .profile, scrim: .soft)
        #endif
```

- [ ] **Step 2: Use Aurora ink for the iOS title block**

In `titleBlock`, replace the `#else` branch:

```swift
            #else
            Text("Who's watching?")
                .font(.system(size: titleSize, weight: .semibold))
                .tracking(-0.5)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text("Select your profile")
                .font(.system(size: subtitleSize, weight: .regular))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            #endif
```
with:
```swift
            #else
            Text("Who's watching?")
                .font(.system(size: titleSize, weight: .semibold))
                .tracking(-0.5)
                .foregroundStyle(Color.auroraInk)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text("Select your profile")
                .font(.system(size: subtitleSize, weight: .regular))
                .foregroundStyle(Color.auroraInkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            #endif
```

- [ ] **Step 3: Build iOS + macOS + tvOS**

Run (expect `** BUILD SUCCEEDED **` for each):
```bash
cd iosApp
xcodebuild build -project Silo.xcodeproj -scheme Silo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Silo.xcodeproj -scheme SiloMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Silo.xcodeproj -scheme SiloTV -destination 'platform=tvOS Simulator,name=Apple TV' CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "Converge iOS profile selection onto the Aurora backdrop"
```

---

## Task 8: Replace Create-Admin with a "server needs setup" screen

**Files:**
- Create: `iosApp/iosApp/Screens/Auth/ServerNeedsSetupView.swift`
- Modify: `iosApp/iosApp/Navigation/Route.swift`
- Modify: `iosApp/iosApp/Screens/Auth/ServerSetupViewModel.swift`
- Modify: `iosApp/iosApp/ContentView.swift`
- Delete: `iosApp/iosApp/Screens/Auth/SetupView.swift`
- Delete: `iosApp/iosApp/Screens/Auth/SetupViewModel.swift`

- [ ] **Step 1: Create `ServerNeedsSetupView`**

```swift
import SwiftUI

#if !os(tvOS)
/// Shown when the chosen server has no account yet (`/api/v1/auth/setup`
/// reports `needsSetup`). iOS no longer creates the admin account in-app —
/// that happens in the server's web UI — so we point the user there and offer
/// a retry that re-probes the server.
struct ServerNeedsSetupView: View {
    var router: AppRouter
    @State private var isChecking = false
    @State private var error: String?

    var body: some View {
        AuroraScreen(variant: .server, scrim: .soft) {
            SiloWordmarkView(width: 132)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 26)

            AuroraEyebrow(text: "Setup needed", centered: true)
                .padding(.bottom, 18)

            ZStack {
                Circle().fill(Color.auroraAccent.opacity(0.14))
                Circle().stroke(Color.auroraAccent.opacity(0.34), lineWidth: 1)
                Image(systemName: "gearshape.2")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(Color.auroraAccent)
            }
            .frame(width: 78, height: 78)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 18)

            VStack(spacing: 12) {
                Text("Finish setup in your browser")
                    .font(.siloTitle)
                    .foregroundStyle(Color.auroraInk)
                    .multilineTextAlignment(.center)
                Text("This server doesn't have an account yet. Open it in a browser to create the first one, then come back here to sign in.")
                    .font(.siloBody)
                    .foregroundStyle(Color.auroraInkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 22)

            VStack(spacing: 16) {
                if let host {
                    HStack(spacing: 10) {
                        Text(host)
                            .font(.system(size: 15, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color.auroraInk)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(Color.auroraInkTertiary)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: AuroraControl.height)
                    .background(
                        RoundedRectangle(cornerRadius: AuroraControl.corner, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AuroraControl.corner, style: .continuous)
                            .stroke(Color.white.opacity(0.16), lineWidth: 1.5)
                    )
                    .onTapGesture { copyURL() }
                }

                if let error {
                    AuroraErrorLabel(error)
                }

                Button {
                    retry()
                } label: {
                    Text(isChecking ? "Checking…" : "I've done that — retry")
                }
                .buttonStyle(AuroraPrimaryButtonStyle(isLoading: isChecking))
                .disabled(isChecking)

                Button("Change server") { router.resetToServerSetup() }
                    .buttonStyle(AuroraGhostButtonStyle())
                    .frame(maxWidth: .infinity)
            }
            .padding(22)
            .auroraGlass(cornerRadius: 24, emphasized: true)
            .animation(.easeInOut(duration: 0.2), value: error)
        }
        .navigationBarBackButtonHidden()
    }

    private var host: String? {
        let url = AuthService.shared.serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        if let parsed = URL(string: url), let host = parsed.host, !host.isEmpty { return host }
        return url.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    private func copyURL() {
        #if os(iOS)
        UIPasteboard.general.string = AuthService.shared.serverUrl
        #endif
    }

    /// Re-probe the current server. If it's now set up, pop back to the login
    /// screen (this view sits on top of `LoginView` in the `.needsLogin`
    /// stack). Otherwise surface a gentle nudge.
    private func retry() {
        guard !isChecking else { return }
        isChecking = true
        error = nil
        Task {
            do {
                let status = try await AuthService.shared.checkServer(url: AuthService.shared.serverUrl)
                await MainActor.run {
                    isChecking = false
                    if status.needsSetup {
                        error = "This server still needs to be set up in a browser."
                    } else {
                        router.goBack()
                    }
                }
            } catch {
                await MainActor.run {
                    isChecking = false
                    self.error = "Couldn't reach the server. Check it's running and try again."
                }
            }
        }
    }
}
#endif
```

- [ ] **Step 2: Swap the route in `Route.swift`**

In `iosApp/iosApp/Navigation/Route.swift`, replace `case setup` (line 8) with:

```swift
    case serverNeedsSetup
```

- [ ] **Step 3: Point the view model at the new route**

In `iosApp/iosApp/Screens/Auth/ServerSetupViewModel.swift`, in `connect(...)`, replace:

```swift
                if status.needsSetup {
                    router.authState = .needsLogin
                    router.navigate(to: .setup)
                } else {
                    router.authState = .needsLogin
                }
```
with:
```swift
                router.authState = .needsLogin
                if status.needsSetup {
                    router.navigate(to: .serverNeedsSetup)
                }
```

- [ ] **Step 4: Update `ContentView` route switches (platform-safe)**

In `iosApp/iosApp/ContentView.swift`, replace the whole `destinationView(for:)` method:

```swift
    @ViewBuilder
    private func destinationView(for route: Route) -> some View {
        switch route {
        case .serverNeedsSetup:
            #if os(tvOS)
            EmptyStateView(
                icon: "gearshape.2",
                title: "Finish setup in your browser",
                subtitle: nil
            )
            .siloBackground()
            #else
            ServerNeedsSetupView(router: router)
            #endif
        case .signup:
            #if os(tvOS)
            EmptyStateView(
                icon: "person.badge.plus",
                title: "Sign up from a phone or the web",
                subtitle: nil
            )
            .siloBackground()
            #else
            SignupView(router: router)
            #endif
        case .login:
            loginRoot
        case .serverSetup:
            #if os(tvOS)
            TVServerSetupView(router: router)
            #else
            ServerSetupView(router: router)
            #endif
        default:
            EmptyStateView(
                icon: "hammer.fill",
                title: "Coming Soon",
                subtitle: "This screen is under construction."
            )
            .siloBackground()
        }
    }
```

Then in `profileFlowDestination(for:)`, replace the `.setup` arm:

```swift
        case .setup:
            SetupView(router: router)
```
with:
```swift
        case .serverNeedsSetup:
            #if os(tvOS)
            EmptyStateView(icon: "gearshape.2", title: "Finish setup in your browser", subtitle: nil)
                .siloBackground()
            #else
            ServerNeedsSetupView(router: router)
            #endif
```

And gate the `.signup` arm in `profileFlowDestination` the same way (it currently reads `case .signup: SignupView(router: router)`):
```swift
        case .signup:
            #if os(tvOS)
            EmptyStateView(icon: "person.badge.plus", title: "Sign up from a phone or the web", subtitle: nil)
                .siloBackground()
            #else
            SignupView(router: router)
            #endif
```

- [ ] **Step 5: Delete the Create-Admin view and view model**

```bash
cd iosApp/iosApp
git rm Screens/Auth/SetupView.swift Screens/Auth/SetupViewModel.swift
```

Note: `AuthService.setupAdmin(...)` is now unused but is left in place (the spec keeps `AuthService` untouched). It can be removed in a later cleanup if desired.

- [ ] **Step 6: Confirm no stragglers**

Run: `cd iosApp && rg -n "SetupView|SetupViewModel|Route\.setup|case \.setup|navigate\(to: \.setup\)|createAdmin" iosApp`
Expected: **no matches** in `iosApp/` app sources except (a) `setupAdmin` in `AuthService.swift`, and (b) pairing-state `.setup` in `Pairing/…` and `PairingProtocol.swift` (unrelated — leave them). If any `Route`/`ContentView`/view-model reference to the old admin `.setup` remains, fix it.

- [ ] **Step 7: Regenerate and build all three targets**

```bash
cd iosApp
xcodegen generate
xcodebuild build -project Silo.xcodeproj -scheme Silo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Silo.xcodeproj -scheme SiloTV -destination 'platform=tvOS Simulator,name=Apple TV' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Silo.xcodeproj -scheme SiloMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
Expected: `** BUILD SUCCEEDED **` for all three.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Replace iOS Create-Admin with a 'finish setup in your browser' screen"
```

---

## Task 9: Final integration & simulator verification

**Files:** none (verification only)

- [ ] **Step 1: Clean build of every scheme**

```bash
cd iosApp
xcodebuild clean build -project Silo.xcodeproj -scheme Silo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO
xcodebuild clean build -project Silo.xcodeproj -scheme SiloTV -destination 'platform=tvOS Simulator,name=Apple TV' CODE_SIGNING_ALLOWED=NO
xcodebuild clean build -project Silo.xcodeproj -scheme SiloMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
Expected: `** BUILD SUCCEEDED **` for all three.

- [ ] **Step 2: Run the iOS app in the simulator and walk the flow**

Boot the iPhone simulator, install, and launch the `Silo` scheme. Verify visually:
- **Server setup**: plum Aurora backdrop with drifting ribbons + starfield, `SILO.` wordmark, "Step 01 — Connect" gold eyebrow, single glass form, "Advanced options" collapsed by default; expanding reveals Protocol + Port. Enter a known dev server and connect.
- **Sign in**: "Step 02 — Sign in" + "Welcome back" + host label; username/password with a working eye toggle; keyboard pushes the focused field into view (form scrolls); "Create account" appears only when signup is enabled; "Change server" returns to server setup.
- **Profile**: "Who's watching?" over the Aurora backdrop; tiles tappable; a PIN profile presents the PIN sheet; "Switch server"/"Sign out" chips work.
- **Sign up** (if the dev server allows it): all fields render and scroll; create-account works.
- **Server needs setup**: point the app at a fresh/unconfigured server → the gear screen appears (not a Create-Admin form); "Change server" works; "retry" re-probes.

Reference the `silotv-simulator-debugging` memory for boot/install/sign-in mechanics (the same `xcrun simctl` patterns apply to the iOS simulator; use local dev credentials such as `<username>` / `<password>`).

- [ ] **Step 3: Verify Reduce Motion**

In the simulator, enable Settings → Accessibility → Motion → Reduce Motion, relaunch, and confirm the Aurora backdrop renders static (no ribbon drift / star twinkle) — `AuroraBackdrop`'s animations already honor `accessibilityReduceMotion`; confirm nothing in the reskin reintroduced motion.

- [ ] **Step 4: Final commit (if any verification fixes were made)**

```bash
git add -A
git commit -m "Polish iOS Aurora first-run flow after simulator verification"
```

---

## Self-Review (completed during planning)

**Spec coverage:** Server setup (T3) ✓ · Sign-in password-first (T5) ✓ · Profile (T7) ✓ · Sign-up (T6) ✓ · Server-needs-setup replacing Create-Admin (T8) ✓ · Advanced disclosure iOS (T3) + tvOS (T4) ✓ · Aurora promoted to shared code with iOS field (T1, T2) ✓ · Reduce Motion (T9) ✓ · "no TV footnote on iOS" — N/A (current iOS `ServerSetupView` has none; the reskin doesn't add one) ✓.

**macOS:** Because `SiloMac` compiles these views but excludes `tvOS/**`, Aurora is moved to `DesignSystem/Aurora/` (T1) and every reskinned view + the form kit is `#if !os(tvOS)`; `ContentView` route arms are platform-gated (T8). macOS inherits the reskin and is built in every task — it is not separately *designed*, only kept green.

**Naming consistency:** `AuroraTextField` parameters (`label`, `text`, `placeholder`, `focus`, `equals`, `isSecure`, `showsRevealToggle`, `contentType`, `keyboard`, `submitLabel`, `onSubmit`) are used identically in T3/T5/T6. `viewModel.showsAdvancedOptions` (existing on `ServerSetupViewModel`) drives both the iOS (T3) and tvOS (T4) disclosures. `Route.serverNeedsSetup` is defined (T8 S2), navigated to (S3), and handled (S4) consistently.

**Confirm-before-building (carried from the spec):** removing Create-Admin assumes the web admin is the canonical first-account bootstrap and the iOS app is never the only way to set up a fresh server.
