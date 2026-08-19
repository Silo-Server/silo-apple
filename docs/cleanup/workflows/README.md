# App cleanup workflows

Two-stage loop for sweeping the Apple clients for low-quality / YAGNI code and cleaning it up
with parallel agents. The orchestrator (Claude) stays in the loop between the stages.

## 1. `app-cleanup-survey.js` — read-only

- 6 finder agents (Fable, medium effort), one per app slice (`DEFAULT_AREAS`), each returns ≤12
  ranked findings with file:line anchors, grep evidence, a concrete edit plan, LOC estimate, risk.
- 6 verifier agents (one per finder batch) try to *refute* each finding: whole-repo grep incl.
  Tests/TopShelf/extensions/project.yml/plists, string-keyed uses, `#if os()` blocks, docs/git-log
  intent. Verdict keep / adjust / drop.
- 1 packager groups survivors into ≤`maxPackages` work packages with **pairwise-disjoint file
  lists** (enforced again in code) and writes a self-contained implementer brief per package.

Run: `Workflow({scriptPath: ".claude/workflows/app-cleanup-survey.js", args: {maxPackages: 6, maxFindingsPerArea: 12}})`

Optional args: `areas` (override the slice list), `finderModel`, `finderEffort`.

Output: `{stats, packages[], deferred[], refuted[], areaSummaries[]}`. **Review the packages
before running stage 2** — split anything that bundles mechanical deletions with a riskier
refactor (they must stay file-disjoint), and drop anything you don't want touched.

## 2. `app-cleanup-fix.js` — mutates, in worktrees only

Per package, pipelined:
1. **Implement** — Opus agent in an isolated git worktree: reads the package spec, applies the
   brief in order, `xcodegen generate`, builds the schemes in `build_scopes`
   (`CODE_SIGNING_ALLOWED=NO`), runs the iOS test suite on a **cloned simulator** (parallel test
   runs on one device collide), commits to `cleanup/<id>`. Never pushes/merges.
2. **Review** — independent Opus agent reads `git diff base..head` from the main checkout,
   re-greps every deleted symbol, traces behavior on all three platforms, checks scope creep and
   whether the reported builds are credible. Verdict approve / request-changes / reject.
3. **Repair** — one round if changes were requested, then re-review.

Args: `{packages: [...], baseRef, fixerModel?, reviewerModel?, runTests?, simTemplateUdid?, branchPrefix?}`.
`baseRef` must be the **full 40-char SHA** of the commit the cleanup lands on. The harness
creates isolated worktrees from the repo's *default* branch (`main`), not the current branch, so
the fixer's mandatory step 0 is `git reset --hard <baseRef>`; the script refuses to review any
package whose reported `base_sha` differs.
Each package needs `id, title, area, risk, est_loc_delta, files, build_scopes, tests` (optional `effort`
for implementer+reviewer, e.g. `"high"` for wide/risky packages) plus
either `spec_path` (a JSON file with `brief` + `findings` — preferred, keeps args small) or the
inline `brief` + `findings`. Write the spec files from the survey result, e.g. to the session
scratchpad, one per package.

Output: `{approved: [ids], summary: [...]}` with branch / base_sha / head_sha / loc_delta /
build+test results / verdict per package. The orchestrator then merges the approved
`cleanup/<id>` branches into the working branch (file-disjoint packages merge cleanly), runs a
final all-scheme build + full test suite, and cleans up worktrees.

Baseline note: since 2026-08-18 the suite is genuinely green (`0 failures`, 3 keychain-migration skips);
the historical "14 environment failures" allowance is retired — the fix prompt's REPO_CONTEXT carries the
current count (1538 at round 6) and treats any failure as the implementer's to fix.

## 3. `app-cleanup-review-continue.js` — finish an interrupted fix run

Added in round 6 after a provider session limit killed `app-cleanup-fix.js` mid-run (7/8 fixers had
committed, 2/8 reviews had finished). Workflow *resume* is same-session only, so this is the fix script's
Review → Repair → re-review tail as a standalone script. Args:
`{baseRef, scratchDir, packages: [{id, title, area, risk, files, build_scopes, effort, spec_path}], fixes: {<id>: <fix report>}}`
where each fix report is the implementer's `FIX_RESULT_SCHEMA` object — recover them from the interrupted run's
`journal.jsonl` (`type: "result"` lines whose result has a `branch`) or from `wf_*.json`'s `result.summary`.
For a fixer that finished but died before committing, read its transcript, commit its worktree yourself and
hand-write the report (say so in `notes` so the reviewer reads the diff with extra care). Output shape matches
the fix script's `{approved, summary}` (plus `first_review_verdict` / `repair_status`), so the merge recipe is
unchanged. Round 6 embedded the args inline (`const EMBEDDED_ARGS = {...}`) because the packages were too large
for a tool argument — the mirrored copy reads `args` instead.

## 4. `player-stage2-fix.js` — Stage 2 control-plane extraction, one wave per run

Same implementer → independent reviewer → one repair round shape, with prompts for a design-driven structural
extraction instead of point fixes: every package has `spec_path` → JSON `{design_ref, brief, deliverables,
invariants, tests_required, deletions, behavior_changes_allowed}`; the implementer realises the named deliverables
(names are binding), writes the named tests first where told, keeps every intermediate step compiling; the reviewer
traces each invariant, runs each deletion grep, checks tests exist by name. Args `{wave, baseRef (full SHA), packages,
scratchDir?, designDoc?}`; the script refuses a wave whose packages are not file-disjoint. Branches `stage2/<id>`.
Design + specs: `docs/cleanup/player-review/2026-08-19-stage2-design.md`, `docs/cleanup/player-review/stage2/`.
Waves are sequential: merge → verify → re-anchor the next wave's spec against the new tip → run.
