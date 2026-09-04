# Companion Pairing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the Silo iOS app discover a waiting Apple TV on the LAN, push the server address(es), and approve the TV's sign-in so the user types no URL or password on the remote.

**Architecture:** A new `iosApp/iosApp/Pairing/` module compiled into both the `Silo` (iOS) and `SiloTV` (tvOS) targets, platform-guarded with `#if os(...)`. Shared `PairingProtocol` (wire messages) + `PairingFrame` (length-prefixed JSON codec) + `PairingSession` (NWConnection wrapper). The TV (Receiver) advertises a Bonjour `_silopair._tcp` service via `NWListener`; the phone (Companion) discovers it via `NWBrowser`, opens a TLS `NWConnection`, and runs a per-server handshake. All token minting stays on the Silo server via its existing `device/{start,poll,approve}` + `GET /auth/device` endpoints, reached through a new URLSession-based `PairingDeviceAPI` that targets an explicit server URL (the app's shared `HTTPClient` only ever talks to the single active server, so pairing must not use it). Servers persist on the TV **only after** a successful sign-in.

**Tech Stack:** Swift 6, SwiftUI, `@Observable`/`@MainActor` view models, the Network framework (`NWListener`/`NWBrowser`/`NWConnection`), `URLSession`, XcodeGen (`project.yml`).

**Design spec:** `docs/superpowers/specs/2026-06-14-companion-pairing-design.md` (read it first; §6 "Accepted risk" records the confirm-once decision).

---

## Decisions locked in during planning (read before starting)

1. **Pairing networking is isolated from `HTTPClient`.** `HTTPClient`/`SiloAPI`/`TokenStore` operate against a single *active* server and have no per-server request API. Rather than rework that, all device-auth calls during pairing go through a new `PairingDeviceAPI` (plain `URLSession`, explicit base URL, optional bearer). This keeps pairing from disturbing the running app's active server.
2. **The phone displays the server-authoritative match code.** After receiving a `userCode` over the channel, the phone calls `GET /auth/device?code=<userCode>` (`PairingDeviceAPI.lookup`) and shows the match code **the server** returns for that code — never the match code from the channel. This is what makes the visual compare resistant to a channel MITM (design spec §6).
3. **Persist-on-success.** The TV holds a pushed server URL as a *pending candidate* and writes it to `ServerRegistry` / `TokenStore` only after the poll returns tokens. Any cancel/fail/timeout/drop discards it (design spec §5/§6/§7).
4. **Tests.** The repo has no working XCTest target (the lone `iosApp/Tests/*.swift` file is an orphaned `@main` + `precondition()` script). Per CLAUDE.md ("focused tests only for critical or high-risk behavior") we unit-test only the **pure, dependency-free** logic — `PairingProtocol` and `PairingFrame` — with standalone `swiftc`-compiled `precondition()` programs that mirror the existing pattern. The stateful coordinators are structured against injected protocols and verified by the **manual LAN end-to-end test** (Task 14).
5. **One server-contract check.** The `GET /auth/device` response field names are not verified field-by-field in this repo. Task 7 includes a step to confirm them against `silo-server/internal/api/handlers/auth_device.go`.
6. **tvOS onboarding is in flux.** `Screens/Auth/TVServerSetupView.swift` has uncommitted Aurora-redesign edits. The Receiver UI is built as a self-contained view (Task 9) wired in with a minimal addition, to avoid clobbering that work.
7. **No biometric gate.** Authorization is the user's confirmation tap on a phone already signed in to the server — there is no Face ID / `LocalAuthentication` step (decision 2026-06-14). The match-code visual compare remains the security anchor.
8. **Receiver polling is cancellable.** The Receiver coordinator reads the session stream on a loop that never blocks on network work; each server's start+poll is a separate cancellable `Task`, so a peer `Cancel` or a dropped connection aborts the attempt immediately and frees the advertiser (Task 8).

---

## File Structure

**Create (all under `iosApp/iosApp/Pairing/`, auto-included in both targets):**
- `PairingProtocol.swift` — wire messages + version + service type. Foundation-only.
- `PairingFrame.swift` — length-prefixed framing codec + incremental buffer. Foundation-only.
- `PairingSession.swift` — `NWConnection` wrapper: send/receive `PairingMessage`, TLS. Shared.
- `PairingDeviceAPI.swift` — `URLSession` device-auth calls against an explicit server. Shared.
- `Receiver/ReceiverPairingCoordinator.swift` — tvOS state machine (`#if os(tvOS)`).
- `Receiver/TVPairingAdvertiser.swift` — `NWListener` Bonjour advertiser (`#if os(tvOS)`).
- `Receiver/TVPairingReceiverView.swift` — tvOS "Set up with iPhone" UI (`#if os(tvOS)`).
- `Companion/CompanionPairingCoordinator.swift` — iOS state machine (`#if os(iOS)`).
- `Companion/TVPairingBrowser.swift` — `NWBrowser` discovery (`#if os(iOS)`).
- `Companion/SetUpTVBanner.swift` — iOS auto-discovery banner (`#if os(iOS)`).
- `Companion/TVPairingView.swift` — iOS server-pick + confirm UI (`#if os(iOS)`).
- `iosApp/Tests/PairingProtocolTests.swift` — standalone test program.
- `iosApp/Tests/PairingFrameTests.swift` — standalone test program.

**Modify:**
- `iosApp/iosApp/Networking/TokenStore.swift` — add `getAccessToken(for:)`.
- `iosApp/iosApp/Networking/DeviceLoginModels.swift` — add approve/lookup models.
- `iosApp/iosApp/Info.plist` and `iosApp/iosApp/tvOS-Info.plist` — Local Network + Bonjour keys.
- `iosApp/iosApp/ContentView.swift` — mount `SetUpTVBanner` overlay (iOS).
- `iosApp/iosApp/Screens/Auth/TVServerSetupView.swift` — present `TVPairingReceiverView` (minimal, tvOS).

---

## Task 1: Config — Info.plist keys + module folder

**Files:**
- Modify: `iosApp/iosApp/Info.plist`
- Modify: `iosApp/iosApp/tvOS-Info.plist`

- [ ] **Step 1: Add Local Network + Bonjour keys to the iOS Info.plist**

Open `iosApp/iosApp/Info.plist` and add these keys at the top level of the root `<dict>` (alongside the existing `NSAppTransportSecurity` block):

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Silo uses your local network to find and set up Silo on your Apple TV.</string>
<key>NSBonjourServices</key>
<array>
  <string>_silopair._tcp</string>
</array>
```

- [ ] **Step 2: Add the same two keys to the tvOS Info.plist**

Open `iosApp/iosApp/tvOS-Info.plist` and add the identical `NSLocalNetworkUsageDescription` and `NSBonjourServices` keys at the top level of the root `<dict>`.

- [ ] **Step 3: Create the module folder so XcodeGen picks it up**

Run:
```bash
mkdir -p iosApp/iosApp/Pairing/Receiver iosApp/iosApp/Pairing/Companion
```
(Files added in later tasks under `iosApp/iosApp/` are automatically included in both targets — no `project.yml` edit needed.)

- [ ] **Step 4: Commit**

```bash
git add iosApp/iosApp/Info.plist iosApp/iosApp/tvOS-Info.plist
git commit -m "Add Local Network + Bonjour Info.plist keys for companion pairing"
```

---

## Task 2: PairingProtocol (wire messages)

**Files:**
- Create: `iosApp/iosApp/Pairing/PairingProtocol.swift`

- [ ] **Step 1: Write the protocol types**

Create `iosApp/iosApp/Pairing/PairingProtocol.swift`:

```swift
import Foundation

/// Constants for the companion-pairing LAN protocol. Platform-neutral so
/// silo-android can mirror it (Android NSD + sockets).
enum PairingProtocol {
    /// Wire protocol version. Bump on any breaking change to message shapes.
    static let version = 1
    /// Bonjour service type the TV advertises and the phone browses for.
    static let serviceType = "_silopair._tcp"
}

/// The TV's advertised state, carried in the Bonjour TXT record and in `Hello`.
enum PairingReceiverState: String, Codable, Equatable {
    /// Blank TV with no server configured — needs a URL pushed.
    case setup
    /// TV already has a server — only needs a user signed in.
    case login
}

/// A message on the wire. Encoded as a JSON object with a `type`
/// discriminator and a `v` (version) field; per-type fields are flattened
/// alongside. Tokens NEVER appear in any message — the server delivers
/// those to the TV over HTTPS.
enum PairingMessage: Equatable {
    /// TV → phone, first message after the connection opens.
    case hello(tvName: String, tvDeviceId: String, state: PairingReceiverState, supportedVersions: [Int])
    /// phone → TV, one per chosen server.
    case pushServer(serverURL: String, serverName: String?)
    /// TV → phone, after the TV called device/start for a pushed server.
    /// `matchCode` is advisory display only; the phone re-fetches the
    /// authoritative match code from the server via lookup before approving.
    case deviceStarted(serverURL: String, userCode: String, matchCode: String)
    /// TV → phone, terminal per-server outcome.
    case serverResult(serverURL: String, status: PairingServerStatus, error: String?)
    /// phone → TV, no more servers; finish.
    case done
    /// either direction, abort.
    case cancel(reason: String)
}

enum PairingServerStatus: String, Codable, Equatable {
    case signedIn
    case failed
}

extension PairingMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, v
        case tvName, tvDeviceId, state, supportedVersions
        case serverURL, serverName
        case userCode, matchCode
        case status, error
        case reason
    }

    private enum Kind: String, Codable {
        case hello, pushServer, deviceStarted, serverResult, done, cancel
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(PairingProtocol.version, forKey: .v)
        switch self {
        case let .hello(tvName, tvDeviceId, state, supportedVersions):
            try c.encode(Kind.hello, forKey: .type)
            try c.encode(tvName, forKey: .tvName)
            try c.encode(tvDeviceId, forKey: .tvDeviceId)
            try c.encode(state, forKey: .state)
            try c.encode(supportedVersions, forKey: .supportedVersions)
        case let .pushServer(serverURL, serverName):
            try c.encode(Kind.pushServer, forKey: .type)
            try c.encode(serverURL, forKey: .serverURL)
            try c.encodeIfPresent(serverName, forKey: .serverName)
        case let .deviceStarted(serverURL, userCode, matchCode):
            try c.encode(Kind.deviceStarted, forKey: .type)
            try c.encode(serverURL, forKey: .serverURL)
            try c.encode(userCode, forKey: .userCode)
            try c.encode(matchCode, forKey: .matchCode)
        case let .serverResult(serverURL, status, error):
            try c.encode(Kind.serverResult, forKey: .type)
            try c.encode(serverURL, forKey: .serverURL)
            try c.encode(status, forKey: .status)
            try c.encodeIfPresent(error, forKey: .error)
        case .done:
            try c.encode(Kind.done, forKey: .type)
        case let .cancel(reason):
            try c.encode(Kind.cancel, forKey: .type)
            try c.encode(reason, forKey: .reason)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .type)
        switch kind {
        case .hello:
            self = .hello(
                tvName: try c.decode(String.self, forKey: .tvName),
                tvDeviceId: try c.decode(String.self, forKey: .tvDeviceId),
                state: try c.decode(PairingReceiverState.self, forKey: .state),
                supportedVersions: try c.decode([Int].self, forKey: .supportedVersions)
            )
        case .pushServer:
            self = .pushServer(
                serverURL: try c.decode(String.self, forKey: .serverURL),
                serverName: try c.decodeIfPresent(String.self, forKey: .serverName)
            )
        case .deviceStarted:
            self = .deviceStarted(
                serverURL: try c.decode(String.self, forKey: .serverURL),
                userCode: try c.decode(String.self, forKey: .userCode),
                matchCode: try c.decode(String.self, forKey: .matchCode)
            )
        case .serverResult:
            self = .serverResult(
                serverURL: try c.decode(String.self, forKey: .serverURL),
                status: try c.decode(PairingServerStatus.self, forKey: .status),
                error: try c.decodeIfPresent(String.self, forKey: .error)
            )
        case .done:
            self = .done
        case .cancel:
            self = .cancel(reason: try c.decode(String.self, forKey: .reason))
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add iosApp/iosApp/Pairing/PairingProtocol.swift
git commit -m "Add PairingProtocol wire messages"
```

---

## Task 3: PairingProtocol tests (standalone)

**Files:**
- Create: `iosApp/Tests/PairingProtocolTests.swift`

- [ ] **Step 1: Write the failing test program**

Create `iosApp/Tests/PairingProtocolTests.swift`:

```swift
import Foundation

@main
struct PairingProtocolTests {
    static func main() {
        testRoundTripsEveryCase()
        testTypeDiscriminatorAndVersionArePresent()
        testUnknownTypeFailsToDecode()
        print("PairingProtocolTests: all passed")
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private static func roundTrip(_ message: PairingMessage) -> PairingMessage {
        let data = try! encoder.encode(message)
        return try! decoder.decode(PairingMessage.self, from: data)
    }

    private static func testRoundTripsEveryCase() {
        let cases: [PairingMessage] = [
            .hello(tvName: "Living Room", tvDeviceId: "ABC-123", state: .setup, supportedVersions: [1]),
            .pushServer(serverURL: "https://media.example.com", serverName: "Home"),
            .pushServer(serverURL: "https://media.example.com", serverName: nil),
            .deviceStarted(serverURL: "https://media.example.com", userCode: "WXYZ-12", matchCode: "brave-otter"),
            .serverResult(serverURL: "https://media.example.com", status: .signedIn, error: nil),
            .serverResult(serverURL: "https://media.example.com", status: .failed, error: "timeout"),
            .done,
            .cancel(reason: "user_declined")
        ]
        for message in cases {
            precondition(roundTrip(message) == message, "round-trip mismatch for \(message)")
        }
    }

    private static func testTypeDiscriminatorAndVersionArePresent() {
        let data = try! encoder.encode(PairingMessage.done)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(json["type"] as? String == "done", "missing/incorrect type discriminator")
        precondition(json["v"] as? Int == PairingProtocol.version, "missing/incorrect version")
    }

    private static func testUnknownTypeFailsToDecode() {
        let data = #"{"type":"bogus","v":1}"#.data(using: .utf8)!
        var threw = false
        do { _ = try decoder.decode(PairingMessage.self, from: data) } catch { threw = true }
        precondition(threw, "decoding an unknown type should throw")
    }
}
```

- [ ] **Step 2: Run it and verify it FAILS to compile (types not yet linked)**

Run:
```bash
swiftc iosApp/iosApp/Pairing/PairingProtocol.swift iosApp/Tests/PairingProtocolTests.swift -o /tmp/pairingprotocoltests 2>&1 | head -5
```
Expected on a *broken* protocol: a compile error. With Task 2 complete it should compile; proceed to Step 3.

- [ ] **Step 3: Run the tests and verify they PASS**

Run:
```bash
swiftc iosApp/iosApp/Pairing/PairingProtocol.swift iosApp/Tests/PairingProtocolTests.swift -o /tmp/pairingprotocoltests && /tmp/pairingprotocoltests
```
Expected: `PairingProtocolTests: all passed`

- [ ] **Step 4: Commit**

```bash
git add iosApp/Tests/PairingProtocolTests.swift
git commit -m "Add PairingProtocol round-trip tests"
```

---

## Task 4: PairingFrame (length-prefixed codec)

**Files:**
- Create: `iosApp/iosApp/Pairing/PairingFrame.swift`

- [ ] **Step 1: Write the codec**

Create `iosApp/iosApp/Pairing/PairingFrame.swift`:

```swift
import Foundation

/// Length-prefixed framing for the pairing channel: each payload is sent as
/// a 4-byte big-endian unsigned length followed by that many bytes of JSON.
/// Pure and dependency-free so it is unit-testable in isolation.
enum PairingFrame {
    /// Largest single frame we will encode or accept (1 MiB). Guards against
    /// a peer claiming an absurd length.
    static let maxFrameBytes = 1 << 20

    enum FrameError: Error, Equatable {
        case frameTooLarge(Int)
    }

    /// Prefix `payload` with its big-endian UInt32 length.
    static func encode(_ payload: Data) throws -> Data {
        guard payload.count <= maxFrameBytes else { throw FrameError.frameTooLarge(payload.count) }
        var length = UInt32(payload.count).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(payload)
        return out
    }
}

/// Accumulates bytes from a stream and yields complete frame payloads as they
/// arrive. Not thread-safe; confine to one connection's receive loop.
struct PairingFrameBuffer {
    private var buffer = Data()

    /// Append newly-received bytes and return every complete payload now
    /// available (possibly zero, possibly several).
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var payloads: [Data] = []
        while true {
            guard buffer.count >= 4 else { break }
            let length = Int(buffer.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            guard length <= PairingFrame.maxFrameBytes else {
                throw PairingFrame.FrameError.frameTooLarge(length)
            }
            guard buffer.count >= 4 + length else { break }
            let start = buffer.index(buffer.startIndex, offsetBy: 4)
            let end = buffer.index(start, offsetBy: length)
            payloads.append(Data(buffer[start..<end]))
            buffer.removeSubrange(buffer.startIndex..<end)
        }
        return payloads
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add iosApp/iosApp/Pairing/PairingFrame.swift
git commit -m "Add PairingFrame length-prefixed codec"
```

---

## Task 5: PairingFrame tests (standalone)

**Files:**
- Create: `iosApp/Tests/PairingFrameTests.swift`

- [ ] **Step 1: Write the test program**

Create `iosApp/Tests/PairingFrameTests.swift`:

```swift
import Foundation

@main
struct PairingFrameTests {
    static func main() {
        testSingleFrameRoundTrips()
        testTwoFramesInOneChunk()
        testFrameSplitAcrossChunks()
        testOversizeLengthThrows()
        print("PairingFrameTests: all passed")
    }

    private static func testSingleFrameRoundTrips() {
        let payload = "hello".data(using: .utf8)!
        let framed = try! PairingFrame.encode(payload)
        var buffer = PairingFrameBuffer()
        let out = try! buffer.append(framed)
        precondition(out == [payload], "single frame should decode to its payload")
    }

    private static func testTwoFramesInOneChunk() {
        let a = "aa".data(using: .utf8)!
        let b = "bbbb".data(using: .utf8)!
        var chunk = try! PairingFrame.encode(a)
        chunk.append(try! PairingFrame.encode(b))
        var buffer = PairingFrameBuffer()
        let out = try! buffer.append(chunk)
        precondition(out == [a, b], "two concatenated frames should both decode")
    }

    private static func testFrameSplitAcrossChunks() {
        let payload = "splitme".data(using: .utf8)!
        let framed = try! PairingFrame.encode(payload)
        var buffer = PairingFrameBuffer()
        let first = try! buffer.append(framed.prefix(3))
        precondition(first.isEmpty, "partial frame should yield nothing yet")
        let second = try! buffer.append(framed.suffix(from: framed.index(framed.startIndex, offsetBy: 3)))
        precondition(second == [payload], "completing the frame should yield the payload")
    }

    private static func testOversizeLengthThrows() {
        // 4-byte length header claiming 2 MiB, exceeding maxFrameBytes.
        var length = UInt32(2 << 20).bigEndian
        let header = Data(bytes: &length, count: 4)
        var buffer = PairingFrameBuffer()
        var threw = false
        do { _ = try buffer.append(header) } catch { threw = true }
        precondition(threw, "an oversize length header must throw")
    }
}
```

- [ ] **Step 2: Run the tests and verify they PASS**

Run:
```bash
swiftc iosApp/iosApp/Pairing/PairingFrame.swift iosApp/Tests/PairingFrameTests.swift -o /tmp/pairingframetests && /tmp/pairingframetests
```
Expected: `PairingFrameTests: all passed`

- [ ] **Step 3: Commit**

```bash
git add iosApp/Tests/PairingFrameTests.swift
git commit -m "Add PairingFrame codec tests"
```

---

## Task 6: PairingSession (NWConnection wrapper)

**Files:**
- Create: `iosApp/iosApp/Pairing/PairingSession.swift`

- [ ] **Step 1: Write the session**

Create `iosApp/iosApp/Pairing/PairingSession.swift`:

```swift
import Foundation
import Network

/// Wraps one `NWConnection` carrying framed `PairingMessage`s. Both the
/// Companion (outbound) and Receiver (inbound) sides use this. TLS provides
/// opportunistic confidentiality only (the cert is unauthenticated — see the
/// design spec §6); integrity rests on the server-issued match code.
actor PairingSession {
    enum SessionError: Error { case closed, decodeFailed }

    private let connection: NWConnection
    private var frameBuffer = PairingFrameBuffer()
    private var continuation: AsyncThrowingStream<PairingMessage, Error>.Continuation?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var isOpen = false

    /// Inbound side (Receiver): wrap a connection handed up by `NWListener`.
    init(connection: NWConnection) {
        self.connection = connection
    }

    /// Outbound side (Companion): connect to a discovered endpoint over TLS.
    init(endpoint: NWEndpoint) {
        let params = PairingSession.tlsParameters()
        self.connection = NWConnection(to: endpoint, using: params)
    }

    /// A TLS-over-TCP parameter set with an ephemeral, unauthenticated cert.
    /// `includePeerToPeer` lets discovery/transport use AWDL when available.
    static func tlsParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        let tls = NWProtocolTLS.Options()
        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        return params
    }

    /// Start the connection and begin the receive loop. Returns a stream of
    /// decoded inbound messages; the stream finishes on close and throws on
    /// transport/decoele error.
    func open() -> AsyncThrowingStream<PairingMessage, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            self.isOpen = true
            self.connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    Task { await self.receiveLoop() }
                case .failed(let error), .waiting(let error):
                    continuation.finish(throwing: error)
                case .cancelled:
                    continuation.finish()
                default:
                    break
                }
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.close() }
            }
            self.connection.start(queue: .global(qos: .userInitiated))
        }
    }

    /// Encode and send one message as a single frame.
    func send(_ message: PairingMessage) async throws {
        guard isOpen else { throw SessionError.closed }
        let payload = try encoder.encode(message)
        let framed = try PairingFrame.encode(payload)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        connection.cancel()
        continuation?.finish()
        continuation = nil
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { await self.handleReceive(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: Error?) {
        if let error {
            continuation?.finish(throwing: error)
            return
        }
        if let data, !data.isEmpty {
            do {
                for payload in try frameBuffer.append(data) {
                    let message = try decoder.decode(PairingMessage.self, from: payload)
                    continuation?.yield(message)
                }
            } catch {
                continuation?.finish(throwing: error)
                return
            }
        }
        if isComplete {
            continuation?.finish()
            return
        }
        guard isOpen else { return }
        receiveLoop()
    }
}
```

- [ ] **Step 2: Verify both targets still build**

Run:
```bash
cd iosApp && xcodegen generate
xcodebuild build -project Silo.xcodeproj -scheme Silo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild build -project Silo.xcodeproj -scheme SiloTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **` for both. (If the tvOS simulator name differs, list with `xcrun simctl list devicetypes | grep TV` and substitute.)

- [ ] **Step 3: Commit**

```bash
git add iosApp/iosApp/Pairing/PairingSession.swift iosApp/Silo.xcodeproj
git commit -m "Add PairingSession NWConnection wrapper"
```

---

## Task 7: PairingDeviceAPI + device models + TokenStore accessor

**Files:**
- Modify: `iosApp/iosApp/Networking/DeviceLoginModels.swift`
- Modify: `iosApp/iosApp/Networking/TokenStore.swift:102-110`
- Create: `iosApp/iosApp/Pairing/PairingDeviceAPI.swift`

- [ ] **Step 1: Confirm the server's lookup response shape**

Read `silo-server/internal/api/handlers/auth_device.go` (the `HandleDeviceLookup` handler) and confirm the JSON field names returned by `GET /auth/device`. Adjust `DeviceLookupResponse` below if they differ from `deviceName` / `matchCode` / `status`. The decoder uses `.convertFromSnakeCase`, so `device_name` maps to `deviceName` automatically.

- [ ] **Step 2: Add the approve/lookup models**

Append to `iosApp/iosApp/Networking/DeviceLoginModels.swift`:

```swift
/// Body for POST /api/v1/auth/device/approve (sent by an authenticated client).
struct DeviceApproveRequest: Codable {
    let code: String
}

/// Response from GET /api/v1/auth/device?code=<userCode>. All optional: we
/// only need the authoritative match code and a display name. Confirm field
/// names against silo-server (see Task 7 Step 1).
struct DeviceLookupResponse: Codable {
    let matchCode: String?
    let deviceName: String?
    let devicePlatform: String?
    let status: String?
}
```

- [ ] **Step 3: Add a per-server token accessor to TokenStore**

In `iosApp/iosApp/Networking/TokenStore.swift`, immediately after `getRefreshToken()` (line 110), add:

```swift
    /// Read a specific server's stored access token WITHOUT changing the
    /// active server. Used by companion pairing to approve a device on a
    /// server other than the one currently active.
    func getAccessToken(for serverId: String) -> String? {
        guard !serverId.isEmpty else { return nil }
        if serverId == activeServerId {
            ensureLoaded()
            return cachedAccessToken
        }
        return keychain.get(Self.accessTokenKey(for: serverId))
    }
```

- [ ] **Step 4: Write PairingDeviceAPI**

Create `iosApp/iosApp/Pairing/PairingDeviceAPI.swift`:

```swift
import Foundation

/// Device-authorization calls issued against an EXPLICIT server base URL,
/// independent of the app's single active server. Used by both pairing sides:
/// the Receiver calls start/poll against a pushed URL (no auth); the Companion
/// calls lookup/approve against a chosen server (bearer = that server's token).
struct PairingDeviceAPI {
    enum APIError: Error { case badURL, http(Int), decode }

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: Receiver (unauthenticated)

    func start(serverURL: String, deviceName: String, devicePlatform: String) async throws -> DeviceLoginStartResponse {
        try await post(serverURL, "/api/v1/auth/device/start", bearer: nil,
                       body: DeviceLoginStartRequest(deviceName: deviceName, devicePlatform: devicePlatform))
    }

    func poll(serverURL: String, deviceCode: String) async throws -> DeviceLoginPollResponse {
        try await post(serverURL, "/api/v1/auth/device/poll", bearer: nil,
                       body: DeviceLoginPollRequest(deviceCode: deviceCode))
    }

    // MARK: Companion (authenticated with the chosen server's token)

    func lookup(serverURL: String, bearer: String, userCode: String) async throws -> DeviceLookupResponse {
        try await get(serverURL, "/api/v1/auth/device", query: ["code": userCode], bearer: bearer)
    }

    func approve(serverURL: String, bearer: String, userCode: String) async throws {
        let _: EmptyResponse = try await post(serverURL, "/api/v1/auth/device/approve",
                                              bearer: bearer, body: DeviceApproveRequest(code: userCode))
    }

    private struct EmptyResponse: Codable {}

    // MARK: Transport

    private func get<R: Decodable>(_ serverURL: String, _ path: String, query: [String: String], bearer: String?) async throws -> R {
        guard var comps = URLComponents(string: serverURL.appending(path)) else { throw APIError.badURL }
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { throw APIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyHeaders(&request, bearer: bearer)
        return try await send(request)
    }

    private func post<B: Encodable, R: Decodable>(_ serverURL: String, _ path: String, bearer: String?, body: B) async throws -> R {
        guard let url = URL(string: serverURL.appending(path)) else { throw APIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        applyHeaders(&request, bearer: bearer)
        return try await send(request)
    }

    private func applyHeaders(_ request: inout URLRequest, bearer: String?) {
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let device = AppleDeviceIdentity.current
        request.setValue(device.id, forHTTPHeaderField: "X-Silo-Device-Id")
        request.setValue(device.name, forHTTPHeaderField: "X-Silo-Device-Name")
        request.setValue(device.platform, forHTTPHeaderField: "X-Silo-Device-Platform")
    }

    private func send<R: Decodable>(_ request: URLRequest) async throws -> R {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.http(-1) }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
        if R.self == EmptyResponse.self { return EmptyResponse() as! R }
        do { return try decoder.decode(R.self, from: data) }
        catch { throw APIError.decode }
    }
}
```

- [ ] **Step 5: Build both targets**

Run the two `xcodebuild build` commands from Task 6 Step 2. Expected: `** BUILD SUCCEEDED **` for both.

- [ ] **Step 6: Commit**

```bash
git add iosApp/iosApp/Networking/DeviceLoginModels.swift iosApp/iosApp/Networking/TokenStore.swift iosApp/iosApp/Pairing/PairingDeviceAPI.swift
git commit -m "Add PairingDeviceAPI + device approve/lookup models + per-server token accessor"
```

---

## Task 8: ReceiverPairingCoordinator (tvOS state machine)

**Files:**
- Create: `iosApp/iosApp/Pairing/Receiver/ReceiverPairingCoordinator.swift`

- [ ] **Step 1: Write the coordinator**

Create `iosApp/iosApp/Pairing/Receiver/ReceiverPairingCoordinator.swift`:

```swift
#if os(tvOS)
import Foundation
import OSLog

/// Drives the TV side of a pairing session over an accepted `PairingSession`.
/// Persist-on-success: a pushed server URL is written to ServerRegistry /
/// TokenStore ONLY after its poll returns tokens (design spec §5/§6).
@MainActor
@Observable
final class ReceiverPairingCoordinator {
    enum State: Equatable {
        case idle
        /// Showing the match code for the named server while the phone approves.
        case awaitingApproval(serverName: String, matchCode: String)
        case signedIn(serverCount: Int)
        case failed(String)
    }

    private(set) var state: State = .idle

    private let api: PairingDeviceAPI
    private let onAuthenticated: () -> Void
    private var signedInCount = 0
    /// The in-flight start+poll for the current server. Run as a separate
    /// cancellable task so the stream reader below is NEVER blocked by polling.
    private var pollTask: Task<Void, Never>?
    /// True while `pollTask` is active. The protocol is one-server-at-a-time;
    /// an overlapping PushServer is ignored.
    private var isPolling = false
    private static let logger = Logger(subsystem: "org.siloserver.silo", category: "pairing.receiver")

    /// - Parameter onAuthenticated: called on the main actor after at least
    ///   one server is signed in, to advance the router to profile selection.
    init(api: PairingDeviceAPI = PairingDeviceAPI(), onAuthenticated: @escaping () -> Void) {
        self.api = api
        self.onAuthenticated = onAuthenticated
    }

    /// Consume the session stream. The stream is ALWAYS being read here; each
    /// server's start+poll runs as a cancellable child task so a Cancel message
    /// or a dropped connection aborts the attempt immediately rather than after
    /// the poll loop finishes (design spec §7).
    func run(session: PairingSession, stream: AsyncThrowingStream<PairingMessage, Error>) async {
        let device = AppleDeviceIdentity.current
        do {
            try await session.send(.hello(
                tvName: device.name,
                tvDeviceId: device.id,
                state: .setup,
                supportedVersions: [PairingProtocol.version]
            ))
            for try await message in stream {
                switch message {
                case let .pushServer(serverURL, serverName):
                    guard !isPolling else { break } // one at a time; ignore overlap
                    isPolling = true
                    pollTask = Task { [weak self] in
                        await self?.handlePushServer(serverURL: serverURL, serverName: serverName, session: session)
                        self?.isPolling = false
                    }
                case .done:
                    await pollTask?.value // let the last server finish persisting
                    if signedInCount > 0 { onAuthenticated() }
                    await teardown(session: session, resetState: false)
                    return
                case let .cancel(reason):
                    Self.logger.notice("peer cancelled: \(reason, privacy: .public)")
                    await teardown(session: session, resetState: true)
                    return
                default:
                    break // Receiver only consumes phone→TV message kinds.
                }
            }
            // Stream ended without a Done (peer closed the connection).
            await teardown(session: session, resetState: true)
        } catch {
            // Stream threw: the connection dropped mid-session.
            Self.logger.error("session error: \(String(describing: error), privacy: .public)")
            await teardown(session: session, resetState: true)
        }
    }

    /// Cancel any in-flight poll, close the session, and (optionally) return the
    /// UI to idle so the advertiser can accept a fresh connection.
    private func teardown(session: PairingSession, resetState: Bool) async {
        pollTask?.cancel()
        await session.close()
        if resetState { state = .idle }
    }

    private func handlePushServer(serverURL: String, serverName: String?, session: PairingSession) async {
        let normalized = ServerRegistry.normalize(url: serverURL)
        let device = AppleDeviceIdentity.current
        do {
            // 1. Start device auth against the PENDING candidate (not persisted).
            let started = try await api.start(serverURL: normalized, deviceName: device.name, devicePlatform: device.platform)
            state = .awaitingApproval(serverName: serverName ?? normalized, matchCode: started.matchCode)
            try await session.send(.deviceStarted(serverURL: normalized, userCode: started.userCode, matchCode: started.matchCode))

            // 2. Poll until approved or the device code expires.
            let deadline = Date().addingTimeInterval(TimeInterval(started.expiresIn))
            while Date() < deadline {
                try Task.checkCancellation() // abort promptly on peer cancel / drop
                let poll = try await api.poll(serverURL: normalized, deviceCode: started.deviceCode)
                switch poll.status {
                case "approved":
                    guard let access = poll.accessToken, let refresh = poll.refreshToken else {
                        throw PairingDeviceAPI.APIError.decode
                    }
                    await persistOnSuccess(url: normalized, fetchedName: serverName, access: access, refresh: refresh)
                    signedInCount += 1
                    state = .signedIn(serverCount: signedInCount)
                    try await session.send(.serverResult(serverURL: normalized, status: .signedIn, error: nil))
                    return
                case "denied", "expired", "consumed":
                    throw PairingDeviceAPI.APIError.http(409)
                default: // "pending"
                    try await Task.sleep(for: .seconds(max(1, poll.pollAfter ?? started.interval)))
                }
            }
            throw PairingDeviceAPI.APIError.http(408) // local timeout
        } catch {
            // Persist-on-success: nothing was written, so nothing to roll back.
            if Task.isCancelled {
                // Peer cancelled or the connection dropped (teardown already reset
                // the UI). The peer is gone, so send nothing.
                Self.logger.notice("attempt for \(normalized, privacy: .public) cancelled")
                return
            }
            Self.logger.error("server \(normalized, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            state = .failed(serverName ?? normalized)
            try? await session.send(.serverResult(serverURL: normalized, status: .failed, error: "auth_failed"))
        }
    }

    /// Commit the now-trusted server + tokens. Runs only after a successful poll.
    private func persistOnSuccess(url: String, fetchedName: String?, access: String, refresh: String) async {
        let id = ServerRegistry.serverId(for: url)
        let entry = ServerEntry(id: id, url: url, fetchedName: fetchedName, userOverrideName: nil, profileId: nil, lastUsedAt: Date())
        ServerRegistry.shared.addOrUpdate(entry)
        await TokenStore.shared.setServerUrl(url)
        await TokenStore.shared.switchActiveServer(serverId: id)
        await TokenStore.shared.saveTokens(accessToken: access, refreshToken: refresh)
        await ServerRegistry.shared.switchTo(serverId: id)
    }
}
#endif
```

- [ ] **Step 2: Build the tvOS target**

Run:
```bash
cd iosApp && xcodegen generate && xcodebuild build -project Silo.xcodeproj -scheme SiloTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add iosApp/iosApp/Pairing/Receiver/ReceiverPairingCoordinator.swift iosApp/Silo.xcodeproj
git commit -m "Add ReceiverPairingCoordinator (persist-on-success)"
```

---

## Task 9: TVPairingAdvertiser + Receiver UI (tvOS)

**Files:**
- Create: `iosApp/iosApp/Pairing/Receiver/TVPairingAdvertiser.swift`
- Create: `iosApp/iosApp/Pairing/Receiver/TVPairingReceiverView.swift`
- Modify: `iosApp/iosApp/Screens/Auth/TVServerSetupView.swift`

- [ ] **Step 1: Write the advertiser**

Create `iosApp/iosApp/Pairing/Receiver/TVPairingAdvertiser.swift`:

```swift
#if os(tvOS)
import Foundation
import Network
import OSLog

/// Advertises `_silopair._tcp` on the LAN and hands the first inbound
/// connection to a `PairingSession`. One connection at a time; later peers
/// are rejected as busy.
@MainActor
final class TVPairingAdvertiser {
    private var listener: NWListener?
    private var busy = false
    private static let logger = Logger(subsystem: "org.siloserver.silo", category: "pairing.advertiser")

    /// - Parameter onConnection: called on the main actor with an opened
    ///   session + its inbound stream for the coordinator to drive.
    func start(onConnection: @escaping (PairingSession, AsyncThrowingStream<PairingMessage, Error>) -> Void) {
        stop()
        let device = AppleDeviceIdentity.current
        let txt = NWTXTRecord([
            "v": String(PairingProtocol.version),
            "name": device.name,
            "id": device.id,
            "st": PairingReceiverState.setup.rawValue
        ])
        do {
            let listener = try NWListener(using: PairingSession.tlsParameters())
            listener.service = NWListener.Service(name: device.name, type: PairingProtocol.serviceType, txtRecord: txt)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self else { return }
                    if self.busy { connection.cancel(); return }
                    self.busy = true
                    let session = PairingSession(connection: connection)
                    let stream = await session.open()
                    onConnection(session, stream)
                }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    Self.logger.error("listener failed: \(String(describing: error), privacy: .public)")
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            Self.logger.error("failed to start listener: \(String(describing: error), privacy: .public)")
        }
    }

    /// Allow a new connection after the previous session ended.
    func release() { busy = false }

    func stop() {
        listener?.cancel()
        listener = nil
        busy = false
    }
}
#endif
```

- [ ] **Step 2: Write the Receiver view**

Create `iosApp/iosApp/Pairing/Receiver/TVPairingReceiverView.swift`:

```swift
#if os(tvOS)
import SwiftUI

/// The "Set up with iPhone" panel shown on the tvOS onboarding screen.
/// Advertises on the LAN and, once a phone connects, shows the match code to
/// confirm. Falls through to the host screen's QR / manual entry otherwise.
struct TVPairingReceiverView: View {
    var router: AppRouter

    @State private var advertiser = TVPairingAdvertiser()
    @State private var coordinator: ReceiverPairingCoordinator?

    var body: some View {
        VStack(spacing: 28) {
            switch coordinator?.state ?? .idle {
            case .idle:
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 64, weight: .semibold))
                Text("Set up with iPhone")
                    .font(.system(size: 40, weight: .bold))
                Text("Open Silo on your iPhone on the same Wi-Fi. It will offer to set up this Apple TV.")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 720)
            case let .awaitingApproval(serverName, matchCode):
                Text("Confirm on your iPhone")
                    .font(.system(size: 40, weight: .bold))
                Text(matchCode)
                    .font(.system(size: 72, weight: .heavy, design: .rounded))
                    .textCase(.uppercase)
                Text("Make sure your iPhone shows this same code for \(serverName).")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 720)
            case let .signedIn(count):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                Text(count == 1 ? "Signed in" : "Signed in to \(count) servers")
                    .font(.system(size: 40, weight: .bold))
            case let .failed(name):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.yellow)
                Text("Couldn’t set up \(name). Try again, or use the QR code.")
                    .font(.system(size: 24))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 720)
            }
        }
        .task { start() }
        .onDisappear { advertiser.stop() }
    }

    private func start() {
        let coordinator = ReceiverPairingCoordinator { router.showProfileSelection() }
        self.coordinator = coordinator
        advertiser.start { session, stream in
            Task {
                await coordinator.run(session: session, stream: stream)
                advertiser.release()
            }
        }
    }
}
#endif
```

- [ ] **Step 3: Present the Receiver view from the onboarding screen**

In `iosApp/iosApp/Screens/Auth/TVServerSetupView.swift`, add a way to reach `TVPairingReceiverView(router: router)` — e.g. a "Set up with iPhone" button that flips a `@State private var showPhoneSetup = false` and presents the view in a `.fullScreenCover` or inline branch. Keep the change minimal and additive so it composes with the in-flight Aurora edits; do not restructure the existing manual-entry/QR layout.

- [ ] **Step 4: Build the tvOS target**

Run the SiloTV `xcodebuild build` command from Task 8 Step 2. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add iosApp/iosApp/Pairing/Receiver/ iosApp/iosApp/Screens/Auth/TVServerSetupView.swift iosApp/Silo.xcodeproj
git commit -m "Add tvOS pairing advertiser + receiver UI"
```

