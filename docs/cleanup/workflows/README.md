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

Baseline note: on `player/one-player-cleanup` @ 20f5aff the iOS suite reports
`Executed 1367 tests, with 14 failures` — profile/identity/keychain environment failures that
predate the cleanup. The fix prompt tells agents this so they don't chase them.
