---
title: Silo Multiple Accounts per Server — Design Spec
description: One merged "Who's watching?" picker across every saved server and account, for Apple and Android clients.
date: 2026-11-02
tags:
  - silo
  - apple
  - android
  - accounts
  - profiles
  - design-spec
---

# Multiple Accounts per Server — Design Spec

- **Date:** 2026-11-02
- **Status:** Draft for review
- **Repos:** `silo-apple` (iOS, iPadOS, macOS, tvOS, Top Shelf), `silo-android` (phone, tablet, Android TV)
- **Server:** No behavior change; add tests that pin down push installation handover (§7)
- **Baselines:** `silo-apple` `04807485`; `silo-android` `2fed2fc22`; `silo-server` `origin/main` `56e6f871c`
- **Supersedes:** the unmerged `feat/multiple-accounts-per-server` branch (Apple only, 13 commits)

## 1. Summary

Silo already supports several saved servers with one signed-in account on each, and several
profiles in each account. This spec allows **more than one account on the same server**.
"Who's watching?" keeps showing only the open account's profiles, and a **Change Account**
screen lists every saved account, grouped by server.

Decisions made with the product owner:

1. "Who's watching?" shows the open account's profiles only. Accounts and servers are chosen on a
   separate Change Account screen (§4.1). *Amended 2026-11-02:* this replaces the original
   decision of one merged picker whose tiles were `(server, account, profile)`. The owner changed
   it after reviewing the Roku build on a real TV.
2. The common case is **one person with accounts on several servers**. Several accounts on one
   server must also work, but should not shape the default layout.
3. Signing out of an account **deletes that account's downloads**.
4. Apple and Android ship the same model and UX.

## 2. Terms

| Term | Meaning | Shown to people as |
|---|---|---|
| Server | A Silo server, identified by its verified server ID (fallback: normalized URL) | Server name and logo |
| Account | One login on one server; local key `localAccountId` (a UUID made on this device), plus the server's user ID `serverUserId` once known | Username, only where needed |
| Profile | A profile inside an account (existing feature) | Profile name and avatar |

Use "Account" in management screens and never "User". "User" clashes with Apple TV system users,
and the old branch spent three review rounds on user/account naming.

## 3. Goals and non-goals

**Goals**
- Switch to any profile in any saved account on any saved server with one choice.
- Keep today's experience unchanged for someone with one server and one account.
- Make phone, tablet, Mac, Apple TV and Android TV behave the same.
- Keep each account's local data (downloads, caches, preferences, push) apart from the others.

