# Physical Apple TV automation setup

Read this reference only when installing, pairing, upgrading, or repairing the automation stack.

## Prerequisites

- The Apple TV and Mac must be reachable on the same usable network path.
- Developer Mode and **Enable UI Automation** must be enabled on the Apple TV. Settings labels can
  move between tvOS releases, so inspect the current device rather than assuming an old path.
- Use current Appium and XCUITest-driver documentation for version compatibility. Wireless tvOS
  18+ should use Appium's RemoteXPC flow.
- Keep the tool installation under a machine-local directory outside the repository, for example
  `~/Library/Application Support/SiloTVAutomation`.

Official references:

- <https://appium.github.io/appium-xcuitest-driver/latest/guides/tvos/>
- <https://appium.github.io/appium-xcuitest-driver/latest/guides/run-preinstalled-wda/>
- <https://github.com/appium/appium-ios-remotexpc/blob/main/docs/apple-tv-pairing-guide.md>

## Inspect before changing anything

On the Mac, check these independently:

```bash
xcrun devicectl list devices
curl -fsS http://127.0.0.1:4723/status
curl -fsS http://127.0.0.1:42314/remotexpc/tunnels
launchctl print "gui/$(id -u)" | grep -i appium
sudo launchctl print system | grep -i tunnel
```

Do not paste raw tunnel-registry output into a final response; it contains private device
identifiers and network details.

For pyatv, first check whether `~/.pyatv.conf` exists. Do not print it. Resolve the target address
from live discovery, then prove existing credentials with a read-only command such as:

```bash
automation_base="$HOME/Library/Application Support/SiloTVAutomation"
tv_address="<runtime-discovered-address>"
"$automation_base/pyatv-venv/bin/atvremote" -s "$tv_address" device_info
```

If this succeeds, pyatv is paired. Do not run pairing again. Avoid raw `atvremote scan` output on a
paired setup because it can emit credential strings.

## RemoteXPC pairing and tunnel

Pair Appium only when no existing Appium session can reach the device and the failure is actually
an authentication or missing-pair-record error:

```bash
sudo appium driver run xcuitest pair-appletv
```

The returned RemoteXPC identifier may differ from CoreDevice's identifier. Keep both as private
runtime state and use the RemoteXPC identifier in Appium capabilities and tunnel creation:

```bash
remote_xpc_udid="<identifier-returned-by-pairing>"
sudo appium driver run xcuitest tunnel-creation -- \
  --appletv-device-id "$remote_xpc_udid" \
  --appletv-discovery-timeout-ms 60000 \
  --disconnect-retry-max-attempts 3
```

The tunnel and Appium server are separate long-running processes. If made persistent, use a
root-owned LaunchDaemon for the privileged tunnel and a user LaunchAgent for Appium. Device-specific
plists belong on the Mac only, never in this repository. Bind Appium to loopback unless remote
network access is explicitly required and secured.

## WebDriverAgent on a real Apple TV

Use `mac-builder` for WDA build and signing work. Noninteractive SSH can compile successfully but
fail signing with `errSecInternalComponent`; use the logged-in GUI session without requesting or
recording the user's keychain password.

For preinstalled WDA on real iOS/tvOS 17+:

1. Build the tvOS WDA runner for testing with a valid development team and unique bundle ID.
2. Preserve the original signed build and prepare a separate runtime copy.
3. Remove the runtime copy's embedded `Frameworks/XC*.framework` directories so it uses the
   device-local XCTest frameworks. Appium documents this as required for the preinstalled flow.
4. Because removal changes the outer bundle seal, re-sign the prepared copy in the logged-in GUI
   session with the same valid identity and preserved entitlements.
5. Run `codesign --verify --deep --strict` on the prepared copy.
6. Use that prepared app as `appium:prebuiltWDAPath` with `appium:usePreinstalledWDA: true`.

Keep the derived data, prepared WDA, signing logs, and any temporary signing LaunchAgent outside
the repository. Unload temporary signing LaunchAgents and move their files to Trash after use.

## Common failure map

- **Appium launches WDA but port 8100 stays refused:** verify the runner remains alive. On tvOS
  17+, check for embedded `XC*` frameworks before blaming the tunnel.
- **WDA build fails with `errSecInternalComponent`:** the SSH security session cannot use the
  login keychain. Use the GUI-session signing path from `mac-builder`; do not request a password.
- **Tunnel registry address already in use:** find and validate the exact existing tunnel process
  before terminating anything, then let the one persistent service restart.
- **Apple TV is unavailable:** it may be asleep. Use an already-paired pyatv Companion connection
  to wake it, or ask the user to wake it. RemoteXPC cannot control an unreachable device.
- **pyatv appears unpaired despite prior use:** check whether the command was pointed at a new
  storage file instead of the default `~/.pyatv.conf`.
- **Pairing prompt appears unexpectedly:** cancel it and test the existing credential store before
  asking the user for another PIN.