---

## Task 10: CompanionPairingCoordinator (iOS state machine)

**Files:**
- Create: `iosApp/iosApp/Pairing/Companion/CompanionPairingCoordinator.swift`

- [ ] **Step 1: Write the coordinator**

Create `iosApp/iosApp/Pairing/Companion/CompanionPairingCoordinator.swift`:

```swift
#if os(iOS)
import Foundation
import OSLog

/// Drives the phone side: connect to a discovered TV, let the user pick which
/// servers to push, confirm the (server-authoritative) match code once, then
/// approve each chosen server. Confirm-once multi-server is an accepted v1
/// risk — see the design spec §6 "Accepted risk".
@MainActor
@Observable
final class CompanionPairingCoordinator {
    enum State: Equatable {
        case connecting
        /// Connected; offer the phone's servers (those with a stored token).
        case pickServers(tvName: String, servers: [ServerEntry])
        /// Awaiting the user's match-code confirmation for the first server.
        case confirmMatch(tvName: String, serverName: String, matchCode: String)
        /// Pushing/approving the remaining servers after confirmation.
        case working(progress: String)
        case finished(signedIn: [String], failed: [String])
        case error(String)
    }

    private(set) var state: State = .connecting

    private let api: PairingDeviceAPI
    private let session: PairingSession
    private let stream: AsyncThrowingStream<PairingMessage, Error>
    private var iterator: AsyncThrowingStream<PairingMessage, Error>.AsyncIterator

    private var tvName = "Apple TV"
    private var queue: [ServerEntry] = []
    private var confirmed = false
    private var signedIn: [String] = []
    private var failed: [String] = []
    private static let logger = Logger(subsystem: "org.siloserver.silo", category: "pairing.companion")

    init(api: PairingDeviceAPI = PairingDeviceAPI(), session: PairingSession, stream: AsyncThrowingStream<PairingMessage, Error>) {
        self.api = api
        self.session = session
        self.stream = stream
        self.iterator = stream.makeAsyncIterator()
    }

    /// Read the TV's `Hello` and present the server picker.
    func begin() async {
        do {
            guard case let .hello(name, _, _, supported)? = try await iterator.next() else {
                state = .error("No response from the Apple TV."); return
            }
            guard supported.contains(PairingProtocol.version) else {
                state = .error("Update Silo on one of your devices to continue."); return
            }
            tvName = name
            let servers = await serversWithTokens()
            guard !servers.isEmpty else {
                state = .error("Sign in to a server on this iPhone first."); return
            }
            state = .pickServers(tvName: name, servers: servers)
        } catch {
            state = .error("Connection lost.")
        }
    }

    /// User tapped a set of servers to push (order = approval order).
    func pushSelected(_ servers: [ServerEntry]) async {
        queue = servers
        await pushNext()
    }

    /// User confirmed the displayed match code matches the TV.
    func confirmMatch() async {
        confirmed = true
        if case let .confirmMatch(_, _, _) = state, let current = queue.first {
            await approveAndAdvance(current)
        }
    }

    /// User said the codes don't match — abort.
    func declineMatch() async {
        try? await session.send(.cancel(reason: "match_declined"))
        await session.close()
        state = .error("Codes didn’t match — setup cancelled.")
    }

    func cancel() async {
        try? await session.send(.cancel(reason: "user_cancelled"))
        await session.close()
    }

    // MARK: - Internals

    private func pushNext() async {
        guard let server = queue.first else { await finish(); return }
        state = .working(progress: "Setting up \(server.displayName)…")
        do {
            try await session.send(.pushServer(serverURL: server.url, serverName: server.displayName))
            guard case let .deviceStarted(_, userCode, _)? = try await nextRelevant() else {
                fail(server); await pushNext(); return
            }
            // Display the SERVER's authoritative match code, not the channel's.
            let token = await TokenStore.shared.getAccessToken(for: server.id) ?? ""
            let lookup = try await api.lookup(serverURL: server.url, bearer: token, userCode: userCode)
            let serverMatch = lookup.matchCode ?? ""
            pendingUserCode = userCode
            if confirmed {
                await approveAndAdvance(server)
            } else {
                state = .confirmMatch(tvName: tvName, serverName: server.displayName, matchCode: serverMatch)
            }
        } catch {
            fail(server); await pushNext()
        }
    }

    private var pendingUserCode: String?

    private func approveAndAdvance(_ server: ServerEntry) async {
        state = .working(progress: "Approving \(server.displayName)…")
        do {
            let token = await TokenStore.shared.getAccessToken(for: server.id) ?? ""
            try await api.approve(serverURL: server.url, bearer: token, userCode: pendingUserCode ?? "")
            // Wait for the TV to report it minted tokens.
            if case let .serverResult(_, status, _)? = try await nextRelevant(), status == .signedIn {
                signedIn.append(server.displayName)
            } else {
                failed.append(server.displayName)
            }
        } catch {
            failed.append(server.displayName)
        }
        queue.removeFirst()
        await pushNext()
    }

    private func finish() async {
        try? await session.send(.done)
        await session.close()
        state = .finished(signedIn: signedIn, failed: failed)
    }

    private func fail(_ server: ServerEntry) { failed.append(server.displayName) }

    /// Pull the next deviceStarted/serverResult, ignoring anything else.
    private func nextRelevant() async throws -> PairingMessage? {
        while let message = try await iterator.next() {
            switch message {
            case .deviceStarted, .serverResult: return message
            case .cancel: return nil
            default: continue
            }
        }
        return nil
    }

    /// The phone's servers that currently have a stored access token.
    private func serversWithTokens() async -> [ServerEntry] {
        var result: [ServerEntry] = []
        for entry in ServerRegistry.shared.sortedEntries {
            if await TokenStore.shared.getAccessToken(for: entry.id) != nil { result.append(entry) }
        }
        return result
    }
}
#endif
```

