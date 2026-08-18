export const meta = {
  name: 'player-remediation-fix',
  description: 'Implement reviewed player-remediation work packages: one Opus implementer per package in its own worktree, independent Opus review, one repair round',
  whenToUse: 'Pass {packages, baseRef} where each package has spec_path (JSON with brief + findings from docs/cleanup/player-review). Branches remediation/<id> are left for the orchestrator to merge.',
  phases: [
    { title: 'Implement', detail: 'one Opus implementer per package, isolated worktree', model: 'opus' },
    { title: 'Review', detail: 'independent Opus diff review per package', model: 'opus' },
    { title: 'Repair', detail: 'one round of fixes if the reviewer objects', model: 'opus' },
  ],
}

if (!args || !Array.isArray(args.packages) || args.packages.length === 0) throw new Error('args.packages is required')
const PACKAGES = args.packages
const BASE_REF = args.baseRef
const FIXER_MODEL = args.fixerModel || 'opus'
const REVIEWER_MODEL = args.reviewerModel || 'opus'
const RUN_TESTS = args.runTests !== false
const BRANCH_PREFIX = args.branchPrefix || 'remediation'
if (!/^[0-9a-f]{40}$/.test(BASE_REF || '')) throw new Error('args.baseRef must be a full 40-char commit SHA, got: ' + BASE_REF)
const SCRATCH = args.scratchDir || '/private/tmp/claude-501/-Volumes-NVMe-dev-github-SiloServer-silo-apple/bf292a54-0271-4d59-ba16-1cb07d1fcff7/scratchpad/worktrees'
const REVIEW_DOC = 'docs/cleanup/player-review/2026-08-17-architecture-review.md'

const FIX_RESULT_SCHEMA = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['done', 'partial', 'failed'] },
    worktree_path: { type: 'string' },
    branch: { type: 'string' },
    base_sha: { type: 'string' },
    head_sha: { type: 'string' },
    applied: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, note: { type: 'string' } }, required: ['id', 'note'] } },
    skipped: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, reason: { type: 'string' } }, required: ['id', 'reason'] } },
    files_changed: { type: 'array', items: { type: 'string' } },
    files_outside_package: { type: 'array', items: { type: 'string' } },
    tests_added: { type: 'array', items: { type: 'string' }, description: 'test method names added, with file' },
    loc_delta: { type: 'integer' },
    builds: { type: 'array', items: { type: 'object', properties: { scheme: { type: 'string' }, result: { type: 'string', enum: ['succeeded', 'failed', 'skipped'] }, detail: { type: 'string' } }, required: ['scheme', 'result'] } },
    tests: { type: 'object', properties: { ran: { type: 'boolean' }, result: { type: 'string' }, detail: { type: 'string' } }, required: ['ran', 'result'] },
    behavior_changes: { type: 'string', description: 'every user-visible or runtime behavior change this branch introduces, per platform; "none" if none' },
    notes: { type: 'string' },
  },
  required: ['status', 'worktree_path', 'branch', 'base_sha', 'head_sha', 'applied', 'skipped', 'files_changed', 'files_outside_package', 'tests_added', 'loc_delta', 'builds', 'tests', 'behavior_changes', 'notes'],
}
const REVIEW_SCHEMA = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['approve', 'request-changes', 'reject'] },
    summary: { type: 'string' },
    issues: { type: 'array', items: { type: 'object', properties: { severity: { type: 'string', enum: ['blocker', 'major', 'minor'] }, file: { type: 'string' }, line: { type: 'integer' }, problem: { type: 'string' }, fix: { type: 'string' } }, required: ['severity', 'file', 'problem', 'fix'] } },
    findings_verified: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, fixed: { type: 'boolean' }, evidence: { type: 'string' } }, required: ['id', 'fixed', 'evidence'] } },
    behavior_risk: { type: 'string' },
  },
  required: ['verdict', 'summary', 'issues', 'findings_verified', 'behavior_risk'],
}