**Non-goals**
- A device-side "person" that groups accounts across servers. The old branch's "Silo user"
  layer (Choose a User → Choose a Server → Who's watching) caused most of its churn.
- Server-side account linking or a federated identity.
- Changing how profiles, PINs or profile management work inside an account.

## 4. User experience

### 4.1 "Who's watching?" and Change Account

*Amended 2026-11-02 (owner decision after the Roku TV review).* This section replaces the merged
picker. The following are gone from "Who's watching?": per-server sections, the username line on
look-alike tiles, the "Sign in again" badge on tiles, the "Sign in" tile for a server with no
account, and the background refresh of other accounts' profile lists.

**"Who's watching?"** shows only the open account's profiles plus Add, as it does today. It uses the
account's cached profile list when the server can't be reached. PIN-protected profiles ask for the
PIN, as now. The footer has **Change Account** where "Change server" used to be.

**Change Account** is reached from the picker footer and from the avatar menu (§4.3).

```
Apple TV                                              iPhone
┌──────────────────┬────────────────────────────┐   ┌─────────────────────────────┐
│ [mark] Home    ◀ │ (A) alex          Current  │   │ Change Account              │
│ [mark] Lake House│     3 profiles             │   │ [mark] Home                 │
│                  │ (S) sam                    │   │   (A) alex  3 profiles  ✓   │
│                  │     1 profile              │   │   (S) sam   1 profile       │
│                  │ (+) Add an account         │   │   (+) Add an account        │
│ (+) Add server   │     Sign in on Home        │   │ [mark] Lake House           │
└──────────────────┴────────────────────────────┘   │   (A) alex  1 profile       │
                                                    │   (+) Add an account        │
                                                    │ (+) Add a server            │
                                                    └─────────────────────────────┘
```

- **TV (tvOS, Android TV, Roku):**
  - A left rail lists the saved servers, each with its server mark and name. The active server
    comes first, then the rest by last use. **Add server** is at the bottom of the rail.
  - The right pane shows the selected server's accounts. Each card shows the username's initial,
    the username, and a second line with the profile count ("3 profiles" / "1 profile"). Its badge
    is **Current** for the open account and **Sign in again** for expired or revoked credentials.
    The last card is **Add an account**, with the line "Sign in on {server}".
  - Left and Right move between the rail and the pane; Up and Down move within each. A scroll
    affordance shows when either column has more rows.
- **Phone, tablet and Mac:** use the same structure and wording in the platform's usual form.
  Accounts are grouped under a header with the server mark and name. Each group ends in
  **Add an account**, and **Add a server** is at the end. It should be obvious which account is on
  which server, and that there is more to scroll.
- **Server marks** (Change Account and the saved-servers list): the branding `mark_url` image when
  the server has one, otherwise the Silo project icon (silo-branding
  `logo/svg/silo-project-icon.svg`), never the initial.
- **Choosing another account** makes it active on its server and opens its "Who's watching?". The
  picker waits for a choice instead of reopening the remembered profile, except that a single
  profile without a PIN opens directly.
- **Choosing an account that needs to sign in again** opens sign-in with the username filled in.
  Back returns to Change Account.
- **With no account open** (after a sign-out or an expiry) while another account still has a
  session, Change Account is the root screen instead of the picker.

**Add** (on "Who's watching?") is for profiles only. On Apple (*amended 2026-11-03, owner
decision*) it opens profile creation directly, as before multi-account, after the primary
profile's PIN if it has one. Adding an account or a server happens on Change Account, through
**Add an account** ("Sign in to another account on a saved server") and **Add a server**
("Connect this {iPhone/iPad/Mac/Apple TV/device} to another Silo server").

Roku and Android were built with an app-styled Add sheet (Add a profile / Add an account / Add a
server). Whether they follow the Apple change is still open.

If a sign-in turns out to be an account that is already saved, Silo refreshes that account's
credentials instead of adding a duplicate. After a sign-in, an account with one profile and no PIN
opens directly; otherwise its "Who's watching?" shows.

### 4.2 When the picker appears

The existing **Profile Selection** setting (Automatic, Every Time, After 1 Hour, After 12 Hours)
is unchanged and now applies to the account and profile:
- **Automatic** restores the last account and profile. If that profile no longer exists, Silo
  shows that account's picker.
- If the open account has a single profile without a PIN, the picker never appears.

### 4.3 Switching

*Amended 2026-11-02.* The avatar menu (iOS, iPadOS, Mac, tvOS, Android phone and TV, Roku)
changes as follows:
- **Switch Profile** opens the current account's "Who's watching?".
- **Change Account** replaces **Switch Server** and opens Change Account (§4.1). Server
  management moves to Settings (§4.5).
- The menu header keeps "profile · server". It adds the username only when the active server has
  more than one saved account.
- **Sign Out** signs out of the current account (§4.4).

Because #981/#982 aligned this menu across platforms, both platforms change it in the same release.

### 4.4 Signing out and removing

**Sign out of an account** does the following:
1. Revokes the session on the server, retrying later if the server can't be reached.
2. Deletes the account's tokens, cached profiles, local preferences, response caches and
   **downloads**.
3. Unregisters the account's push installation.
4. Removes the account. If it was the last account on that server, the server stays saved and
   Change Account shows a **Sign in** row for it, so signing back in is one step. If another
   account still has a session, Change Account shows; otherwise sign-in shows.

On TVs the confirmation is the app's own dialog, not a system alert, with **Cancel** focused by
default: a system dialog that focused "Sign out" caused an accidental sign-out on a TV. On iPhone,
iPad and Mac it is the standard system alert, like the app's other confirmations, with a
destructive Sign Out and a Cancel button (*amended 2026-11-03*). The title is
"Sign out of {account} on {server}?", and the dialog states the download count and size when there
are downloads:

> Sign out of **alex** on **Home**? This deletes 12 downloads (8.4 GB) from this iPhone.

The dialog offers **Sign Out & Remove Server** only while that server has no other account.

**Remove a server** signs out of every account on it, then removes the server.

**Expired or revoked credentials are not a sign-out.** Downloads stay and remain playable offline
until the person signs in again or signs out. Signing in again as a *different* account in place of
the expired one asks before replacing it. Replacing it counts as a sign-out of the old account.

### 4.5 Settings › Accounts

This screen replaces today's server list as the management surface:

```
Accounts
  Home                                  [Rename] [Remove server]
    alex       3 profiles · 12 downloads    ›
    sam        1 profile                    ›
    + Add an account on Home
  Lake House                            [Rename] [Remove server]
    alex       1 profile                    ›
    + Add an account on Lake House
  + Add a server
```

An account's page shows its username, profiles and downloads size, plus Sign in again and
Sign out.

### 4.6 Apple TV

- **Credentials are household-wide.** Accounts and their tokens live in the user-independent
  Keychain, as server sessions do today, so the household signs in once.
- **Selection is per Apple TV user.** Each Apple TV system user remembers their own last account
  and profile, launch setting and profile PIN proofs. This extends the 2026-08-11 profile spec
  from "remembered profile per server" to "remembered account and profile".
- **Focus.** Change Account has two focus sections, the server rail and the accounts pane. Follow
  `docs/tvos-focus.md` and use the native focus graph without manual focus mutation.
- **Phone-assisted setup.** The phone can send several accounts at once. The TV saves all of them
  and opens the most recently used account's picker, where Change Account reaches the rest. It
  does not add a separate "Choose an Account" step.
- **Approving a TV sign-in from a phone.** "Not you?" lets the person choose another saved account
  on the phone or add one, instead of signing out of the phone's current account.
- **Top Shelf** shows the current Apple TV user's open account and profile. It shows nothing personalized when
  the picker is required, as now.

### 4.7 Android TV

Android TV uses the same picker, Change Account screen and rules as Apple TV, without
per-system-user memory because Android TV has no equivalent. Watch Next always follows the open
account and profile and is cleared on every account switch, as it is cleared on profile and server
switches now.

### 4.8 Notifications

For each server, only the account last used on that server receives notifications. When someone
switches to another account on the same server, the device's push installation for that server
moves to the new account (§7). Other accounts on that server get nothing on this device until
they are used again. Other servers keep notifying, as they do today.

When the device has more than one saved account, a notification's subtitle names the profile and
server.

## 5. Data model (shared by Apple and Android)

```
Server            id, url, verifiedServerId, name, logo, lastUsedAt
  └─ Account      localAccountId (UUID), serverUserId?, username, tokens, epoch/loginId,
                  cachedProfiles, addedAt, lastUsedAt, needsSignIn
       └─ Profile (from the server; cached for the picker)

Selection         (serverId, localAccountId, profileId)   — per Apple TV user on tvOS
LaunchMemory      rememberedByAccount[localAccountId] → profileId, PIN proof, epoch
```

Rules:
- **Every local key uses `localAccountId`, never the server's user ID.** The device creates the
  UUID when it saves an account. It never changes, so no stored data ever has to be renamed.
- `serverUserId` is an attribute used to find duplicates. It is set at sign-in and filled in by
  the first verified `/me` for migrated sessions that lack it.
- A server has at most one saved account per `serverUserId`. Signing in as a saved account
  refreshes it instead of adding a duplicate. If a new sign-in arrives on a server whose existing
  account has no `serverUserId` yet, Silo verifies the existing account first. If that check
  can't run, Silo treats the accounts as different and merges them when the check succeeds.
- Servers are matched by `verifiedServerId` when it is known, so the same server under a LAN URL
  and a remote URL does not produce two sections.
- `ServerEntry` no longer holds a profile. The selected profile belongs to the account.
- Keychain and preference names gain the account. For example, `org.siloserver.silo.<serverId>.accessToken`
  becomes `signIn.v1.<serverId>.<localAccountId>` on Apple and `<serverId>.<localAccountId>.<key>` on Android.

### 5.1 Keying local data

Every store that is keyed by `(server, profile)` today becomes `(server, account, profile)`,
because profile IDs repeat across accounts (older accounts all have `default`).

| Area | Apple today | Android today |
|---|---|---|
| Downloads | `SiloDownloads/<server>/<profile>/`, `DownloadStore` scope `server\nprofile` | Room `downloads`, `download_subscriptions`, `download_deletions` keyed `(serverId, profileId)`; `DownloadStorage` paths |
| Response caches | `ResponseSnapshotStore` `server\|profile` | Room `home_cache`, `catalog_cache` |
| Preferences | `UICustomization`, `TitleArt`, `AppNav`, `BrowsePrefs`, `TVLibraryScope`, `EpisodeSpoiler`, `ThemeMusic`, `AdvisoryAge`, `OnboardingTourGate`, `PlayerSettings` | `AndroidServerSettingsCache`, player settings, seek, spoiler, title art, card presentation, `BrowsePrefsStore` |
| Item state | — | Room `user_item_state`, `content_item_state`, `dirty_operations` |
| Push | journal `push.apple.installation.<serverID>`, display targets | `PushInstallationStore` per server |
| Launch memory | `ProfileLaunchState.rememberedByServerID`, `selectionRequiredServerIDs` | `ServerEntry.profileId`, `silo_profile_launch` |
| Watch party | recent-party owner already has `accountID` | — |
| Diagnostics | binding `(serverRegistryID, accountUserID)` already | — |

Apple keys use the old branch's scheme, `<prefix>.v2.<server>.<account>.<profile>`, with downloads
under `<server>/acct-<account>/<profile>`. Android adds the account to each Room key and to
storage paths, using one migration.

### 5.2 Migration

Migration runs once at launch, before any UI, and needs no network:
1. Each server with a saved session becomes one Account with a new `localAccountId`. It keeps its
   tokens and epoch. It copies `serverUserId` from the session if the session has one (Apple
   `CanonicalAccountSession.accountID`). Android stores no server user ID today, so its accounts
   start without one.
2. That account adopts the server's existing local data (downloads, preferences, caches, push
   installation, remembered profile).