- [ ] **Step 2: Build the iOS target**

Run the Silo `xcodebuild build` command from Task 6 Step 2. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add iosApp/iosApp/Pairing/Companion/CompanionPairingCoordinator.swift iosApp/Silo.xcodeproj
git commit -m "Add CompanionPairingCoordinator (confirm-once, server-authoritative match code)"
```

---

## Task 11: TVPairingBrowser (iOS discovery)

**Files:**
- Create: `iosApp/iosApp/Pairing/Companion/TVPairingBrowser.swift`

- [ ] **Step 1: Write the browser**

Create `iosApp/iosApp/Pairing/Companion/TVPairingBrowser.swift`:

```swift
#if os(iOS)
import Foundation
import Network

/// A discovered Apple TV waiting to be set up.
struct DiscoveredTV: Identifiable, Equatable {
    let id: String          // TXT `id` (stable device id), or endpoint string.
    let name: String        // TXT `name`.
    let state: PairingReceiverState
    let endpoint: NWEndpoint
    static func == (a: DiscoveredTV, b: DiscoveredTV) -> Bool { a.id == b.id }
}

/// Browses `_silopair._tcp` and publishes discovered TVs. Drives the
/// hands-off banner. Owns the Local Network permission prompt (triggered on
/// first browse).
@MainActor
@Observable
final class TVPairingBrowser {
    private(set) var found: [DiscoveredTV] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: PairingProtocol.serviceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.found = results.compactMap(Self.makeTV) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        found = []
    }

    private static func makeTV(_ result: NWBrowser.Result) -> DiscoveredTV? {
        guard case let .bonjour(txt) = result.metadata else { return nil }
        let name = txt["name"] ?? "Apple TV"
        let id = txt["id"] ?? "\(result.endpoint)"
        let state = PairingReceiverState(rawValue: txt["st"] ?? "setup") ?? .setup
        return DiscoveredTV(id: id, name: name, state: state, endpoint: result.endpoint)
    }
}
#endif
```

- [ ] **Step 2: Build the iOS target**

Run the Silo `xcodebuild build` command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add iosApp/iosApp/Pairing/Companion/TVPairingBrowser.swift iosApp/Silo.xcodeproj
git commit -m "Add TVPairingBrowser LAN discovery"
```

