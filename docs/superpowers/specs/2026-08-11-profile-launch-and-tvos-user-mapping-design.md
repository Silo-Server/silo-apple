---
title: Silo Profile Launch Choice and Apple TV User Mapping
description: Implementation-ready design for automatic or required profile selection and per-user tvOS profile memory.
date: 2026-08-11
tags:
  - silo
  - apple
  - profiles
  - design-spec
---

# Profile Launch Choice and Apple TV User Mapping — Design Spec

- **Date:** 2026-08-11
- **Status:** Implemented; simulator-validated
- **Repo:** `silo-apple` (iOS, iPadOS, macOS, tvOS, and the tvOS Top Shelf extension)
- **Server:** No change required
- **Android:** Parity follow-up recommended; not part of this implementation
- **Exploration baseline:** `silo-apple` `fdb5225`; `silo-server` `origin/main`
  `2dc7d5e36`; `silo-android` `origin/main` `3efdbd90`

### Implementation validation

- Focused policy, identity, migration, and session-persistence tests: 14 passed.
- Full iOS simulator suite: 1,273 passed; the same 8 failures reproduce on the untouched
  `fdb5225` baseline.
- Clean iOS, tvOS, and macOS builds passed.
- Signed iOS simulator flow passed for Ask Every Time, two Automatic cold launches, interrupted
  explicit switching, Last Used presentation, and deep-link gating/draining.
- Signed tvOS simulator flow passed for the setting/focus UI, Ask Every Time cold launch, and the
  current-user/user-independent-keychain simulated entitlements in both the app and Top Shelf.
- Physical Apple TV validation remains required for switching between multiple real tvOS users;
  the simulator cannot establish that OS-level isolation boundary.

## 1. Summary

Give people an explicit choice for what happens when a new Silo app session starts:

1. **Automatic** — use the last successfully selected Silo profile and go directly to content.
2. **Ask Every Time** — show “Who’s watching?” and require a profile selection before entering
   the authenticated app.

Automatic is the default for existing and new installs, preserving today's behavior. “Ask Every
Time” applies to a **cold process launch**, not every foreground transition. Returning from Control
Center, multitasking, or a temporary background state keeps the current profile and playback
session. Choosing **Switch Profile** always opens the picker immediately.

On tvOS, Automatic integrates with Apple TV system users. Each Apple TV user remembers their own
Silo profile, while the household signs in to the Silo server only once. This uses Apple's current
per-user storage model rather than the deprecated APIs that manually map Apple TV user identifiers
to app profile identifiers.

The feature is client-owned. The server already supplies everything required:

- account-authenticated `GET /api/v1/profiles` works before a profile is active;
- PIN-less profiles can be selected locally by setting `X-Profile-Id` state;
- `POST /api/v1/profiles/{id}/verify-pin` returns the profile verification token needed for a
  protected profile;
- the profile token is bound to the account session, profile, and access-policy revision.

No server issue should be opened for this design.

## 2. Problem

Today `ContentView.checkInitialState()` routes directly to `.authenticated` whenever the active
server has an access token and `AuthService.profileId` is non-nil. `ServerRegistry.ServerEntry`
persists that profile ID per server, and `TokenStore` persists the corresponding profile token in
Keychain. As a result, every cold launch silently restores the previous profile.

The current persistence model also uses one field for two different meanings:

- **active profile** — the identity attached to requests right now;
- **last-used profile** — a convenience hint that may be shown in the picker or restored later.

Those concepts must be separated. Leaving `profileId` populated merely to remember a choice would
continue attaching that profile to requests and would bypass “Ask Every Time.” For PIN-protected
profiles, leaving the profile token active would also defeat the intended re-verification boundary.

tvOS adds another constraint: multiple Apple TV system users can share one physical device. Silo
should remember a different app profile for each system user without asking every household member
to authenticate the same Silo account again.

## 3. Goals and Non-Goals

### Goals

