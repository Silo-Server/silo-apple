# Native-style Companion Pairing Card (iOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the iOS top "Set up Apple TV" banner with a card that rises from the bottom over a dimmed app and runs the entire companion pairing flow — discovery, server selection, match-code confirm, progress, result — inside that one card.

**Architecture:** A bottom-anchored overlay (custom, not `.sheet`) presents `CompanionPairingCard`, which owns one discovered TV's `PairingSession` + `CompanionPairingCoordinator` and swaps its body by coordinator state beneath a consistent header. A presenting `ViewModifier` owns discovery (`TVPairingBrowser`) and per-session dismissal. The tvOS advertiser gains a per-session nonce (`sid`) so "Not Now" hides the card only until the TV restarts its pairing request. The pairing protocol and `CompanionPairingCoordinator` are unchanged.

**Tech Stack:** Swift 5, SwiftUI, Network.framework (Bonjour/NWBrowser/NWListener), XcodeGen. Spec: `docs/superpowers/specs/2026-06-14-companion-pairing-card-ios-design.md`.

---

## File Structure

**Create:**
- `iosApp/iosApp/Pairing/Companion/CompanionPairingDismissal.swift` — pure dismissal-key helper (no platform guard, no SwiftUI/Network deps), so the command-line test can compile it and all targets share it.
- `iosApp/iosApp/Pairing/Companion/CompanionPairingCard.swift` — the card view (`#if os(iOS)`): header + per-step body + session/coordinator wiring (folds in the old `TVPairingView`).
- `iosApp/iosApp/Pairing/Companion/CompanionPairingCardModifier.swift` — the presenting `ViewModifier` (`#if os(iOS)`): browser, candidate computation, dismissal set, overlay. Replaces `SetUpTVBanner.swift`.
- `iosApp/Tests/CompanionDismissalKeyTests.swift` — standalone `@main` test for the dismissal-key logic.

**Modify:**
- `iosApp/iosApp/Pairing/Receiver/TVPairingAdvertiser.swift` — add `sid` to the TXT record (tvOS).
- `iosApp/iosApp/Pairing/Companion/TVPairingBrowser.swift` — parse `sid`; add `sid: String?` to `DiscoveredTV`.
- `iosApp/iosApp/ContentView.swift:75` — `.setUpTVBanner()` → `.companionPairingCard()`.

**Delete:**
- `iosApp/iosApp/Pairing/Companion/SetUpTVBanner.swift` — replaced by the card modifier.
- `iosApp/iosApp/Pairing/Companion/TVPairingView.swift` — folded into the card.

