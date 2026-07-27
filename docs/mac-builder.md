# Mac Builder — building and testing the Apple clients from a Linux host

Most Silo development happens on a Linux workstation. Xcode does not run there, so the Apple
clients are built on a dedicated Mac ("mac-builder") that is driven remotely — including by
coding agents, which get structured build/test/device tools rather than raw SSH.

This document is the whole workflow: how the Mac is wired up, how source gets to it, how to
build/test each platform, and the traps that cost the most time.

Placeholders used throughout — substitute your own:

| Placeholder | Meaning | Example |
|---|---|---|
| `mac-builder` | SSH host alias for the Mac | any alias you like |
| `<mac-user>` | macOS account name on the Mac | `builder` |
| `<TEAM_ID>` | Apple Developer team ID | `ABCDE12345` |
| `<DEVICE_ID>` | `devicectl` device UUID | discover it, never hardcode from this doc |

## The shape of it

```
Linux workstation                                   Mac mini (Xcode)
─────────────────                                   ────────────────
source of truth  ──── rsync / git apply ──────────►  ~/silo-apple-deploy
agent / editor   ──── ssh (stdio) ────────────────►  xcodebuildmcp  ──► xcodebuild
                                                                    ──► xcrun devicectl ──► iPhone / Apple TV
                 ──── ssh (ad hoc) ───────────────►  shell for signing, logs, devicectl
```