3. The old credential slots are deleted after the new records read back.

Because local keys never depend on the server's user ID, migration works offline. Someone who
updates on a plane keeps their downloads.

**After migration there is a single code path.** No reader outside migration may touch the old
slots. The old branch kept "legacy" and "sign-in" credential selections side by side inside
`TokenStore`, which doubled every path and produced most of its edge-case fixes.

### 5.3 Where the code lives

- **Apple:** add an `AccountStore` that owns accounts, tokens and the selection. `TokenStore` keeps
  request signing and refresh, and reads the active account from `AccountStore`. Do not grow
  `TokenStore` further; the old branch took it from 1,638 to 2,942 lines.
- **Android:** extend `ServerRegistry`/`TokenManager` in `shared/` with the account dimension, so
  phone and TV share it.

## 6. Platform parity

*Amended 2026-11-02:* the picker shows one account at a time, Change Account was added, and Roku
was added as a column.

| Behavior | iOS / iPadOS / Mac | Apple TV | Android phone | Android TV | Roku |
|---|---|---|---|---|---|
| "Who's watching?" shows the open account's profiles only | ✓ | ✓ | ✓ | ✓ | ✓ |
| Change Account | grouped list by server | rail + accounts pane | grouped list by server | rail + accounts pane | rail + accounts pane |
| Add on the picker | creates a profile | creates a profile | Add sheet (3 choices) | Add sheet (3 choices) | Add sheet (3 choices) |
| Add an account on any saved server | ✓ | ✓ | ✓ | ✓ | ✓ |
| Server mark, or the Silo project icon as fallback | ✓ | ✓ | ✓ | ✓ | ✓ |
| Sign-out confirmation | system alert | app dialog, Cancel focused | app dialog | app dialog, Cancel focused | app dialog, Cancel focused |
| Sign out deletes downloads | ✓ | — (no downloads) | ✓ | — | — |
| Selection memory | device | per Apple TV user | device | device | device |
| Phone sends several accounts to a TV | sender | receiver | sender | receiver | receiver (one account per server; older protocol) |
| Watch Next / Top Shelf follow the open account and profile | — | Top Shelf | — | Watch Next | — |

