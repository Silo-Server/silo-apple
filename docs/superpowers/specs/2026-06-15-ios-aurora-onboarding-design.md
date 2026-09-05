# iOS First-Run Flow → Aurora — Design Spec

- **Date:** 2026-06-15
- **Status:** Approved (design); ready for implementation planning
- **Platforms:** iOS (iPhone + iPad). tvOS receives one shared change (see §7).
- **Related:** `docs/tvos-onboarding/` (Aurora mockups), tvOS Aurora flow shipped on `main`.

## 1. Summary

The tvOS first-run flow was recently redesigned in the "Aurora" visual language
(plum night backdrop with starfield + aurora ribbons, warm off-white ink, a
single champagne-gold accent, liquid-glass panels, cream-pill buttons). This
project brings that language to the **iOS** server-setup → sign-in → profile
flow, adapted for portrait, touch, and the software keyboard.

This is a **view-layer reskin plus one flow change**. The auth/session logic,
networking, persistence, and the `AppRouter` state machine are **not** changing.

## 2. Goals / Non-Goals

**Goals**
- Reskin the iOS auth screens to match the shipped tvOS Aurora language.
- Adapt the TV's 16:9 two-column layouts to portrait single-column for phone.
- Make iOS sign-in **password-first** (the phone is the device; no QR).
- Share one Aurora design system across iOS and tvOS.
- Remove the in-app Create-Admin screen from iOS; replace with a graceful
  "finish setup in your browser" state.
- Simplify server entry: hide Protocol + Port behind an "Advanced options"
  disclosure (also applied to tvOS).

**Non-Goals**
- No changes to `AuthService`, `ServerRegistry`, `TokenStore`, view models, or
  the `AppRouter` auth-state machine.
- No server API changes.
- No changes to companion pairing behavior (the iOS pairing card overlay stays).
- macOS is not specifically designed here (see §9).
- No new QR / device-login UI on iOS.

## 3. Aurora design language (source of truth)

Tokens and components are defined in the shipped tvOS code and must be reused:

- `iosApp/iosApp/DesignSystem/Aurora/AuroraStyle.swift`
- `iosApp/iosApp/DesignSystem/Aurora/AuroraBackdrop.swift`

**Palette**
- Ink (primary text): `#F3EFE9`; secondary = ink @ 0.62; tertiary = ink @ 0.40
- Accent (champagne gold): `#F3D3A0`
- Night gradient: top `#1C1329` → mid `#0D0A17` → bottom `#070509`
- Glass tint: `#171019` @ 0.5 over `.ultraThinMaterial`
- Primary button: cream gradient `#FDF7EC` → `#F1E3CD`, ink `#20160A`
- Active field: fill `#F4EEE2`, ink `#1A1206`, placeholder `#4A4035`

**Components** (`AuroraStyle.swift`)
- `AuroraEyebrow` — gold 46×1 hairline + monospaced caps label (tracking 3.5)
- `AuroraGlassPanel` / `.auroraGlass(...)` — material + plum tint + gradient
  hairline border + top sheen + optional gold halo (`emphasized`)
- `AuroraPrimaryButtonStyle` — cream pill; focus = white stroke + gold glow + scale
- `AuroraGhostButtonStyle` — tertiary text/button
- `AuroraStepRow` — numbered gold circle + text
- `AuroraSegment` — equal-width chip (used for protocol)
- `AuroraInputField` — controlled-overlay text field (tvOS-specific; see §5)

**Backdrop variants** (`AuroraBackdrop.swift`: rotation, centerY, hue, intensity)
- `.server` (-9, 0.32, -22°, 0.55) · `.signIn` (-14, 0.22, +8°, 0.86)
- `.profile` (-10, 0.27, -16°, 0.66) · `.connecting` (-6, 0.30, -6°, 0.70)
- `.welcome` (-12, 0.24, 0°, 0.92)

Each iOS screen uses the matching variant so the flow feels related but distinct,
exactly as on tvOS.

## 4. Code organization

**Decision: keep the Aurora design system in shared code** (one source of truth).

