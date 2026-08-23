# Physical Apple TV control and proof

Read this reference when exercising or validating an already-configured physical Apple TV.

## Choose the narrowest control layer

- Use Appium for UI hierarchy, focus, screenshots, element selection, button sequences, and app
  state.
- Use pyatv for wake, power, playback transport, and simple remote commands when UI evidence is
  not required.
- Use `devicectl` for installation, launch, termination, app inventory, and process evidence.

Do not claim that pyatv provides ADB-like UI automation. Appium/XCUITest provides that layer.

## Start an Appium session

Resolve all values at runtime. Keep the capability payload outside the repository if saved at all:

```json
{
  "capabilities": {
    "alwaysMatch": {
      "platformName": "tvOS",
      "appium:automationName": "XCUITest",
      "appium:udid": "<runtime-remote-xpc-udid>",
      "appium:platformVersion": "<runtime-tvos-version>",
      "appium:bundleId": "<target-app-bundle-id>",
      "appium:noReset": true,
      "appium:usePreinstalledWDA": true,
      "appium:prebuiltWDAPath": "<machine-local-prepared-wda-app>",
      "appium:newCommandTimeout": 600
    }
  }
}
```

POST this payload to `http://127.0.0.1:4723/session` and retain the returned session ID. Never
assume that a session was created merely because the Appium server reports ready.

## Inspect and interact

Given a runtime `session_id`:

```bash
curl -fsS "http://127.0.0.1:4723/session/$session_id/source"
curl -fsS "http://127.0.0.1:4723/session/$session_id/screenshot"
curl -fsS -H 'Content-Type: application/json' \
  -X POST "http://127.0.0.1:4723/session/$session_id/execute/sync" \
  --data-binary '{"script":"mobile: pressButton","args":[{"name":"Down"}]}'
```

Supported remote buttons vary by driver version; use the current Appium execute-method reference.
Common names include `Up`, `Down`, `Left`, `Right`, `Select`, `Menu`, `Home`, and `PlayPause`.

Prefer accessibility IDs or element actions when validating a specific control. Appium can
calculate the directional sequence needed to focus and select an element. Allow for tvOS focus
animations before capturing the resulting state.

## Evidence standard

For a button or focus test:

1. Record the element whose source attribute is `focused="true"`.
2. Capture a screenshot or its dimensions and digest.
3. Send one deliberate action.
4. Wait for animation to settle.
5. Capture the focused element and screenshot again.
6. Verify the focus, app state, or image digest changed as expected.

For app lifecycle, pair API success with `devicectl` app/process evidence or Appium's queried app
state. A green build, installed app, healthy tunnel, or non-error button response is not behavioral
proof by itself.

When finished:

```bash
curl -fsS -X DELETE "http://127.0.0.1:4723/session/$session_id"
```

Delete the test session, not the shared Appium server or tunnel. Preserve an existing user session
when reinstalling the app is unnecessary.

## pyatv use

Use the established default credential store unless the user intentionally selected another one:

```bash
automation_base="$HOME/Library/Application Support/SiloTVAutomation"
tv_address="<runtime-discovered-address>"
atvremote="$automation_base/pyatv-venv/bin/atvremote"

"$atvremote" -s "$tv_address" device_info
"$atvremote" -s "$tv_address" power_state
"$atvremote" -s "$tv_address" turn_on
```

Power-off, Home, Menu, Select, and directional commands visibly affect shared hardware. Execute
them only when they are required by the user's test. Do not pair again if `device_info` succeeds.

## Evidence handling

- Keep raw screenshots and sources in a private temporary or machine-local automation directory.
- Report labels or titles only when needed to explain the test outcome.
- Do not expose device identifiers, addresses, account data, credentials, or private media lists.
- If evidence must be retained or uploaded, obtain explicit authorization and redact it first.