## 7. Server dependencies

- **Push: one installation per device per server, handed between accounts.**
  - **Model:** the device keeps its one real device ID (`AppleDeviceIdentity.current.id`). Each
    server has one push installation for this device, and it belongs to the active account. This
    matches §4.8 and keeps the server's device list accurate. Do not create per-account device IDs;
    the server's device list would then show one phantom device per account.
  - **Handover reuses an existing path.** When the active account on a server changes, the client
    registers the new owner with the same installation key and the next generation. This is
    already what happens when someone signs out of a server and signs in as a different person
    there. The client tracks the departing owner (`ApplePushRegistration.swift:383-403`). On both
    platforms the server re-binds `user_id` when the key matches
    (`apple_push_ordering.go:124-166`, `android_push_ordering.go:123-171`). The previous-owner
    check applies only to an installation that has been reset (`apple_push_ordering.go:150`).
  - **Server work:** none required. Add tests on both platforms that pin down "same installation
    key, higher generation, new user, so the installation is re-bound to that user". The
    multi-account design depends on that behavior, which is currently implicit.
  - **Not required:** the `push_devices` unique key `(profile_id, device_id, platform)` lacks
    `user_id`, although profile IDs are only unique per user (`user_profiles` primary key
    `(user_id, id)`). It cannot collide while a registration first deletes all of the device's
    rows, and one installation per device keeps that true. Fix it only if the server owners want
    the cleanup.