- Keep `AuroraStyle.swift` and `AuroraBackdrop.swift` in
  `iosApp/iosApp/DesignSystem/Aurora/` with no `#if os(tvOS)` gate.
- Update `iosApp/project.yml` source paths and target membership so the files
  build into **both** the `Silo` (iOS) and `SiloTV` targets, then rerun
  `xcodegen generate`.
- **Shared unchanged:** color tokens, `AuroraBackdrop` (+ variants/scrim/
  starfield), `AuroraGlassPanel`, `AuroraEyebrow`, `AuroraPrimaryButtonStyle`,
  `AuroraGhostButtonStyle`, `AuroraStepRow`, `AuroraSegment`.
- **Platform-dependent metrics:** the tvOS components hardcode TV-scale sizes
  (eyebrow 17pt, button 24pt, field 26pt, control height 72). Factor these into a
  small metrics source (e.g. `AuroraControl` + button/eyebrow sizes) that resolves
  to iOS-appropriate values (≈ field height 52, body sizes one ramp smaller) and
  prefers Dynamic Type where practical.

This keeps the system DRY; the rejected alternative (duplicate an iOS Aurora copy)
starts faster but creates two drifting sources of truth.

## 5. iOS-specific text field

The tvOS `AuroraInputField` renders a visible `Text` overlay plus a near-invisible
real `TextField` to defeat the tvOS focus "platter." iOS has no such platter and
needs genuine inline editing.

**iOS field requirements:**
- Real editable `TextField` / `SecureField` with native caret, selection, and
  text-cursor behavior, styled with the Aurora chrome (cream fill + gold ring when
  `isFocused`; translucent white @ resting).
- Secure entry with a show/hide eye toggle (trailing button).
- Correct `textContentType` / `keyboardType` per field (URL, username, email
  address, password, one-time-code where relevant), autocorrect/autocap disabled
  for identifiers.

Share the *styling* with tvOS (same fill/border/focus tokens); fork the field
*body* per platform (e.g. a shared `AuroraFieldChrome` style + an `AuroraTextField`
iOS view).

## 6. Screens

Each screen = backdrop variant + centered `SILO.` wordmark + gold eyebrow + a
heading block + a liquid-glass form/content card.

### 6.1 Server setup — `ServerSetupView`
- Backdrop `.server`. Eyebrow "STEP 01 — CONNECT". Title "Add your server".
- Glass form: **Server address** field + **Advanced options** disclosure
  (collapsed by default) + **Connect** button.
- Advanced (expanded): **Protocol** segmented control (Auto / HTTPS / HTTP) +
  **Port** field. Collapsed by default because candidate-probing autodetects
  scheme + default ports (`ServerSetupViewModel`).
- Connecting state = inline button loading state (no dedicated screen).
- **No** "Setting up a TV?" footnote on iOS (the companion pairing card already
  auto-overlays via `CompanionPairingCardModifier`).

### 6.2 Sign in — `LoginView` (password-first)
- Backdrop `.signIn`. Eyebrow "STEP 02 — SIGN IN". Title "Welcome back" + host
  label (active server URL).
- Glass form: **Username** + **Password** (with eye toggle) + **Sign in**.
- Secondary links: **Create account** (only when server signup is enabled) ·
  **Change server**.
- No QR / device-login on iOS.

### 6.3 Profile selection — `ProfileSelectionView` (iOS branch)
- Backdrop `.profile` — iOS converges from its current radial-gradient onto the
  shared Aurora backdrop.
- Title "Who's watching?" + "Select your profile".
- Adaptive grid of rounded-square avatar tiles + names; PIN-locked tiles show a
  lock badge; an **Add Profile** tile.
- Tap a tile to select (selection ring). PIN profiles present `PINEntryView`
  (iOS sheet). Top utility chips: **Switch server** · **Sign out**.

### 6.4 Sign up — `SignupView`
- Backdrop `.signIn` (warm; shared with sign-in). Eyebrow "CREATE ACCOUNT".
  Title "Create your account" + host label.