---

## Task 12: TVPairingView (iOS pairing flow UI)

**Files:**
- Create: `iosApp/iosApp/Pairing/Companion/TVPairingView.swift`

- [ ] **Step 1: Write the view**

Create `iosApp/iosApp/Pairing/Companion/TVPairingView.swift`:

```swift
#if os(iOS)
import SwiftUI

/// Modal flow after the user taps "Set up" on a discovered TV: connect, pick
/// servers, confirm the match code, watch progress.
struct TVPairingView: View {
    let tv: DiscoveredTV
    var onClose: () -> Void

    @State private var coordinator: CompanionPairingCoordinator?
    @State private var selection: Set<String> = []

    var body: some View {
        NavigationStack {
            Group {
                switch coordinator?.state ?? .connecting {
                case .connecting:
                    ProgressView("Connecting to \(tv.name)…")
                case let .pickServers(_, servers):
                    serverPicker(servers)
                case let .confirmMatch(_, serverName, matchCode):
                    confirm(serverName: serverName, matchCode: matchCode)
                case let .working(progress):
                    ProgressView(progress)
                case let .finished(signedIn, failed):
                    finished(signedIn: signedIn, failed: failed)
                case let .error(message):
                    errorState(message)
                }
            }
            .navigationTitle("Set up Apple TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { close() } } }
        }
        .task {
            let session = PairingSession(endpoint: tv.endpoint)
            let stream = await session.open()
            let coordinator = CompanionPairingCoordinator(session: session, stream: stream)
            self.coordinator = coordinator
            await coordinator.begin()
        }
    }

    @ViewBuilder private func serverPicker(_ servers: [ServerEntry]) -> some View {
        List {
            Section("Which servers should this TV use?") {
                ForEach(servers) { server in
                    Button {
                        if selection.contains(server.id) { selection.remove(server.id) } else { selection.insert(server.id) }
                    } label: {
                        HStack {
                            Text(server.displayName)
                            Spacer()
                            if selection.contains(server.id) { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            Button("Continue") {
                let chosen = servers.filter { selection.contains($0.id) }
                Task { await coordinator?.pushSelected(chosen) }
            }
            .disabled(selection.isEmpty)
        }
    }

    @ViewBuilder private func confirm(serverName: String, matchCode: String) -> some View {
        VStack(spacing: 24) {
            Text("Does your Apple TV show this code?").font(.headline)
            Text(matchCode).font(.system(size: 44, weight: .heavy, design: .rounded)).textCase(.uppercase)
            Text("For \(serverName)").foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button("Doesn’t match") { Task { await coordinator?.declineMatch() } }
                    .buttonStyle(.bordered)
                Button("Yes, set up") { Task { await coordinator?.confirmMatch() } }
                    .buttonStyle(.borderedProminent)
            }
        }.padding()
    }

    @ViewBuilder private func finished(signedIn: [String], failed: [String]) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
            Text(signedIn.isEmpty ? "Nothing set up" : "Set up \(signedIn.joined(separator: ", "))").font(.headline)
            if !failed.isEmpty { Text("Couldn’t set up: \(failed.joined(separator: ", "))").foregroundStyle(.secondary) }
            Button("Done") { close() }.buttonStyle(.borderedProminent)
        }.padding()
    }

    @ViewBuilder private func errorState(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
            Text(message).multilineTextAlignment(.center)
            Button("Close") { close() }.buttonStyle(.borderedProminent)
        }.padding()
    }

    private func close() {
        Task { await coordinator?.cancel(); onClose() }
    }
}
#endif
```