1. Offer **Automatic** and **Ask Every Time** launch behavior on every Apple client.
2. Preserve Automatic as the migration/default behavior.
3. Keep “last used” separate from the active request identity.
4. Make explicit profile switching and account replacement safe across cached data, in-flight
   requests, PIN tokens, Top Shelf, deep links, and diagnostics.
5. On tvOS 16+, remember the Silo profile separately for each Apple TV system user while sharing
   the Silo account/server sign-in.
6. Preserve offline startup for Automatic mode when cached content and credentials are usable.
7. Never let Top Shelf or a deep link bypass a required profile choice.

### Non-Goals

- No server schema, endpoint, or settings-manifest change.
- No cloud-synced launch preference. This is a local device/viewer policy.
- No manual map from deprecated `TVUserIdentifier` values to Silo profile IDs.
- No changes to profile CRUD, household permissions, or PIN rules.
- No timeout-based “lock after N minutes” in v1. That is a separate privacy-lock feature.
- No Android implementation in this repository.

## 4. Product Decisions

### 4.1 Launch choices

Use a two-value setting:

| Setting | Cold process launch | Resume within same process | Explicit Switch Profile |
|---|---|---|---|
| **Automatic** | Restore the last valid profile | Keep current profile | Show picker |
| **Ask Every Time** | Clear/ignore active profile proof and show picker | Keep current profile | Show picker |

The setting label is **Profile at Launch**. Values:

- **Automatic** — “Use the last profile selected on this device.”
- **Ask Every Time** — “Show Who’s Watching when Silo starts.”

On tvOS, the Automatic helper changes to:

> Use the profile selected for the current Apple TV user.

If the OS cannot retain a current-user preference (for example, an ephemeral user context), Silo
must fall back to the picker. A normal single-user Apple TV must still support the explicit
Automatic choice; validate `TVUserManager.shouldStorePreferencesForCurrentUser` on a physical
tvOS 26 device and use a device-wide fallback record only if the OS does not provide a persistent
current-user store in that configuration.

### 4.2 What “launch” means

“Ask Every Time” is evaluated once during a cold process start in
`ContentView.checkInitialState()`. It does not trigger on every `.active` scene transition.

Reasons:

- tvOS Control Center, iOS interruptions, and normal backgrounding should not throw away playback
  or navigation state;
- clearing profile identity during every foreground transition would race background writes,
  push handling, diagnostics, and the player;
- Apple TV system-user changes terminate and relaunch a Runs-as-Current-User app, so the next
  system user still receives the correct cold-start decision.

### 4.3 PIN-protected profiles

- **Automatic:** a previously verified, still-valid profile token may be restored. This matches
  today's behavior and makes Automatic a real opt-in bypass of repeated PIN entry on that local
  user context.
- **Ask Every Time:** selecting a protected profile requires its PIN during every cold app session.
  The previous profile token must be cleared or made unavailable before the picker becomes active.
- Settings copy for Automatic should state that anyone able to use this device/Apple TV user can
  open the remembered Silo profile without entering its PIN again.

### 4.4 Default focus and remembered hints

The picker may focus/highlight the last-used profile, but it must not select it until the person
presses the profile tile. Add a visible “Last used” marker and an equivalent accessibility value;
do not communicate this state through focus color alone.

### 4.5 Setting changes

- Changing **Automatic → Ask Every Time** affects the next cold launch. It does not eject the
  person from the current session.
- Changing **Ask Every Time → Automatic** records the currently active profile as the automatic
  choice for the active server.
- The launch setting remains after sign-out. The remembered profile mapping does not.

## 5. State Model

Introduce an explicit local policy store, tentatively `ProfileLaunchPreferences`:

```swift
enum ProfileLaunchBehavior: String, Codable, CaseIterable {
    case automatic
    case askEveryLaunch
}

struct RememberedProfile: Codable, Equatable {
    let profileID: String
    let requiredPINAtSelection: Bool
}

struct ProfileLaunchState: Codable, Equatable {
    var behavior: ProfileLaunchBehavior
    var rememberedByServerID: [String: RememberedProfile]
    var selectionRequiredServerIDs: Set<String>
}
```