- Glass form in a `ScrollView`: **Username**, **Email**, **Password**,
  **Confirm password**, **Invite code** (when required) + **Create account**.
- Secondary link: **Back to sign in**.

### 6.5 Server needs setup (new) — replaces `SetupView`
- Shown when `AuthService.checkServer(...)` reports `needsSetup`.
- Backdrop `.server` (continuity with the connect step) + gold gear/server icon.
  Title "Finish setup in your browser".
- Body: the server has no account yet; open it in a browser to create the first
  account, then return to sign in.
- A monospaced **URL pill** (the server address) with a copy button.
- Buttons: **Retry** (re-probe; on success → `.needsLogin`) · **Change server**.

## 7. Cross-platform change: Advanced disclosure on tvOS

Apply the same "Protocol + Port behind Advanced options" collapse to
`TVServerSetupView` so both clients behave consistently. The manual-entry card
shows only the address field + Connect by default, with an Advanced disclosure
that reveals the protocol segments + port (focus-managed for the remote).

## 8. Portrait / touch / keyboard / iPad

- Single-column centered layout. tvOS `focusSection` zones become natural tap
  order; remove tvOS focus-forcing where it does not apply.
- Forms live in a `ScrollView`; the focused field scrolls clear of the keyboard;
  primary action stays reachable.
- Active-field cream fill is driven by `isFocused` (first-responder on tap).
- iPad / landscape / regular width: center the glass card at ~480pt max width with
  additional vertical breathing room; the backdrop fills the screen.
- Full Aurora motion (starfield + ribbons). Honor **Reduce Motion** → static
  backdrop (gradient + bloom, no animation). Consider static under Low Power Mode.

## 9. What stays untouched / out of scope

- `AuthService`, `ServerRegistry`, `TokenStore`, `SiloAPI`, `HTTPClient`.
- `AppRouter` auth-state machine and view models (`ServerSetupViewModel`,
  `LoginViewModel`, `SignupViewModel`, `ProfileSelectionViewModel`,
  `QRLoginViewModel`).
- Companion pairing (`Pairing/…`, `CompanionPairingCardModifier`) — only the
  static server-screen footnote is removed; the auto-overlay card is unchanged.
- macOS: if `SiloMac` reuses the iOS views it inherits Aurora automatically;
  verify separately. Not specifically designed in this spec.

## 10. Flow / routing change

- Remove `SetupView` and stop routing to the `.setup` case on iOS.
- In the path where `checkServer` returns `needsSetup`, route to the new
  "server needs setup" screen instead of Create-Admin.
- Confirm `Route` / `AppRouter` cleanup leaves no dangling `.setup` references on
  iOS; tvOS already has no Create-Admin (verify parity).

## 11. Coordination / risks

- **Server:** no changes required; `needsSetup` is already reported.
- **Android:** the Advanced-options collapse is a client UX choice worth mirroring
  on the Android clients later for consistency (non-blocking; note for that team).
- **Build:** moving Aurora files requires `project.yml` edits + `xcodegen
  generate`; verify both `Silo` and `SiloTV` compile.
- **Confirm before building:** removing Create-Admin assumes the web admin is the
  canonical first-account bootstrap and the iOS app is never the *only* way to set
  up a brand-new server.

## 12. Acceptance criteria

- iOS Server, Sign-in, Profile, and Sign-up screens render in the Aurora language
  matching tvOS tokens/components, in portrait, with working keyboard handling.
- Server screen hides Protocol/Port by default; Advanced reveals them; autodetect
  still connects typical configs. Same behavior verified on tvOS.
- Sign-in is username/password only on iOS; no QR UI.
- Pointing iOS at a fresh, unconfigured server shows the "finish setup in your
  browser" screen (not a Create-Admin form); Retry recovers after web setup.
- Aurora design-system files compile into both iOS and tvOS targets from one
  shared location.
- Reduce Motion yields a static backdrop.
- No regressions in auth, multi-server switching, profile selection, PIN entry,
  or companion pairing.