- [ ] **Step 2: Build the iOS target.** Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add iosApp/iosApp/Pairing/Companion/TVPairingView.swift iosApp/Silo.xcodeproj
git commit -m "Add iOS TVPairingView flow"
```

---

## Task 13: SetUpTVBanner + mount it (iOS hands-off detection)

**Files:**
- Create: `iosApp/iosApp/Pairing/Companion/SetUpTVBanner.swift`
- Modify: `iosApp/iosApp/ContentView.swift`

- [ ] **Step 1: Write the banner overlay**

Create `iosApp/iosApp/Pairing/Companion/SetUpTVBanner.swift`:

```swift
#if os(iOS)
import SwiftUI

/// App-wide overlay: when a blank Apple TV is discovered on the LAN, slide in
/// a "Set up Apple TV" banner. Tapping it opens `TVPairingView`. This is the
/// hands-off detection surface.
struct SetUpTVBannerModifier: ViewModifier {
    @State private var browser = TVPairingBrowser()
    @State private var activeTV: DiscoveredTV?
    @State private var dismissed: Set<String> = []

    func body(content: Content) -> some View {
        content
            .task { browser.start() }
            .safeAreaInset(edge: .top) {
                if let tv = candidate {
                    banner(tv)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.3), value: candidate)
            .sheet(item: $activeTV) { tv in
                TVPairingView(tv: tv) { activeTV = nil }
            }
    }