The exact serialized shape may use arrays instead of a Codable `Set`, but the semantics are fixed:

- `behavior` is local to the current device user and defaults to `.automatic`;
- the remembered profile is keyed by Silo `serverId`;
- `requiredPINAtSelection` lets offline startup know whether a missing profile token is a blocker;
- `selectionRequiredServerIDs` prevents an explicit **Switch Profile** action from being undone by
  Automatic if the app is killed while sitting on the picker.

### 5.1 Three separate state domains

1. **Account session (shared on tvOS):** server registry plus access/refresh credentials.
2. **Remembered viewer preference:** launch behavior plus last-used profile per server.
3. **Active profile session:** profile ID plus matching profile token attached to requests now.

No field may serve two of these roles.

### 5.2 Account-boundary rule

Remembered profile mappings are only valid for the account session in which they were selected.
Any credential replacement for the same server URL must clear that server's remembered and active
profile state before installing the new account tokens. This extends the existing
`preservingProfile: false` account-replacement rule; a URL alone is not an account identity.

Normal access-token refresh does not clear the mapping because it preserves the same server account
and session ownership.

## 6. Launch State Machine

Replace the current “access token + profile ID = authenticated” shortcut with a policy resolver.

```text
No saved server
  -> Server Setup

Saved server, no account access token
  -> Login

Account session exists
  -> Ask Every Time?
       yes -> deactivate profile, preserve remembered hint -> Profile Picker
       no  -> explicit selection still pending?
                yes -> Profile Picker
                no  -> restorable remembered profile?
                         yes -> activate atomically -> Home
                         no  -> Profile Picker
```

### 6.1 Restorable profile rules

Automatic may restore only when all applicable conditions hold:

- a remembered profile exists for the active server;
- no explicit switch is pending;
- if it was PIN-protected, a matching stored profile token exists in the current user context;
- the account session has not been replaced;
- no temporary remote-playback identity owns request authentication.

The cached profile list should be used to reject an obviously deleted profile without delaying
startup. A network `GET /profiles` reconciliation may run through the existing startup prefetch.
Do not make a healthy Automatic launch wait on the network solely to validate a local hint.

If the first server response reports that the profile no longer exists or its verification token is
no longer valid, clear only the active/remembered profile state and route to the picker. Do not sign
the account out or send the person to the login screen.

### 6.2 Atomic activation/deactivation

Profile ID and profile token are one request identity. Add a single transition API rather than
continuing independent writes such as `setProfileToken` followed by `setProfileId`:

```swift
func activateProfile(
    profileID: String,
    profileToken: String?,
    expectedAccount: RefreshAccountIdentity
) async throws

func deactivateProfile(
    reason: ProfileDeactivationReason,
    preserveRememberedProfile: Bool
) async
```

Both operations must use the existing HTTP identity-transition barrier, cancel stale in-flight
requests, update the profile ID/token as one logical commit, clear profile-scoped caches, update
Top Shelf mirrors, and then publish observable identity changes. A temporary remote-playback scope
must fail closed rather than writing into the overlay.

## 7. User Flows

### 7.1 First sign-in

1. Sign in to a server account.
2. Show the existing profile picker.
3. Select a profile (and verify PIN when required).
4. Save it as last used and enter Home.
5. Automatic remains the default unless changed in Settings.

### 7.2 Automatic cold launch

1. Load the shared account session and current-user profile preferences.
2. Restore the current user's last profile for the active server.
3. Enter Home without showing the picker.
4. Reconcile profile existence through normal startup prefetch.

### 7.3 Ask Every Time cold launch

1. Load the account session.
2. Deactivate the request profile and its token while retaining the remembered hint.
3. Warm the profile list and show the picker after the splash.
4. Default focus to the last-used tile.
5. Require PIN entry for protected profiles.

### 7.4 Explicit Switch Profile

