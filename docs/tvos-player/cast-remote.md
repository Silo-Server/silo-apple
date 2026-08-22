> [!WARNING]
> **Historical pre-AetherEngine archive.** This document describes the removed custom-player architecture or its pre-migration validation model. It is retained for history only and must not be used as current implementation guidance. See the [AetherEngine-only replacement specification](aetherengine-replacement-spec.md).

# Silo Cast Remote (iOS → tvOS)

Peer-to-peer LAN remote control: an iPhone discovers a Silo Apple TV on the
local network, connects directly to it, and drives playback (launch, transport,
tracks, quality, speed, aspect/HDR, **volume/mute**, **next episode**) from a
native now-playing screen. Control stays LAN-local; launching new content uses
the phone's Silo server to authorize a playback-scoped TV session. Apple and
Android use the same wire protocol.

## Architecture

| Layer | Type | Role |
|-------|------|------|
| Wire protocol | `Control/SiloControlProtocol.swift` | Message enum + Codable framing; v1/v2 negotiation, `serviceType = _silocast._tcp` |
| Transport | `Control/SiloControlSession.swift` | `actor` over `NWConnection` (TLS-PSK), TLV-framed JSON, ordered outbound queue |
| Phone controller | `Control/iOS/SiloControlClient.swift` | Connect, negotiate, authorize handoff, heartbeat, reconnect, command send |
| TV receiver | `Control/tvOS/TVControlReceiver.swift` | Advertise, negotiate, authorize, launch, apply controls, broadcast state |
| Temporary identity | `Control/tvOS/RemotePlaybackIdentityManager.swift` | Explicit device-login exchange, in-memory auth overlay, logout and restore |

Player integration: the tvOS player registers with `TVCastReceiver` on appear
(`PlayerView`); controls are applied via `PlayerViewModel.applySiloControlCommand(_:)`
and state is published via `PlayerViewModel.makeSiloControlPlaybackState(contentId:)`.

## Message protocol

`SiloCastMessage` (Codable, tagged by `type`, carries protocol `v`):

- `hello` — identity exchange (role phone/tv, deviceName/id, serverId/Name, supportedVersions)
- `handoff_offer` — phone offers its normalized server ID/URL and active profile
- `handoff_challenge` — TV returns the server-issued user/match code
- `handoff_ready` — TV confirms that its temporary phone profile is active
- `handoff_cancel` — either peer cancels a stale, denied, or failed handoff
- `launch` — phone asks the TV to start playing a `SiloCastPlaybackRequest`
- `control` — `SiloCastControlCommand` (play/pause/seek/stop, select audio/subtitle, speed, quality, video gravity, HDR, **set_volume**, **set_muted**, **play_next**)
- `state` — `SiloCastPlaybackState` snapshot (TV → phone, ~2 Hz while playing)
- `error` — coded error (`server_mismatch`, `unauthorized`, `player_not_ready`, …)
- `ping` / `pong` — heartbeat
- `close` — graceful disconnect

### v2 identity and lifecycle

Opening the remote alone never changes identity. A same-server control-only
connection controls the TV-owned playback already on screen. Before an updated
phone launches new content, it must negotiate v2 and complete the handoff:

1. The TV starts a `remote_playback`, temporary device login directly against
   the phone's offered server URL. No bearer or profile credentials cross LAN.
2. The signed-in phone verifies the match code and approves with its current
   profile headers. This also proves an already-unlocked PIN profile.
3. The TV polls for a dedicated session/profile token and installs it in a
   process-only `TokenStore` overlay. Keychain and saved server entries are not
   modified.
4. Only after `handoff_ready` does the phone send `launch`. Progress, resume,
   permissions, and preferences then resolve under the phone profile.
5. Player teardown performs final progress work, best-effort logout, cache
   clearing, and restoration of the TV's saved identity. Socket loss alone does
   not restore; playback lifecycle is authoritative. Ready-without-launch is
   abandoned after 60 seconds, and the server caps the session at 24 hours.