    private var candidate: DiscoveredTV? {
        browser.found.first { $0.state == .setup && !dismissed.contains($0.id) }
    }

    @ViewBuilder private func banner(_ tv: DiscoveredTV) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "appletv.fill")
            VStack(alignment: .leading) {
                Text("Set up \(tv.name)?").font(.subheadline.bold())
                Text("Sign this Apple TV in from your iPhone").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Set Up") { activeTV = tv }.buttonStyle(.borderedProminent).controlSize(.small)
            Button { dismissed.insert(tv.id) } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }
}

extension View {
    func setUpTVBanner() -> some View { modifier(SetUpTVBannerModifier()) }
}
#endif
```

- [ ] **Step 2: Mount the banner on the iOS root**

In `iosApp/iosApp/ContentView.swift`, on the root `Group` in `body` (the one that already has `.preferredColorScheme(.dark)` and the `.onReceive` deep-link handlers), add a platform-guarded modifier. Locate `.preferredColorScheme(.dark)` and add immediately below it:

```swift
        #if os(iOS)
        .setUpTVBanner()
        #endif
```

- [ ] **Step 3: Build the iOS target.** Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add iosApp/iosApp/Pairing/Companion/SetUpTVBanner.swift iosApp/iosApp/ContentView.swift iosApp/Silo.xcodeproj
git commit -m "Add iOS Set-Up-TV discovery banner"
```

