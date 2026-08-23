---
name: physical-tvos-testing
description: Control and behaviorally test a physical Apple TV from the Silo Apple development environment using Appium/XCUITest, RemoteXPC, CoreDevice, and pyatv. Use for physical tvOS UI inspection, screenshots, focus navigation, remote-button input, app lifecycle, wake or power control, pairing, and automation-service repair. Use mac-builder instead for ordinary Apple builds, signing, installation, or simulator work.
---

# Physical tvOS testing

Use the paired Mac as the control host. Inspect the established installation before installing,
pairing, replacing configuration, or starting duplicate services.

## Control layers

- **Appium/XCUITest over RemoteXPC** is the ADB-like testing layer: accessibility hierarchy,
  focused-element state, screenshots, element actions, remote-button input, and app lifecycle.
- **pyatv Companion** complements Appium with wake, power, media, and basic remote commands. It
  does not provide an accessibility tree or screenshots.
- **CoreDevice (`devicectl`)** discovers devices and handles app installation, launch, termination,
  app inventory, and process inspection.
- For a new WDA build, provisioning, signing, or Silo deployment, read and use the `mac-builder`
  skill. Runtime automation alone does not require resyncing or rebuilding Silo.

## Privacy boundary

Device names, network addresses, MAC addresses, CoreDevice identifiers, RemoteXPC UDIDs, pairing
records, pyatv credentials, Apple account names, signing certificate hashes, and team IDs are
private machine state.

- Never add them to this repository, patches, examples, LaunchAgent templates, screenshots, or
  final responses.
- Discover them at runtime and keep them in task-specific shell variables. Do not hardcode them in
  commands intended for reuse.
- Never print pairing records or credential values. In particular, `atvremote scan` can print
  stored credentials for an already-paired device; do not use its raw output as proof or include it
  in a transcript.
- Keep Appium pair records, pyatv storage, generated WDA products, launchd plists containing device
  identifiers, logs, UI sources, and screenshots outside the repository.
- Treat screenshots, accessibility trees, and media labels as private user data. Do not commit or
  upload them without explicit authorization.

Before staging, committing, or handing off any physical-tvOS automation change:

1. Review every changed and untracked file, not only `git diff` output.
2. Scan the changed files for device names, non-loopback IP addresses, MAC addresses, UUIDs,
   account names, certificate or team identifiers, credential fields, long hex/base64 strings,
   pair records, screenshots, UI sources, and logs.
3. Replace reusable values with descriptive placeholders and keep machine-local configuration
   outside the repository.
4. Stop if any value cannot be confidently classified as public or synthetic.

## Pairing is protocol-specific

Appium/RemoteXPC pairing and pyatv Companion pairing are independent. Each may display its own PIN.
Do not initiate a new pairing merely because the other control layer was paired.

Before asking the user for a PIN:

1. Check whether the relevant tool already has credentials.
2. Prove them with a harmless live command.
3. Pair only if that proof fails for an authentication reason.

pyatv's default credential store is `~/.pyatv.conf`. Reuse it unless the user intentionally chose
another store. Pointing pyatv at a new empty file makes a paired device appear unpaired.

## Workflow

1. Confirm the target is awake and resolve its identifiers from current discovery output. Do not
   reuse identifiers from notes or previous runs.
2. Check the Appium server and RemoteXPC tunnel before starting replacements.
3. Start one Appium session for the target app and retain its returned session ID.
4. Capture the initial focused element and screenshot.
5. Perform the smallest action that proves the requested behavior.
6. Capture the resulting focused element, UI state, screenshot, or app state.
7. Delete the Appium session when the test is complete. Leave shared persistent services running.

Completion requires observable physical-device evidence. Installation, pairing, a healthy server,
or a successful API response alone does not prove UI control. At minimum, show that a real action
changed focus, app state, or the screenshot on the physical Apple TV.

For installation, pairing, WDA preparation, launchd services, and failure recovery, read
[references/setup.md](references/setup.md). For session APIs and behavioral proof, read
[references/control.md](references/control.md).