When the player opens, the TV shows a non-focusable six-second notice naming the
phone profile and device (for example, **Playing as Alex — From Nathan's
iPhone**). Cross-server launches also include the temporary server name. The
profile name is display metadata only; authorization remains bound to the
server-approved profile ID.

Updated phones refuse to launch through v1 receivers because v1 cannot prove
phone-owned identity. Updated receivers still accept v1 launches from older
phones during the compatibility window; those retain the legacy TV-owned
identity behavior.

### Ordering
All non-hello sends go through `SiloCastSession.enqueue(_:)`, drained by a single
internal task, so state snapshots and commands cannot reorder on the wire (a
stale snapshot can never overwrite a fresh one). The initial `hello` uses the
awaitable `send(_:)` and is always sent before any `enqueue`.

### Liveness, takeover, reconnect
- **Heartbeat:** each side pings every 3 s and tears down after ~12 s without
  the corresponding `pong`; unrelated inbound traffic does not mask a broken
  receive path.
- **Takeover:** a new controller connection evicts the existing one
  (`closeActiveSession`) rather than being rejected — a dropped phone can always
  reconnect, and there is no single-session lockout.
- **Auto-reconnect:** on a transport drop the phone shows "Reconnecting…" and
  retries with 1–5 s backoff (up to 5 attempts), preserving the target. An
  intentional `.close` (takeover or user disconnect) clears the target so it
  does **not** reconnect.
- **Graceful close:** intentional disconnects enqueue `.close` (ordered after
  pending sends) then tear down after a bounded 300 ms flush window, so the peer
  gets a clean app-level signal without the close being able to hang.
- **Re-advertise:** the TV re-advertises its Bonjour service when the active
  server changes, so phones on the new server can find it (and stale phones cannot).

## Volume control — important platform constraint

tvOS exposes **no system/TV-volume API**: `MPVolumeView` is not in the tvOS SDK
and `AVAudioSession.outputVolume` is read-only. The remote therefore controls
**per-player playback gain**, not system volume:

- **`PlayerCore` route** (custom decoder → `AVAudioEngine`): gain is applied to
  the engine's `mainMixerNode.outputVolume`. This always works because PlayerCore
  decodes to PCM. The gain is re-applied after every engine reset/route change so
  it survives format changes.
- **`AVPlayer` route:** gain is applied via `avPlayer.volume`. This attenuates
  **decoded PCM only** — it is a **no-op when audio is bitstreamed/passthrough**
  (Dolby Digital/Atmos to a receiver) or routed via AirPlay. User-mute is modeled
  as `volume = 0`, **never** `avPlayer.isMuted` (that property is reserved for the
  player's initial-video-display gate and would clobber a user mute).

Consequences, surfaced honestly in the UI:
- The slider attenuates **0–100 % of the current TV volume** and **cannot boost
  above it** (there is no amplification).
- The cast state echoes the *applied* gain value, which on a passthrough AVPlayer
  route may not correspond to an audible change.

## Security — known limitation (deferred)

The cast channel uses **TLS-PSK with a single static pre-shared key compiled into
every build** (`SiloControlSession.tlsParameters()`). The channel is therefore
**encrypted but not peer-authenticated**. v2 improves credential handling and
binds the temporary TV session to a server-approved phone user/profile, but a
Silo-capable device on the LAN can still initiate a connection or handoff. The
authenticated phone approval prevents that peer from receiving another user's
credentials without the user's participation; it does not cryptographically
pair the LAN devices.

**Deferred follow-up (recommended):** derive a per-pair / per-server secret from
the existing companion-pairing trust (`_silopair`, see the pairing flow) and bind
it into the cast `hello` handshake (e.g. HMAC the hello/launch with the per-pair
secret, or a one-time PIN echoed from the TV), so only paired devices can control
the TV. Until then, treat LAN access as the trust boundary.

## Testing

Protocol negotiation, v2 message round-trips, and `RemotePlaybackClock`
interpolation/optimistic math live in `iosApp/Tests/SiloControlTests.swift` and
run through the `SiloTests` target.
End-to-end behavior is verified with two simulators sharing the host network
(see the `companion-pairing-sim-test` notes for the Bonjour/TLS sim-to-sim setup).