---

## Task 14: Manual end-to-end verification (the coordinators' acceptance test)

There is no automated harness for the stateful flow; verify on real devices/simulators on one LAN.

- [ ] **Step 1: Install both apps**

Build & run `Silo` on an iPhone (or iOS simulator) and `SiloTV` on an Apple TV (or tvOS simulator) on the **same Wi-Fi**. Sign the iPhone into at least one Silo server (two, to exercise multi-server).

- [ ] **Step 2: Happy path (single server)**
  - On the Apple TV, open onboarding → "Set up with iPhone".
  - On the iPhone (app foreground), confirm the "Set up <TV name>?" banner appears within a few seconds; tap **Set Up**, allow the Local Network prompt.
  - Pick one server → Continue. Confirm the iPhone and TV show the **same** match code; tap "Yes, set up".
  - Expect: the TV advances to "Who's watching?"; the iPhone shows "Set up <server>". Verify in the server's session list (`GET /auth/sessions`) that a new session named for the TV exists.

- [ ] **Step 3: Multi-server pick**
  - Repeat, selecting two servers. Confirm the match code once. Expect both servers signed in on the TV (`ServerRegistry` shows two entries) and a per-server result summary on the phone.

- [ ] **Step 4: Persist-on-success**
  - Start setup, reach the match-code screen, then tap **Cancel** on the phone (or background it). Expect the TV returns to the idle "Set up with iPhone" state and `ServerRegistry` on the TV gains **no** entry. Repeat killing the connection mid-poll; confirm no partial server entry persists.