const REPO_CONTEXT = `
Repository: silo-apple (Swift/SwiftUI clients for iOS, tvOS, macOS).
- App sources iosApp/iosApp/, tests iosApp/Tests/ (XCTest, target SiloTests, @testable import Silo), Top Shelf iosApp/TopShelf/.
- Target membership is in iosApp/project.yml (XcodeGen). Silo (iOS), SiloTV (tvOS), SiloMac (macOS) compile most of iosApp/iosApp/. Never hand-edit Silo.xcodeproj; edit project.yml and regenerate.
- Context: an independent architecture review of the player (${REVIEW_DOC}, with per-slice evidence under docs/cleanup/player-review/slices/) ranked 16 defects. This work package fixes a subset. Read the relevant §3 rows and the cited slice file(s) before editing — they carry the exact evidence and the smallest safe correction. Line numbers there were taken at 36393b4; the base commit for this package is one docs-only commit later, so they should still match — re-grep anyway.
- Xcode DerivedData lives at /Volumes/NVMe/DeveloperCache/xcode-derived-data; a cold build takes several minutes — wait for it. The iOS test suite (~1355 tests) takes ~10 minutes including simulator boot.
- BASELINE TEST FAILURES on the base branch (environment issues, NOT regressions): ProfileLaunchIdentityTests (2), ProfileLaunchMigrationTests.testLegacyRegistryProfileMigratesBeforeProfileFieldIsRemoved, SettingValuesAPITests (2), UICustomizationPreferencesTests (2+); "Executed ~1355 tests, with 14 failures" is the green baseline. Any OTHER failure is yours to fix; a changed total must be explained by tests you added/removed.
`

const BUILD_CMDS = {
  ios: `xcodebuild build -project Silo.xcodeproj -scheme Silo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E '^\\*\\* BUILD|error:' | head -40`,
  tvos: `xcodebuild build -project Silo.xcodeproj -scheme SiloTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E '^\\*\\* BUILD|error:' | head -40`,
  macos: `xcodebuild build -project Silo.xcodeproj -scheme SiloMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E '^\\*\\* BUILD|error:' | head -40`,
}
const SIM_TEMPLATE_UDID = (args && args.simTemplateUdid) || '89473B29-E0D9-4FB2-83DA-D16856E3BC70'
function testCmd(id) {
  return `SIM=$(xcrun simctl clone ${SIM_TEMPLATE_UDID} "remed-${id}") && echo "sim=$SIM" && xcodebuild test -project Silo.xcodeproj -scheme Silo -destination "id=$SIM" CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E 'Executed|\\*\\* TEST|error:|failed' | tail -30; xcrun simctl shutdown "$SIM" >/dev/null 2>&1; xcrun simctl delete "$SIM"`
}

