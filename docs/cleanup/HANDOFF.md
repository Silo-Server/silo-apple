# Silo Apple streamlining program — session handoff

**Read this first when picking the program up in a new session.** It is the single entry point; every other
document it names is supporting evidence. Last updated 2026-08-18 after round 5 landed (`4f5a3a6`).

---

## 1. Goal and ground rules (owner's words, unchanged)

> Streamline and clean up any and all of the code/logic for our app — player, engine, UI etc. Remove any
> unnecessary code and keep this maintainable long-term. Rewrite what needs rewritten. Think DRY, YAGNI and KISS.

- **One PR.** [PR #172](https://github.com/Silo-Server/silo-apple/pull/172) (`player/architecture-remediation` →
  `main`) is *the* PR. Every further round lands on this branch and is folded into that PR. The owner explicitly
  rejected landing early and continuing on a follow-up PR ("No, I want a single PR"). Do not re-raise it.
- **Behaviour must stay identical on iOS, tvOS, macOS and the extensions** for cleanup work. Product-visible changes
  are only allowed when the owner decides them (see §7 decisions).
- **Server / Android are separate repos** (`silo-server`, `silo-android`); do not change wire contracts here. When a
  change needs the server, open a silo-server PR (precedent: silo-server #670).
- **tvOS focus:** read `docs/tvos-focus.md` before touching navigation, menus, grids or custom controls. Share
  models/formatting/loaders across platforms; keep focus ownership per platform.
- Do not touch the intentionally-kept list in `docs/cleanup/app-cleanup-backlog.md` §3 without new information.

## 2. Where the branch stands

| Item | State |
|---|---|
| Branch / PR | `player/architecture-remediation` @ `4f5a3a6`, pushed to `origin` (GitHub `Silo-Server/silo-apple`); PR #172 `MERGEABLE / CLEAN`, CodeRabbit green |
| Size vs `main` | ~115 commits, ~510 files, roughly +23k / −28k raw |
| Suite (iOS `SiloTests`, only test target) | `Executed 1522 tests, 3 skipped, 14 failures (0 unexpected)` — the 14 are the documented simulator-environment failures (§5); the 3 skips are keychain-migration tests when the sim host cannot write the keychain |
| Builds | `Silo` (iOS), `SiloTV` (tvOS), `SiloMac` all green at the tip, `CODE_SIGNING_ALLOWED=NO` |
| Hardware | HDR10 HEVC MKV loopback + display criteria validated on Apple TV 4K gen 3 (tvOS 26.6) on 08-17; DV rows pending; **one open anomaly** (§8) |
| Sibling PRs to sequence after #172 | #171 (release launch paths / deep links), #169 + #107 (subtitles) — they overlap touched files |

### What is on the branch, in layers (details: PR #172 body and `app-cleanup-backlog.md` §0 round table)

1. **One-player consolidation** (`player/one-player-cleanup`, kept as backup @ `36393b4`): FFmpeg/VideoToolbox
   `PlayerCore`/CompatibilityPlayer backend deleted; every route is `AVPlayer` → native-direct, the local loopback
   (`127.0.0.1` fMP4-HLS remux by `LoopbackSegmentWriter`), or server HLS. Cleanup rounds 1–4 (−4.3k code lines).
2. **Player architecture remediation R1 + R2**, driven by the independent review
   `docs/cleanup/player-review/2026-08-17-architecture-review.md` (+ `slices/`): 14 of 16 ranked defects fixed,
   73 characterization tests, typed `PlaybackFailure` channel (string classifiers gone), `AVPlayer` injected, V3
   fixtures re-vendored from server `5fdb5d73` + `output_change` replan op, `silo://` scheme, dormant on-device
   video-bridge tier + `.passthroughAV1` deleted (−2,185).
3. **R2b brand migration**: every persisted / OS-registered / on-disk / wire `continuum` literal → `silo` with
   one-time migrations; only `LegacyBrandKeys` (read-only migration sources) still names the old brand.
4. **Server pairing**: Apple advertises `client_audio_track_selection_v1` on `original_http` (silo-server #670,
   merged, dev-validated), routes non-default audio to loopback, marks `progressive` unsupported on device.
5. **Cleanup tail** (Fable-reviewed): dead API/cache/legacy-quality helpers; shared phone/tvOS similar-item loader
   and episode formatting; docs truth pass (−275).
6. **Round 5 — DRY/KISS/YAGNI sweep** (2026-08-18): 25-agent survey → 8 file-disjoint packages → 8 Opus
   implementers + independent Opus reviewers, all approved; 104 files, +1,148 / −2,231. Full item list in the
   backlog §0 round-5 row; reviewer-confirmed benign behaviour deltas are listed in the PR body under
   "Behaviour changes to be aware of".

## 3. How the cleanup loop runs (the machinery)

Two-stage, orchestrator-in-the-loop. Scripts live in `.claude/workflows/` (gitignored — local to this Mac) and are
**mirrored for durability in `docs/cleanup/workflows/`**; if `.claude/workflows/` is missing, copy them back from
there. `docs/cleanup/workflows/README.md` documents args and lessons in detail.

| Stage | Script | What it does | Cost last run |
|---|---|---|---|
| Survey (read-only) | `app-cleanup-survey-v2.js` | 8 slices (player-core, player-avroute, player-subtitles, player-ui, screens-shared-ui, tvos-topshelf, infra, tests). Per slice: **Sonnet** mechanical inventory (duplicate symbols, platform twins, giant functions, orphans, repeated idioms, debug forks, stale comments) → **Opus** finder (high effort, ≤15 evidenced findings with a surviving implementation + behaviour argument) → **Opus** skeptic (default drop). One **Opus** packager → ≤8 file-disjoint packages ≤~800 LOC with self-contained briefs; disjointness re-enforced in code. Guardrails baked in: no Stage 2/3, no P1–P13, no tvOS focus changes, no wire changes, no new manager/protocol layers, backlog §3 respected, "push back on a wrong premise". | 25 agents, ~63 min, ~3.9M tokens |
| Fix (mutating, worktrees only) | `app-cleanup-fix.js` | Per package: Opus implementer in an isolated worktree (`git reset --hard <baseRef>` first — harness worktrees start from `main`), applies the brief, `xcodegen generate`, builds the schemes in `build_scopes`, runs the iOS suite on an **isolated simulator**, commits to `cleanup/<id>`; independent Opus reviewer reads the diff from the main checkout; one repair round. Never pushes/merges. | 18 agents, ~52 min, ~2.1M tokens |
| Remediation fix (for review-driven rounds) | `player-remediation-fix.js` | Same shape as the fix stage but takes `spec_path` JSONs with `brief` + `findings` from `docs/cleanup/player-review`; branches `remediation/<id>`. Used for R1/R2/R2b. | — |
| v1 survey | `app-cleanup-survey.js` | Deletion-oriented predecessor (Fable finders). Superseded by v2; kept for reference. | — |

**Exact invocation used for round 5** (workflows need an explicit per-request opt-in — the owner said "create a
workflow"; do not launch one unasked):

```
Workflow({ scriptPath: ".claude/workflows/app-cleanup-survey-v2.js",
           args: { baseSha: "<full 40-char SHA of the branch tip>" } })
```
then review the packages (see below), write one spec JSON per package (`{brief, findings}`) to the session
scratchpad, and:
```
Workflow({ scriptPath: ".claude/workflows/app-cleanup-fix.js",
           args: { baseRef: "<same full SHA>", scratchDir: "<session scratchpad>/worktrees",
                   packages: [ { id, title, area, risk, est_loc_delta, files, build_scopes, tests, effort, spec_path }, … ] } })
```
Then, in the main checkout: `git merge --no-ff --no-edit cleanup/<id>` for each approved package (file-disjoint →
clean merges), delegate a final all-scheme build + full suite to a Sonnet agent, update backlog §0, commit
(`git commit -- docs/cleanup/...` — see gotcha in §5), push, `gh pr edit 172 --repo Silo-Server/silo-apple
--body-file …`, then `git worktree remove` the round's worktrees and `git branch -d cleanup/*`.

**Orchestrator review step (do not skip — it caught wrong premises three times in earlier rounds):** check package
file lists are pairwise disjoint (do it in code, not by eye), check each finding's `files` against its package's
`files` and make sure the brief fences off anything owned by a parallel package, split mechanical deletions from
refactor-shaped work if they only share a file incidentally, drop anything you don't trust. In round 5 the packager
had already fenced every collision I found; verify anyway.

**Slice notes are pre-seeded** with the review's §5 "accidental complexity" list that is *not* gated; refresh
them before the next run to remove items round 5 already fixed (bridge residue, `PlayerTrack` rebuild, probe
helper, constrained-device predicate, `PlayerOnDeckItem`, seek preamble, ETag dup, caption snapshot, etc.).

## 4. Verification recipe (what "green" means)

From `iosApp/`:

```bash
xcodegen generate
xcodebuild build -project Silo.xcodeproj -scheme Silo   -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E '^\*\* BUILD|error:'
xcodebuild build -project Silo.xcodeproj -scheme SiloTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E '^\*\* BUILD|error:'
xcodebuild build -project Silo.xcodeproj -scheme SiloMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E '^\*\* BUILD|error:'
```
Full suite on an isolated simulator (parallel runs on one device collide):
```bash
SIM=$(xcrun simctl create verify-run "iPhone 17 Pro") && xcodebuild test -project Silo.xcodeproj -scheme Silo -destination "id=$SIM" CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E 'Executed|\*\* TEST|error:|failed' | tail -30; xcrun simctl shutdown "$SIM"; xcrun simctl delete "$SIM"
```
- Green = every failure is inside `ProfileLaunchIdentityTests`, `ProfileLaunchMigrationTests`,
  `SettingValuesAPITests`, `UICustomizationPreferencesTests` (14 assertion failures / 7 methods on this host; some
  hosts see 2). Any failure outside those, or a total-count change you cannot explain by tests added/removed, is a
  regression.
- Total-count baseline drifts by host (1526 vs 1528 seen for the same tree). Always take a same-host control at the
  base SHA before reading a delta.
- `git diff --check <base>..HEAD` must be clean.
- Delegate builds/tests to a Sonnet/Haiku agent so the output stays out of the main context; DerivedData is at
  `/Volumes/NVMe/DeveloperCache/xcode-derived-data`; a cold build is minutes, the suite ~10–15 min.
- Hardware validation records go in `docs/tvos-player/validations/*.yaml` (see its README).

## 5. Environment gotchas (each cost time once)

- `iosApp/Silo.xcodeproj` is **gitignored and regenerated**; `SiloTests` sources are a directory glob — adding or
  deleting a test file needs only `xcodegen generate`, never a `project.yml` edit, never a committed xcodeproj.
- `git add docs/cleanup/...` is refused as ignored (some excludes rule matches `docs/cleanup` even though the files
  are tracked). Use `git commit -- <path>` (tracked files commit fine) or `git add -f`.
- `.claude/*` is gitignored except `skills/` — workflow scripts are local; mirrored under `docs/cleanup/workflows/`.
- `xcrun simctl clone 89473B29-…` (the iPhone 17 Pro template the fix script uses by default) fails with
  CoreSimulator error 405 while that device is **Booted** by another session. Create a fresh `iPhone 17 Pro` sim
  instead (the verification recipe above does), or pass a different `simTemplateUdid`.
- The desktop-app simulator screenshot path needs a pre-created Metal cache dir; tvOS screenshots are unsupported.
- Harness worktrees start from `main`, not the working branch — every fixer's step 0 is
  `git reset --hard <baseRef>`; the fix script rejects packages whose reported `base_sha` differs.
- Old bisect worktrees for the HDR10 investigation live under `/Volumes/NVMe/DeveloperCache/scratch/silo-apple-bisect/`
  and a `.codex` worktree exists — leave them.
- Apple TV device workflow (signing on the Studio, `devicectl` install, `pyatv` wake, deep-link
  `silo://play/<contentId>` to start playback) is recorded in the assistant memory
  `apple-tv-device-workflow` and `docs/tvos-player/README.md`.

## 6. Open work — what is left, ranked

### 6a. Small, unblocked (a follow-up cleanup package, ~−300 total)
From round 5's deferred list (backlog §0 "Round-5 deferred"):
- `displayCapabilities:` argument passed to `ApplePlaybackRoutePlanner` that the planner never consumes
  (`PlayerViewModel` ↔ planner; deferred only for file collision).
- `VideoTrack` write-only colour fields (deferred for collision with the bridge-residue package).
- Two dead `TokenStore` refresh overloads kept alive **only** by `SettingValuesAPITests` (a red-baseline file).
- `NWListener` range-origin fake written three times in tests (~−250, medium risk: the merged origin must adopt
  Retarget's cursor/end recursion as the superset).
- Backlog §1: 1.20 (`generatedHLSSpillPolicy` reason string), 1.21 (historical "Continuum" prose — harmless).
- The **14 environment test failures** (backlog §4.6): fixing or marking them is what makes "green" trustworthy;
  it also unblocks the `TokenStore` item above.

### 6b. Gated — the big levers (need an owner decision or a server change first)
| Work | What it is | Gate |
|---|---|---|
| **Round 3 = Stage 2 control-plane extraction** (review §8/§9) | `PlaybackBackend` protocol, pure `PlaybackReducer` + `PlaybackSessionActor`, `PlaybackEngineSession`, one `RecoveryPolicy` replacing six backend ladders + VM outage ride-through, `TrackSelectionCoordinator` extraction from the VM's subtitle half. This is the real answer to `PlayerViewModel` ≈ 8k raw lines / `AVPlayerBackend` ≈ 4.6k. Ships behind `player.apple.control_plane: off|native_direct|loopback|all`. | Needs the **remote key in silo-server settings** (P11; pattern: `SettingKeys.generated.swift`, `PlayerSettings.swift`, `flusher.enqueue`). Until it exists there is no non-TestFlight rollback. Also wants a control run on the HDR10 anomaly (§8) first. Run via `player-remediation-fix.js` with spec JSONs; roughly 5–7 implementers + reviewers. |
| **Stage 3 = narrow the local matrix (Option B deletions)** | EC3/AC3/AAC encoder ladders in the writer; the plan-less EVENT writer fallback (backlog §2.5, ~−300…−600); server-authoritative tightening (planner limited to execution detail, `local_mutations` populated, `ApplePlaybackRouteCapabilities` premium claims → `plan.claims`). Each behind the route key. | **P1, P2, P5** (see §7). |
| Stage 4/5 | Default the new control plane on; one release later delete the old VM core + ladders. Stage 5 (Option C, delete ~11.6k loopback lines + FFmpeg dep) only if P1 = no. | Stages 2–3 first; P1. |
| Review items still open | #10 server audio pick on native-direct/HLS (needs server audio-index semantics; largely moot now that non-default audio → loopback); #11 combined-index translation for embedded tracks (needs the version inventory plumbed from the VM); six online-unreachable error rungs (PVM `1524-1553` at review time); `cmpLog` vs `os_log` unification; macOS scene-phase divergence; audiobook engine as a second V3 client. | Mostly Stage 2 territory; small ones could go in a follow-up package. |
| Another DRY survey pass | Round 5's finders each ran a whole-repo identifier scan and found **zero orphan types**; remaining yield is repetition. Expect a diminishing tail unless Stage 2/3 reshape the code first. | Owner's call on spend; say "use a workflow". |

## 7. Decisions the owner still needs to make (asked 2026-08-17, unanswered)

Full list: review §10 (P1–P13). The ones that gate work now:

- **P1** — Are *Dolby Vision presented as DV* (P8.1 conversion, not HDR10) and *lossless multichannel audio*
  (FLAC/LPCM, not AAC) commitments? These are the only things loopback provides that the server cannot.
  Yes → keep loopback (Options B/D, current path). No → Option C becomes possible (delete ~11.6k loopback lines +
  FFmpeg + 17 test files; DV→HDR10, lossless→AAC, every MKV play becomes a server session).
- **P2** — May common H.264/HEVC MKV/TS playback move to server remux? (server capacity + outage posture)
- **P5** — Unknown-duration / untrusted-keyframe sources → server HLS instead of the local growing playlist?
  (enables deleting the EVENT fallback, backlog §2.5)
- **P11** — Agree the remote kill-switch key(s) with silo-server before Stage 2.
- Backlog 1.18 — three divergent runtime-format styles across the app: unify only if one output format is chosen.

## 8. Open validation item (does not block landing, does need closing)

On 2026-08-18 an HDR10 HEVC MKV loopback item on the bedroom Apple TV died at anchor+21 s with `-11868/-17223`
on **every** build tested (including a pre-round-2 variant), while identical bytes/plan played 2.5 h on 08-17;
disabling the display-criteria write fails immediately with the same code → the evidence points at the TV/HDMI
display path, not the writer. Recorded with the bisect in `docs/tvos-player/validations/2026-08-18-*.yaml`.
**Needs one control run** (different day / TV input / AVR path) before it is closed as environmental. Also still
pending on hardware: the Dolby Vision rows once the TV's server carries silo-server #670. Deep-link
`silo://play/<contentId>` via `devicectl … --payload-url` is how to start playback on the TV; `pyatv` key presses
do not reach the player.

## 9. Documents and where things live

| What | Where |
|---|---|
| This handoff | `docs/cleanup/HANDOFF.md` |
| Round table, intentionally-kept list, deferred/refuted, areas worth a look | `docs/cleanup/app-cleanup-backlog.md` (§0, §3, §4) |
| Architecture review (defects, target architecture, staged plan, product decisions) | `docs/cleanup/player-review/2026-08-17-architecture-review.md` + `slices/` |
| Workflow scripts (mirror) + README | `docs/cleanup/workflows/` (source of truth when present: `.claude/workflows/`) |
| Player docs | `docs/tvos-player/` (README, 01–09, `validations/`) |
| tvOS focus rules | `docs/tvos-focus.md` |
| PR | https://github.com/Silo-Server/silo-apple/pull/172 (body carries the layer summary, behaviour changes, validation) |
| Server counterpart | silo-server PR #670 (`client_audio_track_selection_v1`), merged; deployed to shared dev |
| Assistant memory (cross-session) | `player-architecture-remediation`, `app-cleanup-workflows`, `one-player-consolidation`, `apple-tv-device-workflow`, `ios-sim-metal-cache-dir` |

## 10. Suggested first 15 minutes of the next session

1. `git fetch origin && git status && git log --oneline -5` on `player/architecture-remediation`; confirm PR #172
   is still `MERGEABLE` and whether `main` moved (`git log --oneline HEAD..origin/main`); merge `origin/main` in
   if it did and re-run the verification recipe.
2. Ask the owner which of the three next options they want: (a) unblock **Round 3** by adding the
   `player.apple.control_plane` key in silo-server, (b) answer **P1/P2/P5** to open Stage 3, (c) spend another
   survey→fix cycle on the small tail (§6a) — or the 14 env test failures first.
3. If a workflow round: refresh the slice notes in `app-cleanup-survey-v2.js`, take the full tip SHA, run survey,
   review packages, run fix, merge, verify, update backlog §0 + PR body + this file's §2.