1. Flush pending profile/device setting writes under the old immutable profile scope.
2. Mark the active server as `selectionRequired`.
3. Deactivate profile identity but preserve the last-used hint.
4. Clear profile-scoped caches, close/rebind realtime consumers, and show the picker.
5. Clear `selectionRequired` only after a new profile activation commits successfully.

The setting, top menu, and account-card switch actions must all call one coordinator method instead
of each writing `AuthService.shared.profileId = nil` directly.

### 7.5 Server switch

- Resolve behavior and remembered profile independently for the destination server.
- Automatic may enter Home when that server/account/profile record is restorable.
- Ask Every Time or a pending explicit selection routes to the picker.
- Never carry a profile token from the previous server.

### 7.6 Sign-out and account replacement

- Clear the active and remembered profile for the affected server/account.
- Clear its profile token(s), caches, Top Shelf identity, and pending-selection marker.
- Preserve the local `ProfileLaunchBehavior` setting.
- Removing the server also removes every launch record keyed by that server ID.

### 7.7 Profile deletion

If the deleted profile is active or remembered, clear both references and remain on/return to the
picker. Do not automatically select a sibling profile.

### 7.8 Offline behavior

- **Automatic:** open cached content when the remembered ID and any required cached profile token
  are available.
- **Ask Every Time, PIN-less profile:** selecting from a cached profile list may proceed offline.
- **Ask Every Time, protected profile:** verification requires the server; show a focused error and
  keep the person on the picker. Do not reuse the previous token as a silent fallback.
- If no cached profile list exists, show the existing retryable error state.

## 8. tvOS System-User Integration

### 8.1 Use the modern entitlement model

Add this entitlement to both the `SiloTV` app and `SiloTVTopShelf` extension targets:

```xml
<key>com.apple.developer.user-management</key>
<array>
    <string>runs-as-current-user-with-user-independent-keychain</string>
</array>
```

Apple's current model launches the app as the active Apple TV user and automatically separates
that user's preferences and normal Keychain data. The old `currentUserIdentifier`,
`presentProfilePreferencePanel`, `TVAppProfileDescriptor`, and explicit user-to-profile mapping
APIs are deprecated and must not be introduced.

References:

