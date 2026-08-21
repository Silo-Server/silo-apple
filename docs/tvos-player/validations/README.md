# Apple Player Validation Records

Store route validation records here when a result can become a product-facing
claim.

Use filenames like:

```text
<date>-<platform>-<implementation-route>-<claim>.yaml
```

Examples:

- `2026-04-27-tvos-siloPlayerLoopback-dolby-vision.yaml`
- `2026-04-27-tvos-avPlayerNativeDirect-atmos.yaml`

Follow the template in
[`../06-validation-record-template.md`](../06-validation-record-template.md),
including its no-device-identifiers rule: this directory is published, so a
record carries the model identifier (`AppleTV14,1`) and a PR number plus commit
SHA — never a device UUID, room nickname, production hostname or branch name.
The same rule governs the filename: when a record needs to name the unit it ran
on, use the model identifier (`appletv14-1`), not a room nickname.