Two independent channels reach the Mac, and the difference between them matters (see
[Signing and the keychain trap](#signing-and-the-keychain-trap)):

1. **XcodeBuildMCP over SSH** — a long-lived stdio MCP server. Structured tools for build, test,
   install, launch, simulator control, UI automation, and LLDB. This is the preferred channel.
2. **Ad-hoc `ssh mac-builder '<command>'`** — for anything MCP does not cover: `xcodegen`,
   keychain unlocking, reading raw build logs, `devicectl --console`.

Linux keeps ownership of the repo, git history, and PRs. The Mac is a build appliance — never
edit source there.

## One-time setup

### On the Mac

```bash
# Xcode from the App Store or developer.apple.com, then:
sudo xcodebuild -license accept
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

brew install node xcodegen
npm install -g xcodebuildmcp        # lands at /opt/homebrew/bin/xcodebuildmcp

# Remote Login (SSH) on, and give the build account full-disk access if you
# plan to drive UI automation:
sudo systemsetup -setremotelogin on
```

Enable Developer Mode on every physical device you intend to deploy to, and pair each one to the
Mac once through Xcode → Devices and Simulators.

Reference versions currently in use: macOS 26.5.1, Xcode 26.4.

### Network

The Mac is reached over Tailscale, so the workflow works from anywhere without port forwarding
and without the Mac being publicly exposed. Any stable route works — the only requirement is
that SSH is reliable enough for a long-lived stdio connection.

### On the Linux host

`~/.ssh/config`:

```
Host mac-builder
  HostName <mac>.<tailnet>.ts.net
  User <mac-user>
  IdentityFile ~/.ssh/id_ed25519_macbuilder
  IdentitiesOnly yes
  StrictHostKeyChecking yes
```

Push the public key with `ssh-copy-id` and confirm `ssh mac-builder true` succeeds without a
prompt. Passwordless, non-interactive auth is required — the MCP transport uses `BatchMode=yes`.

Now the wrapper that turns the remote MCP server into a local stdio command,
`~/.local/bin/xcodebuildmcp-mac`:

```sh
#!/bin/sh
set -eu

exec ssh \
  -T \
  -o BatchMode=yes \
  -o ConnectTimeout=10 \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -o LogLevel=ERROR \
  mac-builder \
  env \
  PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  XCODEBUILDMCP_ENABLED_WORKFLOWS=simulator,simulator-management,device,debugging,ui-automation,macos,xcode-ide,project-discovery,coverage,swift-package \
  /opt/homebrew/bin/xcodebuildmcp \
  mcp
```

`chmod +x` it, then register it as an MCP server:

```bash
claude mcp add xcodebuildmcp -- ~/.local/bin/xcodebuildmcp-mac
```

Three details in that wrapper are load-bearing:

- **`XCODEBUILDMCP_ENABLED_WORKFLOWS`.** XcodeBuildMCP enables *simulator tools only* by default.
  Without this variable there are no device, macOS, debugging, or UI-automation tools at all, and
  the failure looks like "that tool doesn't exist" rather than a configuration error.
- **`PATH=/opt/homebrew/bin:...`.** A non-interactive SSH session does not source the Mac's shell
  profile, so Homebrew is not on `PATH` and `xcodebuildmcp` — a Node script — fails with
  `env: node: No such file or directory`.
- **`-T` plus the keepalives.** No TTY (this is a binary protocol stream), and the keepalives stop
  a NAT or Wi-Fi idle timeout from silently killing a server that a session holds open for hours.

Verify: start a session and call `session_show_defaults`. If it answers, the channel is up.

## Agent routing rule

The Linux host's global `CLAUDE.md` carries this boundary so agents route Apple work correctly:

```markdown
## Platform execution boundary

- This Ubuntu host owns backend, web, Android, container, and browser workloads.
- Run native iOS, tvOS, macOS, Xcode, and Apple Simulator work through the
  `xcodebuildmcp` MCP server on `mac-builder`. Prefer its structured build,
  device, debugger, screenshot, and UI-automation tools over raw SSH commands.
- Preserve the exact commit plus dirty and untracked source state when handing
  Apple work to the Mac. Do not validate against a stale remote checkout.
- Use Playwright/Chromium for web UI automation on this host.
```

The third bullet is the one that keeps results honest. The Mac has its own checkout, and it is
very easy to build a stale tree and report a green build for code that was never compiled.

## Getting source onto the Mac

The Mac holds a **deploy checkout** at `~/silo-apple-deploy` that mirrors the Linux working tree
— including uncommitted and untracked changes. It is disposable; treat it as build scratch.

**Full sync** (first time, or after branch switches / large changes):

```bash
rsync -az --delete \
  --exclude 'DerivedData' --exclude 'build' \
  /path/to/silo-apple/ mac-builder:~/silo-apple-deploy/

ssh mac-builder 'cd ~/silo-apple-deploy && git log --oneline -1 && git status --short | wc -l'
```

The verification line is not optional. Confirm the commit matches local `HEAD` and the dirty-file
count matches local `git status --short | wc -l` before trusting any build result.

**Incremental sync** (the fast path while iterating on a fix):

```bash
git diff <base-commit> > /tmp/silo.patch
ssh mac-builder 'cd ~/silo-apple-deploy && git checkout -- .'
ssh mac-builder 'cd ~/silo-apple-deploy && git apply - && git status --short' < /tmp/silo.patch
```

Diff against a fixed base and always reset first, so each push is the full cumulative delta
rather than a patch that only applies to one intermediate state. This is seconds versus tens of
seconds for rsync, which adds up over a debugging session.

**Then regenerate the project.** `Silo.xcodeproj` is generated by XcodeGen and is not committed:

```bash
ssh mac-builder 'cd ~/silo-apple-deploy/iosApp && /opt/homebrew/bin/xcodegen generate'
```

Required after any sync that touched `project.yml`, added or removed files, or changed signing
xcconfigs. Cheap enough to run after every sync.

## Session defaults

Set project, scheme, and destination once per session so later calls take no arguments:

```jsonc
// session_set_defaults
{
  "projectPath": "/Users/<mac-user>/silo-apple-deploy/iosApp/Silo.xcodeproj",
  "scheme": "Silo",
  "simulatorId": "<sim-uuid>",     // from list_sims
  "configuration": "Debug"
}
```

Use `session_show_defaults` before the first build in a session, `list_sims` / `list_devices` to
find IDs. Do not hardcode simulator UUIDs — they change when runtimes are reinstalled.

Schemes: `Silo` (iOS), `SiloTV` (tvOS), `SiloMac` (macOS).

## Build and test recipes

### Simulator — the default loop

Use the MCP tools; they parse errors and return structured results.

| Intent | Tool |
|---|---|
| Build iOS | `build_sim` |
| Build and run | `build_run_sim` |
| Run unit tests | `test_sim` |
| tvOS | same tools, `{"scheme": "SiloTV", "simulatorId": "<tvos-sim>"}` |
| macOS | `build_macos` / `test_macos`, destination `platform=macOS` |
| Screenshot / UI tree | `screenshot`, `snapshot_ui` |
| Tap / type / swipe | `tap`, `type_text`, `swipe`, `button` |
| Debugger | `debug_attach_sim`, `debug_breakpoint_add`, `debug_stack`, `debug_variables` |

`build_run_sim` in one call beats `build_sim` then `launch_app_sim` — fewer round trips over SSH.

Simulator builds need no signing at all, which is why they are the default for verifying a change
compiles and its tests pass.

### Compile-only check without signing

Fastest way to confirm a platform still builds, and it sidesteps the keychain entirely:

```bash
ssh mac-builder 'cd ~/silo-apple-deploy/iosApp && \
  xcodebuild build -project Silo.xcodeproj -scheme SiloTV \
  -destination "generic/platform=tvOS" CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)"'
```

Swap `-scheme SiloMac -destination "platform=macOS"` for the Mac app.

### Physical device

Requires real signing. Use a **single SSH command** that unlocks the keychain and builds, for the
reason in the next section:

```bash
ssh mac-builder 'security unlock-keychain -p "$KEYCHAIN_PASSWORD" ~/Library/Keychains/login.keychain-db && \
  cd ~/silo-apple-deploy/iosApp && \
  xcodebuild build -project Silo.xcodeproj -scheme Silo \
    -destination "id=<DEVICE_ID>" \
    -derivedDataPath ~/silo-build-ios \
    DEVELOPMENT_TEAM=<TEAM_ID> -allowProvisioningUpdates 2>&1 | tail -30'
```

Then install and launch:

```bash
ssh mac-builder 'xcrun devicectl device install app --device <DEVICE_ID> \
  ~/silo-build-ios/Build/Products/Debug-iphoneos/Silo.app'

ssh mac-builder 'xcrun devicectl device process launch --device <DEVICE_ID> org.siloserver.silo'
```

Stable derived-data paths (`~/silo-build-ios`, `~/silo-build-tvos`) keep incremental builds warm
and make the `.app` path predictable. For tvOS the products directory is `Debug-appletvos`.

`xcrun devicectl list devices` shows what is reachable; an Apple TV reads `unavailable` while
asleep and needs a nudge from the remote.

### Capturing `print()` from a device

`OSLog` does not reach `devicectl --console`; `print()` to stdout does. To watch it:

```bash
ssh mac-builder 'nohup xcrun devicectl device process launch \
  --device <DEVICE_ID> --console org.siloserver.silo \
  >> /tmp/silo-run.log 2>&1 </dev/null & disown'
```

`nohup … </dev/null & disown` all three matter — otherwise a SIGHUP, a SIGTTIN stop on terminal
input, or the shell exiting kills the stream. Closing the `--console` stream terminates the app on
the device, so treat that process as the app's umbilical cord and do not `pkill` it mid-test.

Tail with `tail -n 0 -F` (capital `-F` survives log truncation) and pipe through
`grep --line-buffered` — without line buffering, events arrive in minute-long bursts.

## Signing and the keychain trap

This is the single biggest time sink, so it gets its own section.

**`security unlock-keychain` does not persist across SSH sessions.** Each SSH connection is its
own security session. Unlocking the keychain in one `ssh` invocation has no effect on the next
one, and no effect on the already-running MCP server — which is a *different*, long-lived session
established when the agent started.

The symptom is a build that fails deep in a `CodeSign` step, often on an embedded extension rather
than the app itself. The MCP tool output usually shows only "Command CodeSign failed"; the real
cause (`User interaction is not allowed`) is buried in the raw log.

Consequences:

- **Simulator and `CODE_SIGNING_ALLOWED=NO` builds** — unaffected. Use MCP tools freely.
- **Device builds** — either unlock inside the same `ssh` command as `xcodebuild` (the recipe
  above), or unlock the keychain out-of-band and keep it unlocked for the MCP server's session.

If codesign still fails right after a successful unlock, the partition list is likely blocking
non-interactive access:

```bash
ssh mac-builder 'security unlock-keychain -p "$KEYCHAIN_PASSWORD" ~/Library/Keychains/login.keychain-db && \
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$KEYCHAIN_PASSWORD" ~/Library/Keychains/login.keychain-db'
```

A quick isolation test that avoids a five-minute build:

```bash
ssh mac-builder 'cp /bin/echo /tmp/cs-probe; codesign --force --sign <IDENTITY_HASH> /tmp/cs-probe; rm -f /tmp/cs-probe'
ssh mac-builder 'security find-identity -v -p codesigning'
```

Watch for `CSSMERR_TP_CERT_REVOKED` in that identity list — expired or revoked certificates linger
in the keychain and get picked ahead of the good one.

> **Handling the password.** Keep it in an environment variable, a `.env` file, or the host
> keychain — never inline in a command, a script, or a commit. Anything typed into an agent
> session is written to that session's transcript on disk.

**Signing configuration itself** lives in the repo: copy `iosApp/Signing/Local.xcconfig.sample`
to `Local.xcconfig` (gitignored) to override bundle IDs, entitlements, and `DEVELOPMENT_TEAM`
for a Personal Team, then run `xcodegen generate`. That file documents which features degrade
under a Personal Team — App Groups, push, and Top Shelf handoff are unavailable; playback, auth,
and library browsing all work.

## Reading the real build errors

MCP tool output is summarized and truncated. Full `xcodebuild` logs live on the Mac at:

```
~/Library/Developer/XcodeBuildMCP/workspaces/<workspace>-<hash>/logs/<tool>_<timestamp>_pid<pid>_<id>.log
```

The tool result includes the exact log path — grep it directly:

```bash
ssh mac-builder 'grep -E "error:|CSSMERR|Command CodeSign" "<log-path>" | head -20'
```

For a signing failure, pull context around the failing step rather than the tail:

```bash
ssh mac-builder 'grep -B5 -A25 "CodeSign /Users.*<Target>" "<log-path>"'
```

`grep -E "error:"` is also the right first move on any raw `xcodebuild` output — real errors are
buried under thousands of lines of Swift toolchain noise.

## Gotchas

- **A green build on the Mac proves nothing if the tree is stale.** Verify commit *and* dirty-file
  count after every sync.
- **Simulator versus device destinations produce different product directories**
  (`Debug-appletvsimulator` versus `Debug-appletvos`). `devicectl install` silently rejects a
  simulator bundle.
- **Run `xcodegen generate` after syncing.** `Silo.xcodeproj` is generated; a stale one omits new
  files and the build fails with confusing "cannot find type" errors.
- **SourceKit "No such module" errors are IDE index artifacts.** If `xcodebuild` says
  `BUILD SUCCEEDED`, the code is fine.
- **`devicectl --console` is launch-time only.** You cannot attach to an already-running app;
  launching creates a fresh instance and kills the old one.
- **Device install can fail on a Developer Disk Image mismatch** when the device OS is newer than
  the Mac's Xcode. Updating Xcode is the fix; nothing in the build is wrong.
- **Never commit from the Mac checkout.** It is a build mirror. Commits, pushes, and PRs happen on
  Linux against the real working tree.
- **Never hardcode device UUIDs from documentation.** Discover them with `list_devices` or
  `xcrun devicectl list devices` — they are per-device and change on re-pairing.

## Quick reference

| Path / value | What |
|---|---|
| `~/silo-apple-deploy` | Deploy checkout on the Mac (build scratch, never edit) |
| `~/silo-apple-deploy/iosApp/Silo.xcodeproj` | Generated project |
| `~/silo-build-ios`, `~/silo-build-tvos` | Stable derived-data paths |
| `~/Library/Developer/XcodeBuildMCP/workspaces/*/logs/` | Full build logs |
| `/opt/homebrew/bin/xcodebuildmcp`, `/opt/homebrew/bin/xcodegen` | Tooling (absolute paths — Homebrew is not on the non-interactive `PATH`) |
| `Silo` / `SiloTV` / `SiloMac` | iOS / tvOS / macOS schemes |
| `org.siloserver.silo` | Default bundle ID (override in `Local.xcconfig`) |

## Extending this to another Mac or another project

Nothing here is Silo-specific except the paths and scheme names. To point the same setup at a
different project: add an SSH host alias, copy the wrapper (adjusting only the alias), register
the MCP server, and set session defaults to the new project path. XcodeBuildMCP keys its logs and
state per workspace, so one Mac can serve many projects and many developers concurrently.