function fixerPrompt(pkg) {
  const scopes = (pkg.build_scopes && pkg.build_scopes.length) ? pkg.build_scopes : ['ios', 'tvos', 'macos']
  const buildBlock = scopes.map(s => `  # ${s}\n  ${BUILD_CMDS[s]}`).join('\n')
  return `You are implementing ONE remediation work package in silo-apple. You are inside a dedicated git worktree (run \`git rev-parse --show-toplevel\` and use that absolute path for everything; do NOT touch any other checkout of this repo).
${REPO_CONTEXT}
PACKAGE ${pkg.id}: ${pkg.title}
Area: ${pkg.area}   Risk: ${pkg.risk}
Files you may edit: ${pkg.files.join(', ')}
Tests you may add/edit: ${(pkg.tests && pkg.tests.length) ? pkg.tests.join(', ') : '(as the brief says)'}

BRIEF AND FINDINGS: read ${pkg.spec_path} FIRST (JSON: "brief" = ordered implementer brief with hard boundaries; "findings" = the defects with review-row ids, evidence, files/anchors and the smallest safe correction). Then read the cited review sections and slice files. Follow the brief's step order.

RULES
- Implement exactly what the brief asks — the smallest correct fix, not a redesign. No new abstractions beyond what the brief names. Do not reformat untouched code. Do not "improve" nearby code.
- If a finding turns out to be wrong at the base commit (evidence doesn't hold), SKIP it, record why with file:line, and continue. Never force a fix.
- Stay inside the file list. If a fix genuinely requires another file (a caller, a test, project.yml), keep it minimal and list it under files_outside_package with the reason.
- Tests: add exactly the tests the brief names (or explains why they cannot be written at this base and what seam is missing). Existing tests that pinned the defective behavior must be updated to pin the corrected behavior — say so in notes.
- Every behavior change must be intentional and listed in behavior_changes, per platform.
- If you edit iosApp/project.yml, regenerate. In a fresh worktree Silo.xcodeproj does not exist yet, so generate before building anyway.

STEPS
0. BASE — MANDATORY FIRST ACTION. The harness creates worktrees from the repository's default branch, NOT this package's base. Run in the worktree root:
     git reset --hard ${BASE_REF} && git rev-parse HEAD
   HEAD MUST print ${BASE_REF}. If not, stop and report status=failed. Record it as base_sha. Do not read or edit any file before this step.
1. git checkout -b ${BRANCH_PREFIX}/${pkg.id}
2. Read every file in the package (and the cited review/slice sections) before editing. Apply findings in the brief's order so intermediate states compile.
3. Verify — from <root>/iosApp:
  xcodegen generate
${buildBlock}
${RUN_TESTS ? `  # tests — ALWAYS use your own cloned simulator (other packages run concurrently); the command clones, runs, and deletes it:\n  ${testCmd(pkg.id)}` : '  # tests: skipped by workflow args'}
  "** BUILD FAILED **" or any "error:" line means you are not done. If tests fail on something you didn't touch, note it rather than "fixing" unrelated tests.
4. Commit on ${BRANCH_PREFIX}/${pkg.id} with a clear message ("fix(player): <what>", body listing the finding ids and behavior changes). Do NOT push. Do NOT merge. Do NOT delete the worktree.
5. Report via the structured output tool.`
}

function reviewerPrompt(pkg, fix) {
  return `You are independently reviewing a remediation commit in silo-apple before merge. Read-only: do NOT edit files, do NOT commit.
${REPO_CONTEXT}
PACKAGE ${pkg.id}: ${pkg.title} (area ${pkg.area}, risk ${pkg.risk})
Brief + findings the implementer followed: READ ${pkg.spec_path} first, then the cited review §3 rows / slice files.

Implementer report:
${JSON.stringify(fix, null, 2)}

HOW TO REVIEW
- Expected base: ${BASE_REF}. Confirm \`git merge-base ${BASE_REF} ${fix.head_sha}\` prints ${BASE_REF} and ${fix.base_sha} == ${BASE_REF}; if not, verdict=reject.
- From the main checkout (cwd): git diff ${fix.base_sha}..${fix.head_sha} --stat  and  git diff ${fix.base_sha}..${fix.head_sha}. (To build, use the worktree at ${fix.worktree_path}; if gone: git worktree add ${SCRATCH}/review-${pkg.id} ${fix.branch}.)
- For EVERY finding in the spec: verify the defect is actually fixed at head (re-trace the control flow the review cited), or that the skip reason is correct. Fill findings_verified per id.
- Trace before/after on all three platforms: nil/edge cases, ordering, threading (@MainActor / actor reentrancy), task lifetimes, generation/identity guards. Confirm the fix is the smallest correct one and introduces no new race.
- Check that behavior_changes is complete and honest; check scope creep (unrelated edits, renames, new abstractions not in the brief).
- Check the tests the brief required exist and assert the corrected behavior (not the old); check reported build/test results are credible (schemes built vs files touched).
- Do NOT nitpick style. Raise only real behavior/compile/maintainability problems.

Verdict: approve / request-changes (concrete fixes; ONE repair round) / reject. Report via the structured output tool.`
}