- [Mapping Apple TV users to app profiles](https://developer.apple.com/documentation/tvservices/mapping-apple-tv-users-to-app-profiles)
- [User Management Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.user-management)
- [`kSecUseUserIndependentKeychain`](https://developer.apple.com/documentation/security/ksecuseuserindependentkeychain)
- [WWDC22: Support multiple users in tvOS apps](https://developer.apple.com/videos/play/wwdc2022/110384/)

### 8.2 Storage classification

Adding Runs as Current User changes the meaning of all local persistence. Split it deliberately:

| Data | tvOS storage audience | Why |
|---|---|---|
| Server entries and shared account identity | User-independent | Every Apple TV user should see the signed-in household account |
| Access and refresh tokens | User-independent Keychain | Avoid a full Silo login for every Apple TV user |
| Physical Apple device ID | User-independent Keychain | The same Apple TV remains one server-side device |
| Active server preference | Current Apple TV user | Different users may prefer different saved servers |
| Launch behavior and remembered profile map | Current Apple TV user | This is the system-user-to-Silo-profile association |
| Active profile ID | Current Apple TV user | Prevent cross-user request identity |
| Profile verification token | Current Apple TV user Keychain | PIN proof belongs to that viewer, not the household account globally |
| Top Shelf active profile and status | Current Apple TV user/App Group | Home Screen content must match the active Apple TV user |

`SharedKeychain` should gain an explicit audience, for example:

```swift
enum KeychainAudience {
    case currentUser
    case userIndependent
}
```

On tvOS, `.userIndependent` adds `kSecUseUserIndependentKeychain: kCFBooleanTrue` to add, update,
read, and delete queries. On iOS and macOS, the audience parameter has no behavioral effect.

Do not mark every existing keychain item as user-independent. In particular, making the one
per-server `profileToken` slot user-independent would let two Apple TV users mapped to different
protected profiles overwrite each other's proof.

### 8.3 Server registry split

The current `ServerEntry.profileId` prevents a clean storage split because server metadata is
household-shared while the profile association is current-user-specific. Refactor the registry so:

- shared server entries contain `id`, `url`, `fetchedName`, and `lastUsedAt`, but no active profile;
- the current Apple TV user's active-server preference and remembered profile map live in
  `ProfileLaunchPreferences`;
- tvOS stores/backs up the shared server registry in the user-independent Keychain (a small JSON
  generic-password item is sufficient);
- iOS/macOS may continue storing the registry in defaults, but use the same profile-preference
  abstraction so request identity is no longer embedded in `ServerEntry`.

This lets a newly selected Apple TV system user discover the already-signed-in Silo servers, while
still receiving a fresh profile picker until they choose their own mapping.

### 8.4 Top Shelf

The extension must run with the same User Management entitlement and read:

- the current user's active server/profile preference from the per-user App Group;
- the account access token from the user-independent Keychain;
- the current user's profile token from the current-user Keychain.

When **Ask Every Time** is active or `selectionRequired` is set, `ContentProvider` returns no
personalized Top Shelf rows. This avoids exposing the previous viewer's Continue Watching shelf and
prevents a Top Shelf action from looking like it bypassed the picker. The deep link remains queued
until a profile is selected.

### 8.5 System-user switching

Runs-as-Current-User tvOS presents its own transition UI and relaunches the app for the new user.
Silo therefore does not need to observe deprecated user-identifier change notifications. Before
resign/termination, existing scoped settings flushes and exit-sentinel work should complete under
the old immutable profile authority; the new process then resolves the new user's preference.

## 9. Migration and Compatibility

### 9.1 Existing Apple installs

- Seed `ProfileLaunchBehavior.automatic` when no value exists.
- Convert each legacy `ServerEntry.profileId` into that server's remembered profile record.
- Preserve the existing active profile ID/token so the first post-upgrade launch behaves exactly
  as it did before.
- Do not delete legacy state until the new stores have been written and read back successfully.
- Mark the migration with a versioned key and make it idempotent.

### 9.2 tvOS entitlement migration

The entitlement changes which user owns defaults and normal Keychain items, so upgrade behavior
must be proved on a physical Apple TV rather than inferred from a simulator build.

The migration reader should try, in order:

1. the new user-independent registry/account token items;
2. legacy shared-access-group Keychain items without the user-independent query key;
3. the existing App Group/defaults registry as a bootstrap source.

Copy forward only after successful reads and verify the destination before removing a legacy copy.
If an upgrade-installed physical device demonstrates that the old default-user data is not visible
after enabling the entitlement, stop and design a bridge release rather than shipping a silent
sign-out regression.

### 9.3 Personal-team signing

Add the User Management key to `SiloTV.personal.entitlements` and
`TopShelf.personal.entitlements` only if personal provisioning supports it. If it does not, keep a
documented local-signing fallback that compiles/runs without system-user separation; production
entitlements remain authoritative. Never replace the paid-team production entitlements to make a
personal build pass.

## 10. UI Changes

### iOS/iPadOS

- Add **Profile at Launch** to the account section in `IOSSettingsOverview`.
- Present a native picker or menu with Automatic and Ask Every Time.
- Keep the existing account card as the Switch Profile action.

### macOS

- Add the same setting to the existing `SettingsView` account section.
- Use platform-native picker presentation and the same shared state store.

### tvOS

- Add a **Profile at Launch** detail row/picker to the Account or Interface settings pane.
- Copy for Automatic references the current Apple TV user.
- Keep the profile rail row and top-menu action as explicit Switch Profile actions.
- The profile grid focuses the last-used tile when available.

### Accessibility

- Use a native `Button`/`Picker`; no gesture-only controls.
- Announce the current launch mode and helper text to VoiceOver.
- Expose “Last used” as an accessibility value/hint in addition to a visual badge.
- Preserve tvOS focus sections and restore focus to the setting row after dismissing the picker.
- Do not rely on tint, focus color, or avatar artwork alone to communicate selection state.

## 11. Coordination With Existing Subsystems

### Deep links and push notifications

`ContentView` already queues content deep links until `.authenticated`. Preserve that rule: a cold
launch in Ask Every Time waits at the picker, then drains the queued item/play/download action only
after activation succeeds. Invitation links remain account-level and follow their existing flow.

### Caches and settings writes

- Flush pending settings using the old captured profile scope before deactivation.
- Then clear all profile-scoped response, home, item-detail, navigation, requests, AI, diagnostics,
  and realtime state through the existing central cache boundary.
- Do not re-read mutable `AuthService.profileId` at async completion time; carry the captured scope.

### Temporary remote playback identity

The tvOS remote-playback overlay is process-only and must remain separate from the persistent
profile choice. An explicit switch or launch-policy change must not overwrite an active temporary
scope. End/restore the temporary identity through `RemotePlaybackIdentityManager` first, or refuse
the profile mutation until the overlay ends.

### Diagnostics

Deactivation closes diagnostics eligibility before publishing the picker. Activation re-evaluates
eligibility for the newly selected profile. Never attribute startup/picker breadcrumbs to the
remembered-but-not-active profile.

## 12. Server and Android Assessment

### Server

No server work is required:

- profile listing is account-authenticated and available with no active profile;
- profile selection is a client request-header scope, not a server “current profile” field;
- PIN verification already mints durable proof bound to the session/profile/policy revision;
- launch policy and Apple TV system-user identity are local client concerns and should not be sent
  to the server.

Do not add this preference to the cross-platform server settings contract. Syncing it would make a
choice on one Apple TV unexpectedly change iPhone, macOS, or another household TV behavior.

### Android

Android phone and TV currently use the same startup shortcut as Apple: access token plus persisted
profile ID routes directly to Home/Main. A later Android issue should add the same Automatic/Ask
choice and active-vs-remembered separation. Android has no equivalent Apple TV system-user
entitlement, so its TV implementation remains device-wide unless Android/Google TV exposes a
supported app-user storage boundary.

## 13. Implementation Slices

1. **Identity split and policy tests**
   - Add `ProfileLaunchPreferences` and the launch resolver.
   - Add atomic profile activation/deactivation.
   - Migrate Apple client behavior without adding tvOS system-user entitlement yet.

2. **Settings and picker UX**
   - Add the setting on iOS/macOS/tvOS.
   - Centralize Switch Profile.
   - Add last-used focus/badge and accessibility metadata.

3. **Top Shelf and recovery paths**
   - Gate Top Shelf for Ask/pending selection.
   - Handle stale/deleted/unverified remembered profiles as picker recovery, not account logout.
   - Verify deep-link and temporary remote-identity boundaries.

4. **tvOS Runs-as-Current-User storage migration**
   - Add entitlements.
   - Split current-user and user-independent Keychain audiences.
   - Move shared server/account registry state to the user-independent store.
   - Prove upgrade and multiuser behavior on physical hardware.

Keeping the entitlement/storage cut as the final slice prevents a broad persistence migration from
obscuring the core launch-policy behavior during review.

## 14. Testing and Acceptance Criteria

### Unit tests

- Default/migration resolves to Automatic.
- Ask Every Time routes to profile selection despite a stored active profile.
- Ask Every Time preserves the remembered ID but clears active ID/profile token.
- Automatic restores a PIN-less profile offline.
- Automatic restores a protected profile only with matching proof.
- Explicit Switch Profile persists `selectionRequired` across a process restart.
- Successful selection clears `selectionRequired` and updates remembered state atomically.
- Account replacement on the same URL clears old active/remembered profile state.
- Server switch resolves the destination server's independent remembered profile.
- Stale/deleted/unverified profile recovery routes to picker without clearing account tokens.
- Temporary remote identity refuses persistent profile mutation.
- Top Shelf returns no personalized content in Ask/pending mode.
- Keychain audience tests prove access/refresh are user-independent on tvOS while profile tokens are
  current-user-scoped.

### Simulator/build matrix

- iOS simulator: cold Automatic, cold Ask, explicit switch, PIN and PIN-less paths, queued deep link.
- tvOS simulator: focus behavior, settings picker, Top Shelf policy gate, and both launch modes.
- macOS: both launch modes and Settings UI.
- Compile the Top Shelf extension with production and supported personal entitlement variants.

### Required physical Apple TV matrix

Use a signed-in physical device; the Simulator does not prove Apple TV user storage isolation.

1. Upgrade from the current release with an authenticated/PIN-protected profile; verify no surprise
   sign-out and Automatic continuity.
2. Add two Apple TV system users, map each to a different Silo profile, and switch A → B → A.
3. Verify each user reaches only their own remembered profile and Top Shelf rows.
4. Set one user to Ask Every Time and the other to Automatic; verify independent behavior.
5. Verify a protected Ask profile requires PIN again after two terminate/launch cycles.
6. Verify Automatic preserves its protected profile across two terminate/launch cycles.
7. Switch users while Silo is foreground/backgrounded and confirm the old profile never flashes.
8. Verify sign-out/account replacement is shared appropriately while profile mappings clear safely.
9. Verify companion reauthorization on the same server URL does not restore the prior account's
   profile.

### Acceptance criteria

- Existing users remain Automatic after upgrade.
- Ask Every Time reliably lands on “Who’s watching?” after every cold launch.
- Automatic reliably restores the correct last profile.
- tvOS system users can share one Silo account sign-in and keep distinct Silo profiles.
- Protected profile proof never crosses Apple TV users or Silo accounts.
- Explicit Switch Profile cannot be undone by killing/reopening the app before choosing.
- Top Shelf and deep links cannot bypass Ask Every Time.
- No server change is required to ship the feature.

## 15. Affected Files (Reference)

- `iosApp/iosApp/ContentView.swift` — launch policy routing and deep-link gating.
- `iosApp/iosApp/Navigation/AppRouter.swift` — centralized profile-selection transition.
- `iosApp/iosApp/Screens/Profiles/ProfileSelectionViewModel.swift` — atomic commit and remembered
  state updates.
- `iosApp/iosApp/Screens/Profiles/ProfileSelectionView.swift` / `ProfileTile.swift` — last-used
  focus/badge/accessibility.
- `iosApp/iosApp/Screens/Auth/AuthService.swift` — activation/deactivation and account-boundary
  behavior.
- `iosApp/iosApp/Networking/ServerRegistry.swift` — remove profile identity from shared server
  metadata and add tvOS storage backing.
- `iosApp/iosApp/Networking/TokenStore.swift` — atomic profile identity and keychain audiences.
- `iosApp/iosApp/Shared/SharedStorage.swift` — current-user vs user-independent Keychain queries and
  shared preference keys.
- New `iosApp/iosApp/Screens/Profiles/ProfileLaunchPreferences.swift` — local launch behavior,
  remembered mapping, migration, and resolver.
- `iosApp/iosApp/Screens/Settings/IOSSettingsOverview.swift` and `SettingsView.swift` — iOS/macOS
  setting.
- `iosApp/iosApp/tvOS/Screens/Settings/TVSettingsView.swift` and settings components — tvOS setting
  and focus restoration.
- `iosApp/iosApp/tvOS/Navigation/TVMainTabView.swift` — centralized explicit switch action.
- `iosApp/TopShelf/ContentProvider.swift` / `TopShelfHTTPClient.swift` — policy gating and split
  credential reads.
- `iosApp/SiloTV.entitlements`, `iosApp/TopShelf/TopShelf.entitlements`, and supported personal
  variants — User Management capability.
- `iosApp/Tests/` — resolver, migration, identity, Top Shelf, and account-boundary coverage.