**Notes for all tasks:**
- `iosApp/Silo.xcodeproj` is gitignored; regenerate freely and never `git add` it. Each commit adds only the listed source files.
- Regenerate the project after adding/removing files: `xcodegen generate --spec iosApp/project.yml` (writes `iosApp/Silo.xcodeproj`; no `cd` needed).
- iOS build (no signing): `xcodebuild build -project iosApp/Silo.xcodeproj -scheme Silo -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`
- tvOS build: same with `-scheme SiloTV -destination 'generic/platform=tvOS Simulator'`.
- The card deliberately uses **system blue** for its primary button and selection accents (the app's global tint is `.siloOnSurface`, near-white). Blue matches the native iOS pairing aesthetic the card emulates. This is intentional, not a mistake.

---

## Task 1: tvOS — per-session nonce in the advertiser

**Files:**
- Modify: `iosApp/iosApp/Pairing/Receiver/TVPairingAdvertiser.swift:20-25`

- [ ] **Step 1: Add `sid` to the TXT record**

In `start()`, the TXT dictionary is currently:

```swift
        let txt = NWTXTRecord([
            "v": String(PairingProtocol.version),
            "name": device.name,
            "id": device.id,
            "st": PairingReceiverState.setup.rawValue
        ])
```

Replace it with (adds a fresh nonce generated on every `start()` call):

```swift
        // `sid` is a fresh per-advertising-session nonce. The phone keys "Not
        // Now" dismissals on it, so the card re-appears only when the TV
        // restarts its pairing request (a new `sid`) — not on brief Bonjour
        // flaps (same `sid`). Older phones ignore it and fall back to `id`.
        let txt = NWTXTRecord([
            "v": String(PairingProtocol.version),
            "name": device.name,
            "id": device.id,
            "sid": UUID().uuidString,
            "st": PairingReceiverState.setup.rawValue
        ])
```

- [ ] **Step 2: Build the tvOS target to verify it compiles**

Run: `xcodegen generate --spec iosApp/project.yml && xcodebuild build -project iosApp/Silo.xcodeproj -scheme SiloTV -destination 'generic/platform=tvOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add iosApp/iosApp/Pairing/Receiver/TVPairingAdvertiser.swift
git commit -m "Advertise per-session pairing nonce (sid) from tvOS

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: iOS — dismissal-key helper (TDD)

**Files:**
- Test: `iosApp/Tests/CompanionDismissalKeyTests.swift`
- Create: `iosApp/iosApp/Pairing/Companion/CompanionPairingDismissal.swift`

- [ ] **Step 1: Write the failing test**

Create `iosApp/Tests/CompanionDismissalKeyTests.swift`:

```swift
import Foundation

@main
struct CompanionDismissalKeyTests {
    static func main() {
        testSameSidStaysDismissed()
        testNewSidIsNotDismissed()
        testMissingSidFallsBackToId()
        testEmptySidBehavesLikeMissing()
        print("CompanionDismissalKeyTests: all passed")
    }

    private static func testSameSidStaysDismissed() {
        var dismissed: Set<String> = []
        dismissed.insert(CompanionPairingDismissal.key(id: "TV-1", sid: "sessionA"))
        precondition(dismissed.contains(CompanionPairingDismissal.key(id: "TV-1", sid: "sessionA")),
                     "the same (id, sid) must remain dismissed")
    }

    private static func testNewSidIsNotDismissed() {
        var dismissed: Set<String> = []
        dismissed.insert(CompanionPairingDismissal.key(id: "TV-1", sid: "sessionA"))
        precondition(!dismissed.contains(CompanionPairingDismissal.key(id: "TV-1", sid: "sessionB")),
                     "a new sid for the same id must re-present (not dismissed)")
    }

    private static func testMissingSidFallsBackToId() {
        precondition(CompanionPairingDismissal.key(id: "TV-1", sid: nil) == "TV-1",
                     "missing sid must key on id alone")
    }

    private static func testEmptySidBehavesLikeMissing() {
        precondition(CompanionPairingDismissal.key(id: "TV-1", sid: "") == "TV-1",
                     "empty sid must behave like missing sid")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swiftc -o /tmp/companion-dismissal-tests iosApp/Tests/CompanionDismissalKeyTests.swift 2>&1 | tail -3`
Expected: FAIL — `error: cannot find 'CompanionPairingDismissal' in scope`

- [ ] **Step 3: Write the minimal implementation**

Create `iosApp/iosApp/Pairing/Companion/CompanionPairingDismissal.swift`:

```swift
import Foundation

/// Computes the stable "Not Now" dismissal key for a discovered TV.
///
/// Keying on the TV's per-session nonce (`sid`) means a dismissal lasts only
/// until the TV restarts its pairing request (which yields a fresh `sid`); a
/// brief Bonjour flap keeps the same `sid` and stays dismissed. Falls back to
/// the device `id` for older TVs that don't advertise a nonce.
///
/// No platform guard so the command-line test can compile it directly; the
/// logic is pure and harmless on every target.
enum CompanionPairingDismissal {
    static func key(id: String, sid: String?) -> String {
        if let sid, !sid.isEmpty { return "\(id)#\(sid)" }
        return id
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swiftc -o /tmp/companion-dismissal-tests iosApp/Tests/CompanionDismissalKeyTests.swift iosApp/iosApp/Pairing/Companion/CompanionPairingDismissal.swift && /tmp/companion-dismissal-tests`
Expected: `CompanionDismissalKeyTests: all passed`

- [ ] **Step 5: Commit**

```bash
git add iosApp/iosApp/Pairing/Companion/CompanionPairingDismissal.swift iosApp/Tests/CompanionDismissalKeyTests.swift
git commit -m "Add companion pairing dismissal-key helper + test

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: iOS — parse `sid` in the browser

**Files:**
- Modify: `iosApp/iosApp/Pairing/Companion/TVPairingBrowser.swift:6-12` and `:41-47`

- [ ] **Step 1: Add `sid` to `DiscoveredTV`**

Replace the struct (lines 6-12):

```swift
/// A discovered Apple TV waiting to be set up.
struct DiscoveredTV: Identifiable, Equatable {
    let id: String          // TXT `id` (stable device id), or endpoint string.
    let name: String        // TXT `name`.
    let state: PairingReceiverState
    let endpoint: NWEndpoint
    static func == (a: DiscoveredTV, b: DiscoveredTV) -> Bool { a.id == b.id }
}
```

with:

```swift
/// A discovered Apple TV waiting to be set up.
struct DiscoveredTV: Identifiable, Equatable {
    let id: String          // TXT `id` (stable device id), or endpoint string.
    let name: String        // TXT `name`.
    let state: PairingReceiverState
    let endpoint: NWEndpoint
    let sid: String?        // TXT `sid`: per-advertising-session nonce, if present.
    static func == (a: DiscoveredTV, b: DiscoveredTV) -> Bool { a.id == b.id }
}
```

- [ ] **Step 2: Parse `sid` in `makeTV`**

Replace `makeTV` (lines 41-47):

```swift
    private static func makeTV(_ result: NWBrowser.Result) -> DiscoveredTV? {
        guard case let .bonjour(txt) = result.metadata else { return nil }
        let name = txt["name"] ?? "Apple TV"
        let id = txt["id"] ?? "\(result.endpoint)"
        let state = PairingReceiverState(rawValue: txt["st"] ?? "setup") ?? .setup
        return DiscoveredTV(id: id, name: name, state: state, endpoint: result.endpoint)
    }
```

with:

```swift
    private static func makeTV(_ result: NWBrowser.Result) -> DiscoveredTV? {
        guard case let .bonjour(txt) = result.metadata else { return nil }
        let name = txt["name"] ?? "Apple TV"
        let id = txt["id"] ?? "\(result.endpoint)"
        let state = PairingReceiverState(rawValue: txt["st"] ?? "setup") ?? .setup
        return DiscoveredTV(id: id, name: name, state: state, endpoint: result.endpoint, sid: txt["sid"])
    }
```

- [ ] **Step 3: Build the iOS target to verify it compiles**

Run: `xcodebuild build -project iosApp/Silo.xcodeproj -scheme Silo -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

(Note: the existing project still references the old banner; this step only verifies the browser edit compiles. New files are wired in Tasks 4–5.)

- [ ] **Step 4: Commit**

```bash
git add iosApp/iosApp/Pairing/Companion/TVPairingBrowser.swift
git commit -m "Parse pairing session nonce (sid) into DiscoveredTV

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: iOS — the pairing card view

**Files:**
- Create: `iosApp/iosApp/Pairing/Companion/CompanionPairingCard.swift`

This view folds in the old `TVPairingView` (same coordinator calls: `begin()`, `pushSelected(_:)`, `confirmMatch()`, `declineMatch()`, `cancel()`), restyled as a bottom card with discovery + per-step bodies.

- [ ] **Step 1: Create the card view**

Create `iosApp/iosApp/Pairing/Companion/CompanionPairingCard.swift`:

```swift
#if os(iOS)
import SwiftUI

/// The native-style companion pairing card: rises from the bottom over a dimmed
/// app and runs the whole flow for one discovered TV — discovery, server
/// selection, match-code confirm, progress, result — beneath a consistent
/// header. Owns the `PairingSession` + `CompanionPairingCoordinator` for that
/// TV (folds in the former `TVPairingView`).
struct CompanionPairingCard: View {
    let tv: DiscoveredTV
    /// Discovery-step "Not Now" (and scrim tap): dismiss until the TV re-advertises.
    var onNotNow: () -> Void
    /// Terminal close (Done / error / cancel mid-flow): just dismiss.
    var onClose: () -> Void

    /// System blue matches the native pairing look; the app's global tint is
    /// near-white, which would wash out the primary button.
    private let accent = Color.blue

    @State private var coordinator: CompanionPairingCoordinator?
    @State private var selection: Set<String> = []
    @State private var started = false
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(appeared ? 0.45 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { if !started { animateOut(onNotNow) } }

            card
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .offset(y: appeared ? 0 : 700)
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { appeared = true }
        }
        .onDisappear { Task { await coordinator?.cancel() } }
    }

    // MARK: - Card shell

    private var card: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.25))
                .frame(width: 38, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 18)
            stepContent
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    @ViewBuilder private var stepContent: some View {
        if !started {
            discovery
        } else {
            switch coordinator?.state ?? .connecting {
            case .connecting:
                progressStep(title: "Connecting…", subtitle: tv.name)
            case let .pickServers(_, servers):
                serverPicker(servers)
            case let .confirmMatch(_, serverName, matchCode):
                confirm(serverName: serverName, matchCode: matchCode)
            case let .working(progress):
                progressStep(title: "Setting up…", subtitle: progress)
            case let .finished(signedIn, failed):
                finished(signedIn: signedIn, failed: failed)
            case let .error(message):
                errorState(message)
            }
        }
    }

    // MARK: - Steps

    private var discovery: some View {
        VStack(spacing: 0) {
            heroGlyph.padding(.bottom, 16)
            Text("Set Up \(tv.name)")
                .font(.siloTitle)
                .multilineTextAlignment(.center)
            Text("Sign this Apple TV in using this iPhone.")
                .font(.siloCaption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            primaryButton("Set Up") { setUp() }.padding(.top, 22)
            tertiaryButton("Not Now") { animateOut(onNotNow) }.padding(.top, 4)
        }
    }

    private func serverPicker(_ servers: [ServerEntry]) -> some View {
        VStack(spacing: 0) {
            compactHeader(title: "Choose servers", subtitle: "Sign \(tv.name) in to…")
            VStack(spacing: 8) {
                ForEach(servers) { server in serverRow(server) }
            }
            primaryButton("Continue") {
                let chosen = servers.filter { selection.contains($0.id) }
                Task { await coordinator?.pushSelected(chosen) }
            }
            .disabled(selection.isEmpty)
            .opacity(selection.isEmpty ? 0.5 : 1)
            .padding(.top, 18)
        }
    }

    private func serverRow(_ server: ServerEntry) -> some View {
        let isOn = selection.contains(server.id)
        return Button {
            if isOn { selection.remove(server.id) } else { selection.insert(server.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .foregroundStyle(.white)
                Text(server.displayName)
                    .font(.siloBody)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isOn ? accent : Color.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                isOn ? Color.siloChromeSelectedFill : Color.siloChromeRestingFill,
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func confirm(serverName: String, matchCode: String) -> some View {
        VStack(spacing: 0) {
            Text("Make sure your TV shows")
                .font(.siloCaption)
                .foregroundStyle(.secondary)
            Text(matchCode)
                .font(.siloPIN)
                .textCase(.uppercase)
                .tracking(8)
                .padding(.top, 8)
            Text("for \(serverName)")
                .font(.siloCaption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            primaryButton("Yes, this matches") { Task { await coordinator?.confirmMatch() } }
                .padding(.top, 22)
            tertiaryButton("Doesn’t match") { Task { await coordinator?.declineMatch() } }
                .padding(.top, 4)
        }
    }

    private func finished(signedIn: [String], failed: [String]) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
                .padding(.bottom, 12)
            Text(signedIn.isEmpty ? "Nothing set up" : "Set up \(signedIn.joined(separator: ", "))")
                .font(.siloHeadline)
                .multilineTextAlignment(.center)
            if !failed.isEmpty {
                Text("Couldn’t set up: \(failed.joined(separator: ", "))")
                    .font(.siloCaption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            primaryButton("Done") { animateOut(onClose) }.padding(.top, 22)
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.yellow)
                .padding(.bottom, 12)
            Text(message)
                .font(.siloBody)
                .multilineTextAlignment(.center)
            primaryButton("Close") { animateOut(onClose) }.padding(.top, 22)
        }
    }

    // MARK: - Header & building blocks

    private var heroGlyph: some View {
        Image(systemName: "appletv.fill")
            .font(.system(size: 56))
            .foregroundStyle(.primary)
            .frame(width: 104, height: 104)
    }

    private func compactHeader(title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "appletv.fill").font(.system(size: 22)).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.siloHeadline)
                Text(subtitle).font(.siloCaption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.bottom, 14)
    }

    private func progressStep(title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.siloHeadline)
            Text(subtitle).font(.siloCaption).foregroundStyle(.secondary)
            ProgressView().padding(.top, 4)
        }
        .padding(.vertical, 8)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.siloHeadline).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(accent)
    }

    private func tertiaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.siloBody).frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent)
    }

    // MARK: - Actions

    private func setUp() {
        started = true
        Task {
            let session = PairingSession(endpoint: tv.endpoint)
            let stream = await session.open()
            let coordinator = CompanionPairingCoordinator(session: session, stream: stream)
            self.coordinator = coordinator
            await coordinator.begin()
        }
    }

    private func animateOut(_ completion: @escaping () -> Void) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { appeared = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { completion() }
    }
}
#endif
```

- [ ] **Step 2: Regenerate the project and build iOS**

Run: `xcodegen generate --spec iosApp/project.yml && xcodebuild build -project iosApp/Silo.xcodeproj -scheme Silo -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` (the card is not referenced yet, but must compile; this also pulls in `CompanionPairingDismissal.swift` from Task 2.)

- [ ] **Step 3: Commit**

```bash
git add iosApp/iosApp/Pairing/Companion/CompanionPairingCard.swift
git commit -m "Add native-style companion pairing card view

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: iOS — present the card; remove the banner

**Files:**
- Create: `iosApp/iosApp/Pairing/Companion/CompanionPairingCardModifier.swift`
- Delete: `iosApp/iosApp/Pairing/Companion/SetUpTVBanner.swift`
- Delete: `iosApp/iosApp/Pairing/Companion/TVPairingView.swift`
- Modify: `iosApp/iosApp/ContentView.swift:75`

- [ ] **Step 1: Create the presenting modifier**

Create `iosApp/iosApp/Pairing/Companion/CompanionPairingCardModifier.swift`:

```swift
#if os(iOS)
import SwiftUI

/// App-wide overlay: when a blank Apple TV is discovered on the LAN, present the
/// native-style pairing card (`CompanionPairingCard`) rising from the bottom.
/// Replaces the old top banner. Owns discovery (`TVPairingBrowser`) and
/// per-session "Not Now" dismissal.
struct CompanionPairingCardModifier: ViewModifier {
    @State private var browser = TVPairingBrowser()
    @State private var dismissed: Set<String> = []
    @State private var active: DiscoveredTV?

    func body(content: Content) -> some View {
        content
            .task { browser.start() }
            .onChange(of: candidate) { _, newValue in
                // Latch onto a candidate when nothing is showing. We do NOT
                // auto-clear when it disappears: once setup begins the TV stops
                // advertising, and the card must persist to show progress/result.
                if active == nil, let tv = newValue { active = tv }
            }
            .overlay {
                if let tv = active {
                    CompanionPairingCard(
                        tv: tv,
                        onNotNow: {
                            dismissed.insert(CompanionPairingDismissal.key(id: tv.id, sid: tv.sid))
                            active = nil
                        },
                        onClose: { active = nil }
                    )
                }
            }
    }

    /// First discovered TV awaiting setup whose session hasn't been dismissed.
    private var candidate: DiscoveredTV? {
        browser.found.first {
            $0.state == .setup
                && !dismissed.contains(CompanionPairingDismissal.key(id: $0.id, sid: $0.sid))
        }
    }
}

extension View {
    func companionPairingCard() -> some View { modifier(CompanionPairingCardModifier()) }
}
#endif
```

- [ ] **Step 2: Delete the old banner and modal files**

Run: `git rm iosApp/iosApp/Pairing/Companion/SetUpTVBanner.swift iosApp/iosApp/Pairing/Companion/TVPairingView.swift`
Expected: both files removed.

- [ ] **Step 3: Update the call site in `ContentView`**

In `iosApp/iosApp/ContentView.swift` (around line 75), inside the `#if os(iOS)` block, replace:

```swift
        .setUpTVBanner()
```

with:

```swift
        .companionPairingCard()
```

- [ ] **Step 4: Regenerate the project and build iOS**

Run: `xcodegen generate --spec iosApp/project.yml && xcodebuild build -project iosApp/Silo.xcodeproj -scheme Silo -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add iosApp/iosApp/Pairing/Companion/CompanionPairingCardModifier.swift iosApp/iosApp/ContentView.swift iosApp/iosApp/Pairing/Companion/SetUpTVBanner.swift iosApp/iosApp/Pairing/Companion/TVPairingView.swift
git commit -m "Present companion pairing card from the bottom, drop top banner

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Full verification

**Files:** none (verification only).

- [ ] **Step 1: Re-run the dismissal-key test**

Run: `swiftc -o /tmp/companion-dismissal-tests iosApp/Tests/CompanionDismissalKeyTests.swift iosApp/iosApp/Pairing/Companion/CompanionPairingDismissal.swift && /tmp/companion-dismissal-tests`
Expected: `CompanionDismissalKeyTests: all passed`

- [ ] **Step 2: Build iOS and tvOS clean**

Run: `xcodegen generate --spec iosApp/project.yml && xcodebuild build -project iosApp/Silo.xcodeproj -scheme Silo -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild build -project iosApp/Silo.xcodeproj -scheme SiloTV -destination 'generic/platform=tvOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Manual two-simulator smoke test**

Per the spec, no UI tests. Verify by hand using two simulators on the same host network (see memory: companion-pairing-sim-test):
1. Launch SiloTV on a tvOS simulator and reach its setup screen (advertising).
2. Launch Silo on an iOS simulator already signed in to ≥1 server.
3. Confirm the **card rises from the bottom** (no top banner), dims the app, and shows "Set Up {tvName}" + Set Up / Not Now.
4. Tap **Set Up** → Connecting → **Choose servers** (in-card multi-select) → Continue → **match code** → Yes → progress → **Done**, all within the card.
5. Tap **Not Now**; confirm the card stays dismissed while the TV keeps advertising.
6. Restart the TV's pairing screen (new `sid`); confirm the card **re-appears**.

Record the result (pass/fail per step) in the task notes.

- [ ] **Step 4: Final confirmation**

Confirm: no remaining references to the removed symbols.
Run: `grep -rn "setUpTVBanner\|SetUpTVBannerModifier\|TVPairingView" iosApp --include="*.swift"`
Expected: no matches.

---

## Self-Review

- **Spec coverage:** §1 presentation → Tasks 4–5 (bottom overlay, dimming, custom not-sheet, auto-present via `candidate`). §2 card content by coordinator state → Task 4 (`stepContent` switch, folded `TVPairingView`, in-card server rows + match code). §3 `sid` dismissal → Task 1 (advertise), Task 3 (parse), Task 2 (key helper + test), Task 5 (apply in modifier). §4 data flow → Tasks 4–5 wiring. §5 testing → Task 2 (only the dismissal-key logic), no UI tests. §6 out-of-scope (Android, server) → untouched. All covered.
- **Placeholder scan:** none — every step has concrete code/commands and expected output.
- **Type consistency:** `CompanionPairingDismissal.key(id:sid:)` is used identically in the test (Task 2), the modifier `candidate` and `onNotNow` (Task 5). `DiscoveredTV.sid` defined in Task 3, consumed in Task 5. `CompanionPairingCard(tv:onNotNow:onClose:)` defined in Task 4, called in Task 5. Coordinator calls (`begin/pushSelected/confirmMatch/declineMatch/cancel`) match `CompanionPairingCoordinator`. `.companionPairingCard()` defined in Task 5, called in `ContentView` Task 5.
- **Edge note (intentional):** `onChange(of: candidate)` latches and does not auto-dismiss on disappearance (documented in code) so the card survives the TV leaving `setup` mid-flow; pre-Set-Up disappearance is an accepted minor imperfection per the spec.
