Last verified against the code: 2026-08-20 (template only; the Stage 2
control-plane extraction did not change what a record must carry).

# Apple Validation Record Template

Use this template for any Apple-player route validation that could become a
product claim.

Validation records should live in `docs/tvos-player/validations/` using
filenames like `<date>-<platform>-<implementation-route>-<claim>.yaml`.

## Required fields

| Field | Example |
| --- | --- |
| Date | `2026-04-22` |
| Platform | `tvOS 18.5` |
| Device | `Apple TV 4K (3rd gen) — AppleTV14,1` |
| Build | `PR #172 @ ecf1770` |
| Route family | `NativePlayer` |
| Implementation route | `avPlayerNativeDirect` |
| Delivery | `direct` / `transcode` |
| Asset container | `mp4` |
| Video codec / profile | `hevc / dvhe.05` |
| Audio codec / layout | `eac3 / 7.1` |
| Subtitle configuration | `embedded off, sidecar WebVTT on` |
| Output path | `HDMI -> LG C3 -> Denon X3800H` |
| Expected behavior | `TV enters Dolby Vision mode; subtitles stay selectable` |
| Actual behavior | `Passed` / `Failed` plus notes |
| Evidence | screenshots, AVR panel text, system banners, logs |

No device identifiers, no branch names: records are committed to a public
repository, so give the model identifier (`AppleTV14,1`) and never a device
UUID, serial number, room nickname or production hostname, and cite the build
as a PR number plus commit SHA — a branch name resolves to nothing once it
merges.

## Example record

```yaml
date: 2026-04-22
platform: tvOS 18.5
device: Apple TV 4K (3rd gen) — AppleTV14,1
app_build: SiloTV Debug from silo-apple PR #172 @ ecf1770
route_family: SiloPlayer
implementation_route: siloPlayerLoopback
delivery: direct
asset:
  container: mp4
  video: hevc
  profile: dvhe.05
  audio: eac3
  subtitle_state: sidecar_webvtt_primary
output_path: HDMI -> LG C3 -> Denon X3800H
expected: TV enters Dolby Vision mode and subtitles stay selectable
actual: pending
evidence:
  - system log route trace
  - TV mode-switch banner photo
  - AVR front-panel audio mode photo
notes:
  - Do not generalize this record to other Dolby Vision profiles
```

## Claim rules

- Do not treat a route name as a claim.
- Do not generalize one Dolby Vision or Atmos result to every container or
  subtitle configuration.
- Do not mark PiP or external playback supported until the route, app config,
  lifecycle behavior, and receiver path have all been validated together.