- [ ] **Step 5: Match-code decline**
  - At the confirm screen, tap "Doesn’t match". Expect setup aborts cleanly and can be retried.

- [ ] **Step 6: Fallbacks**
  - Deny the Local Network permission; confirm the banner never appears and the TV's QR / manual entry still work.

- [ ] **Step 7: Commit a note**

```bash
git commit --allow-empty -m "Verify companion pairing end-to-end on LAN"
```

---

## Self-Review (completed during planning)

**Spec coverage:** §4 components → PairingProtocol (T2), PairingSession+frame (T4/T6), SiloAPI approve/lookup → PairingDeviceAPI (T7), Receiver coordinator+advertiser+UI (T8/T9), Companion coordinator+browser+banner+view (T10–T13). §5 flow + confirm-once → T10. §6 persist-on-success → T8; server-authoritative match code → T10; opportunistic TLS → T6. §7 edge cases → coordinators + T14. §8 Info.plist/permissions → T1. §9 testing → T3/T5 (pure logic) + T14 (manual). All spec sections map to a task.

**Type consistency:** `PairingMessage` cases and field names are identical across T2 (definition), T8/T10 (producers/consumers). `PairingSession.open()` returns `AsyncThrowingStream<PairingMessage, Error>` and is consumed with that exact type in T8–T13. `PairingDeviceAPI` method names (`start/poll/lookup/approve`) match their call sites in T8/T10. `ServerEntry`, `ServerRegistry.{normalize,serverId,addOrUpdate,switchTo,sortedEntries}`, `TokenStore.{getAccessToken(for:),saveTokens,switchActiveServer,setServerUrl}`, `AppRouter.showProfileSelection()`, and `AppleDeviceIdentity.current.{id,name,platform}` all match the verbatim signatures extracted from the codebase.

**Known verification point (not a placeholder):** T7 S1 confirms the `GET /auth/device` response field names against silo-server; `DeviceLookupResponse` fields are decoded leniently (all optional) so a name mismatch degrades to an empty match code rather than a crash, and is caught in T14 S2.