- **Sessions per device.** The check found no server code that revokes other users' sessions
  when a new login arrives from the same device. That check was one `git grep` of
  `origin/main` and was not exhaustive. Confirm before Phase 2.

## 8. Delivery plan

Each phase is one PR per repo. Each must build, pass tests and ship on its own. Branch from
`origin/main` and rebase instead of merging main in.

| Phase | Scope | Visible change |
|---|---|---|
| 1. Storage | Account model, `AccountStore` / shared Kotlin store, migration, account-keyed local data, push installation handover (plus the server handover tests) | None |
| 2. Phone, tablet, Mac | Change Account, Add sheet, Add an account on any saved server, Sign out deleting downloads, Settings › Accounts, avatar menu change | Yes |
| 3. TV | Apple TV and Android TV picker and focus, per-Apple-TV-user account memory, Change Account, phone sending several accounts, "Not you?", Top Shelf / Watch Next | Yes |
| 4. Notifications | Notification subtitle, switching to the notification's account and profile on open | Yes |

Phase 1 can split further on Apple: (a) types, store and migration; (b) downloads; (c)
preferences and caches; (d) push. Keep each PR small enough to review in one sitting.

### 8.1 Reuse from `feat/multiple-accounts-per-server`

Port with tests:
- `SignInKey`, `SavedSignIn`, `SavedSignInStore` (strict reads, versioned decode, read-back, backup index)
- `AccountScopedKeyAdoption` and the downloads `acct-` layout
- `PendingRevocationStore` and the revoke-with-retry in `HTTPClient`
- The migration algorithm from `TokenStore.migrateLegacySessionsIfNeeded`, rewritten without the legacy selection path
- Optional `ProfileLaunchState` fields for backward-compatible decoding
- Tests: `SignInKeyTests`, `SavedSignInStoreTests`, `AccountScopedLocalDataTests`, `DownloadAccountScopeTests`, `PushAccountAttributionTests`, `SignInRevocationTests`

Do not port: `SiloUserIndex`/`SiloUser`, `SiloUserCoordinator`, `SiloLaunchResolver`,
`ProfileLaunchAskFor`, the `Screens/Users/` screens, and its `AppRouter`/`ContentView` routing.
All of these belong to the separate user-picker design.

## 9. Testing

- Migration: one server, several servers, unverified session, a failed write partway through,
  and a downgrade-safe decode.
- Isolation: two accounts on one server, both with a `default` profile. Downloads, preferences,
  caches and push must not cross between them.
- Sign out: downloads removed, other accounts on the same server untouched, server kept with a
  Sign in row in Change Account.
- Expired credentials keep downloads; replacing with a different account asks first.
- Picker and Change Account: offline render from cache, Automatic restoring a deleted profile,
  server marks with the Silo icon fallback, Cancel focused in the sign-out dialog.
- Apple TV: two Apple TV users with different remembered accounts (physical device, as in the
  2026-08-11 spec); focus between the Change Account rail and pane.
- Rendered evidence for every visible change on iPhone, iPad, Mac, Apple TV, Android phone and
  Android TV.

## 10. Open questions

- **Q4.** Is there a cap on accounts per device? Proposal: none. The picker scrolls by section.

Resolved:
- Q1: accounts are keyed by a local UUID (§5).
- Q2: one push installation per device per server, handed over on switch, with no server change (§7).
- Q3: for each server, the last-used account receives notifications (§4.8).
