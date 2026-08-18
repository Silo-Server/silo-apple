# Silo Apple streamlining program — session handoff

**Read this first when picking the program up in a new session.** It is the single entry point; every other
document it names is supporting evidence. Last updated 2026-08-18 (evening): owner answered P1/P2/P5 and P11
(§7 — loopback stays; Stage 3/Option B and Stage 5/Option C are off the table; Stage 2 ships as a **hard
cutover**, no remote kill-switch, silo-server PR #673 closed unmerged); the suite is genuinely green
(1520 / 0 failures — the 14-failure era is over, §2); the round-5 deferred tail landed (`e893967`).

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
| Branch / PR | `player/architecture-remediation` @ `e893967` (+ docs commits after it), pushed to `origin` (GitHub `Silo-Server/silo-apple`); PR #172 `MERGEABLE / CLEAN`, CodeRabbit green |
| Size vs `main` | ~120 commits, ~510 files, roughly +23k / −29k raw |
| Suite (iOS `SiloTests`, only test target) | `Executed 1520 tests, with 3 tests skipped and 0 failures (0 unexpected)` — **genuinely green since 2026-08-18** (the 14 environment failures are fixed, §4.6 of the backlog); the 3 skips are keychain-migration tests when the sim host cannot write the keychain; any failure at all is now a regression |
| Builds | `Silo` (iOS), `SiloTV` (tvOS), `SiloMac` all green at the tip, `CODE_SIGNING_ALLOWED=NO` |
| Hardware | HDR10 loopback + display criteria validated (bedroom gen-3 08-17, Living Room gen-2 08-18); DV rows validated 08-18 on Living Room (P8.1 passthrough, P7→8.1 + TrueHD→FLAC); §8 anomaly **closed as environmental** |
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
7. **Env baseline + round-5 tail** (2026-08-18, two hand-briefed packages, orchestrator-reviewed): the 14
   "environment" test failures fixed for real — `KeychainBackend` seam on `SharedKeychain` (nil in the app) +
   in-memory test fake for the unsigned-host `errSecMissingEntitlement` class, stale pre-#132 tab-projection
   expectations updated, two orphaned tests deleted with the two dead `TokenStore` overloads — suite now
   **1520 / 0 failures / 3 skipped**; plus the round-5 deferred tail (`displayCapabilities:` plumbing,
   `VideoTrack.colorSpace/.colorPrimaries`, `RangeOriginStub` fake merge, spill-reason rename; net −385).
   Premise corrections recorded in backlog §0.

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
- Green = **0 failures**: `Executed 1520 tests, with 3 tests skipped and 0 failures (0 unexpected)` on this
  host. The old 14-failure environment baseline was fixed on 2026-08-18 — any failure at all, or a total-count
  change you cannot explain by tests added/removed, is a regression.
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

### 6a. Small, unblocked
The whole round-5 deferred list **and** the 14 environment failures landed on 2026-08-18 (backlog §0 row,
§4.6). Still open, all small:
- Re-cover the temporary-scope refresh guard with a direct unit test against the live
  `TokenStore.saveRefreshedTokens(_:_:replacing:)` funnel — the only direct assertion was deleted with the
  dead overload; end-to-end coverage remains (`testOrdinaryUnauthorizedResponseCannotCrossFromPersistentIntoTemporaryCredentials`).
- Backlog 1.21 (historical "Continuum" prose) — intentionally left; rewriting would make it factually wrong.
- `VideoTrack.bitDepth` is write-only but deliberately kept (HDR10-adjacent; see backlog §0 premise notes).

### 6b. Gated — the big levers (need an owner decision or a server change first)
| Work | What it is | Gate |
|---|---|---|
| **Round 3 = Stage 2 control-plane extraction** (review §8/§9) | `PlaybackBackend` protocol, pure `PlaybackReducer` + `PlaybackSessionActor`, `PlaybackEngineSession`, one `RecoveryPolicy` replacing six backend ladders + VM outage ride-through, `TrackSelectionCoordinator` extraction from the VM's subtitle half. This is the real answer to `PlayerViewModel` ≈ 8k raw lines / `AVPlayerBackend` ≈ 4.6k. Ships as a **hard cutover** — owner decision 2026-08-18 (P11 = no runtime flag): the legacy VM core + ladders are deleted in the same effort once the new plane is verified; the 73+ characterization tests are the safety net, and rollback of a bad build is a new TestFlight/App Store build. | **UNGATED as of 2026-08-18**: P11 decided (no key — hard cutover; PR #673 closed unmerged, recoverable) and the §8 control run passed (anomaly environmental). Ready to run whenever the owner wants the cycle. Run via `player-remediation-fix.js` with spec JSONs; roughly 5–7 implementers + reviewers. |
| ~~Stage 3 = narrow the local matrix (Option B deletions)~~ **Cancelled 2026-08-18** | P1 = yes, P2 = no, P5 = no (§7): the encoder ladders, the EVENT fallback and common-container local playback all stay. Only the server-authoritative tightening items (planner limited to execution detail, `local_mutations` populated, `ApplePlaybackRouteCapabilities` premium claims → `plan.claims`) remain candidates — as Stage 2 territory. | Decided — closed. |
| ~~Stage 4~~ Folded into Stage 2 | With no runtime flag (P11 = no key) there is no separate "default it on" release: Stage 2 lands with the old VM core + ladders already deleted. (The former Stage 5 / Option C is dead: P1 = yes.) | — |
| Review items still open | #10 server audio pick on native-direct/HLS (needs server audio-index semantics; largely moot now that non-default audio → loopback); #11 combined-index translation for embedded tracks (needs the version inventory plumbed from the VM); six online-unreachable error rungs (PVM `1524-1553` at review time); `cmpLog` vs `os_log` unification; macOS scene-phase divergence; audiobook engine as a second V3 client. | Mostly Stage 2 territory; small ones could go in a follow-up package. |
| Another DRY survey pass | Round 5's finders each ran a whole-repo identifier scan and found **zero orphan types**; remaining yield is repetition. Expect a diminishing tail unless Stage 2/3 reshape the code first. | Owner's call on spend; say "use a workflow". |

## 7. Product decisions (P1–P13)

Full list: review §10. The gating ones were answered by the owner on **2026-08-18**:

- **P1 = yes** — *Dolby Vision presented as DV* and *lossless multichannel audio* (FLAC/LPCM) **are**
  product commitments. The loopback tier stays; Option C (delete ~11.6k loopback lines + FFmpeg + 17 test
  files) is permanently off the table.
- **P2 = no** — common H.264/HEVC MKV/TS playback stays on the local path; no move to server remux.
- **P5 = no** — unknown-duration / untrusted-keyframe sources keep the local growing-playlist EVENT
  fallback; backlog §2.5 is closed as intentionally kept (backlog §3).
- **P11 = no remote key** — the owner decided Stage 2 ships as a **hard cutover**: no
  `player.apple.control_plane` setting, no staged per-device rollout; rollback of a bad build is a new
  TestFlight/App Store build. The owner was shown (and declined) the insurance argument — the key was
  rollback/rollout risk control, not compatibility. silo-server PR #673, which implemented the key
  end-to-end (contract rev 8), was closed unmerged the same day and can be reopened if this ever changes.

**Consequences:** Stage 3 (Option B local-matrix narrowing) and Stage 5 (Option C) are cancelled, and
Stage 4 folds into Stage 2 (hard cutover). The remaining big lever is Stage 2 / Round 3 alone.

Still open: the rest of P1–P13 (review §10), and backlog 1.18 — three divergent runtime-format styles
across the app: unify only if one output format is chosen.

## 8. HDR10 loopback anomaly — **CLOSED 2026-08-18 (environmental)**

The 08-18 bedroom-TV failure (HDR10 HEVC MKV loopback dying at anchor+21 s with `-11868/-17223` on every build)
was closed by a control run the same evening on the **Living Room Apple TV** (4K 2nd gen, HDR10-capable HDMI
path): same title `movie-tmdb-852590`, byte-identical 1203-segment plan, same PQ @ 24.000 criteria applied —
cleared the +21 s window on both the initial anchor and a post-seek anchor (1056.6 → sampled +66 s), ~22 min
clean, zero failure markers. With build, bytes/plan, date and criteria-outcome all controlled, the remaining
variable is the bedroom TV/AVR/HDMI path. Record:
`docs/tvos-player/validations/2026-08-18-tvos-siloPlayerLoopback-hdr10-control-run-living-room.yaml`.
**Bonus in the same capture:** the pending DV rows validated on hardware — DV P8.1 passthrough (×2 titles) and
DV P7→8.1 conversion + TrueHD→FLAC 7.1 (both P1 commitments), all loopback on production.
Residual (non-blocking): check the bedroom input/cable/AVR settings at leisure and re-run the deep link there.
Workflow reminders: deep-link `silo://play/<contentId>` via `devicectl … --payload-url`; `pyatv` key presses do
not reach the player.

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
| Server control-plane key (P11) | silo-server PR #673 — **closed unmerged 2026-08-18** (owner: hard cutover, no remote key; branch recoverable from the PR) |
| Assistant memory (cross-session) | `player-architecture-remediation`, `app-cleanup-workflows`, `one-player-consolidation`, `apple-tv-device-workflow`, `ios-sim-metal-cache-dir` |

## 10. Suggested first 15 minutes of the next session

1. `git fetch origin && git status && git log --oneline -5` on `player/architecture-remediation`; confirm PR #172
   is still `MERGEABLE` and whether `main` moved (`git log --oneline HEAD..origin/main`); merge `origin/main` in
   if it did and re-run the verification recipe (§4 — green now means **0 failures**).
2. Round 3 (Stage 2) is **ungated** (§6b): P11 decided, §8 closed. It ships as a **hard cutover** (§7): write
   the specs so the legacy VM core + ladders are deleted in the same effort, with the characterization suite as
   the safety net. Run via `player-remediation-fix.js` with spec JSONs (roughly 5–7 implementers + reviewers;
   workflows still need an explicit per-request opt-in).
3. Small items: the temporary-scope guard unit test (§6a — may already be done by the spun-off task).