function repairPrompt(pkg, fix, review) {
  return `You are doing a ONE-round repair on a remediation commit in silo-apple after independent review.
${REPO_CONTEXT}
PACKAGE ${pkg.id}: ${pkg.title}
Branch: ${fix.branch}   base_sha: ${fix.base_sha}   current head: ${fix.head_sha}
Worktree: ${fix.worktree_path} — if gone: git worktree add ${SCRATCH}/repair-${pkg.id} ${fix.branch}. Use \`git rev-parse --show-toplevel\` for absolute paths. Do NOT touch any other checkout.

Reviewer verdict: ${review.verdict}
Reviewer summary: ${review.summary}
Behavior risk noted: ${review.behavior_risk}
Issues to address:
${JSON.stringify(review.issues, null, 2)}
Findings the reviewer marked unfixed:
${JSON.stringify((review.findings_verified || []).filter(f => !f.fixed), null, 2)}

Original brief + findings: READ ${pkg.spec_path}.

Address every blocker/major (minor if cheap). If an issue is wrong, say so in notes with evidence rather than changing code. Rebuild the affected schemes (cd <root>/iosApp && xcodegen generate && xcodebuild for ${(pkg.build_scopes || ['ios', 'tvos', 'macos']).join(', ')} with CODE_SIGNING_ALLOWED=NO)${RUN_TESTS ? `, run the iOS suite on a cloned simulator (\`${testCmd(pkg.id + '-repair')}\`)` : ''}, commit on the SAME branch (no amend, no push, no merge). Report via the structured output tool with the new head_sha.`
}

phase('Implement')
const results = await pipeline(
  PACKAGES,
  pkg => agent(fixerPrompt(pkg), { label: `fix:${pkg.id}`, phase: 'Implement', schema: FIX_RESULT_SCHEMA, model: FIXER_MODEL, isolation: 'worktree', ...(pkg.effort ? { effort: pkg.effort } : {}) })
    .then(fix => ({ pkg, fix })),
  async (r, pkg) => {
    if (!r || !r.fix) return { pkg, fix: null, review: null, error: 'fixer returned nothing' }
    if (r.fix.status === 'failed') return { ...r, review: null }
    if (!r.fix.base_sha || !r.fix.base_sha.startsWith(BASE_REF.slice(0, 12))) {
      log(`Package ${pkg.id}: WRONG BASE (${r.fix.base_sha}) — expected ${BASE_REF}; not reviewing`)
      return { ...r, fix: { ...r.fix, status: 'failed', notes: `WRONG BASE ${r.fix.base_sha}; ` + (r.fix.notes || '') }, review: null }
    }
    const review = await agent(reviewerPrompt(pkg, r.fix), { label: `review:${pkg.id}`, phase: 'Review', schema: REVIEW_SCHEMA, model: REVIEWER_MODEL, ...(pkg.effort ? { effort: pkg.effort } : {}) })
    return { ...r, review }
  },
  async (r, pkg) => {
    if (!r || !r.fix || !r.review) return r
    if (r.review.verdict !== 'request-changes') return r
    log(`Package ${pkg.id}: reviewer requested changes (${r.review.issues.length} issues) — repair round`)
    const repaired = await agent(repairPrompt(pkg, r.fix, r.review), { label: `repair:${pkg.id}`, phase: 'Repair', schema: FIX_RESULT_SCHEMA, model: FIXER_MODEL, ...(pkg.effort ? { effort: pkg.effort } : {}) })
    if (!repaired) return { ...r, repair: null }
    const rereview = await agent(reviewerPrompt(pkg, repaired), { label: `re-review:${pkg.id}`, phase: 'Repair', schema: REVIEW_SCHEMA, model: REVIEWER_MODEL, ...(pkg.effort ? { effort: pkg.effort } : {}) })
    return { ...r, repair: repaired, rereview, finalFix: repaired, finalReview: rereview }
  },
)

const summary = results.filter(Boolean).map(r => {
  const fix = r.finalFix || r.fix
  const review = r.finalReview || r.review
  return {
    id: r.pkg.id, title: r.pkg.title,
    status: fix ? fix.status : 'failed',
    branch: fix ? fix.branch : null, base_sha: fix ? fix.base_sha : null, head_sha: fix ? fix.head_sha : null,
    worktree: fix ? fix.worktree_path : null,
    loc_delta: fix ? fix.loc_delta : 0,
    builds: fix ? fix.builds : [], tests: fix ? fix.tests : null, tests_added: fix ? fix.tests_added : [],
    applied: fix ? fix.applied.map(a => a.id) : [], skipped: fix ? fix.skipped : [],
    files_outside_package: fix ? fix.files_outside_package : [],
    behavior_changes: fix ? fix.behavior_changes : '',
    verdict: review ? review.verdict : 'unreviewed',
    review_summary: review ? review.summary : (r.error || ''),
    findings_verified: review ? review.findings_verified : [],
    open_issues: review ? review.issues.filter(i => i.severity !== 'minor') : [],
    behavior_risk: review ? review.behavior_risk : '',
    had_repair_round: !!r.repair,
  }
})
const approved = summary.filter(s => s.verdict === 'approve')
log(`Remediation: ${approved.length}/${summary.length} packages approved; net LOC ${summary.reduce((n, s) => n + (s.loc_delta || 0), 0)}`)
return { approved: approved.map(s => s.id), summary }
