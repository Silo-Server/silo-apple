export const meta = {
  name: 'app-cleanup-fix',
  description: 'Execute cleanup work packages from app-cleanup-survey: one Opus implementer per package in its own worktree, independent review, one repair round',
  whenToUse: 'Second half of the app cleanup loop. Pass {packages, baseRef} from a reviewed app-cleanup-survey result. Branches cleanup/<id> are left for the orchestrator to merge.',
  phases: [
    { title: 'Implement', detail: 'one Opus fixer per package, isolated worktree', model: 'opus' },
    { title: 'Review', detail: 'independent Opus diff review per package', model: 'opus' },
    { title: 'Repair', detail: 'one round of fixes if the reviewer objects', model: 'opus' },
  ],
}

if (!args || !Array.isArray(args.packages) || args.packages.length === 0) throw new Error('args.packages (from app-cleanup-survey) is required')
const PACKAGES = args.packages
const BASE_REF = args.baseRef || 'HEAD'
const FIXER_MODEL = args.fixerModel || 'opus'
const REVIEWER_MODEL = args.reviewerModel || 'opus'
const RUN_TESTS = args.runTests !== false
const BRANCH_PREFIX = args.branchPrefix || 'cleanup'
if (!/^[0-9a-f]{40}$/.test(BASE_REF)) throw new Error('args.baseRef must be a full 40-char commit SHA (the branch the cleanup lands on), got: ' + BASE_REF)
const SCRATCH = args.scratchDir || '/private/tmp/claude-501/-Volumes-NVMe-dev-github-SiloServer-silo-apple/66acf2f6-279f-4928-9560-8e8dac511153/scratchpad/worktrees'

// ---------------------------------------------------------------------------
// Schemas
// ---------------------------------------------------------------------------
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
    files_outside_package: { type: 'array', items: { type: 'string' }, description: 'files edited that were NOT in the package file list, with why in notes' },
    loc_delta: { type: 'integer', description: 'net lines changed per git diff --shortstat (insertions - deletions)' },
    builds: { type: 'array', items: { type: 'object', properties: { scheme: { type: 'string' }, result: { type: 'string', enum: ['succeeded', 'failed', 'skipped'] }, detail: { type: 'string' } }, required: ['scheme', 'result'] } },
    tests: { type: 'object', properties: { ran: { type: 'boolean' }, result: { type: 'string' }, detail: { type: 'string' } }, required: ['ran', 'result'] },
    notes: { type: 'string' },
  },
  required: ['status', 'worktree_path', 'branch', 'base_sha', 'head_sha', 'applied', 'skipped', 'files_changed', 'files_outside_package', 'loc_delta', 'builds', 'tests', 'notes'],
}
const REVIEW_SCHEMA = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['approve', 'request-changes', 'reject'] },
    summary: { type: 'string' },
    issues: { type: 'array', items: { type: 'object', properties: { severity: { type: 'string', enum: ['blocker', 'major', 'minor'] }, file: { type: 'string' }, line: { type: 'integer' }, problem: { type: 'string' }, fix: { type: 'string' } }, required: ['severity', 'file', 'problem', 'fix'] } },
    behavior_risk: { type: 'string', description: 'any place the diff could change runtime behavior on iOS/tvOS/macOS, or "none found"' },
  },
  required: ['verdict', 'summary', 'issues', 'behavior_risk'],
}

// ---------------------------------------------------------------------------
// Prompts
// ---------------------------------------------------------------------------
const REPO_CONTEXT = `
Repository: silo-apple (Swift/SwiftUI clients for iOS, tvOS, macOS).
- App sources iosApp/iosApp/, tests iosApp/Tests/, Top Shelf iosApp/TopShelf/, extensions iosApp/NotificationService/ + iosApp/DownloadsActivity/.
- Target membership is in iosApp/project.yml (XcodeGen). Silo (iOS), SiloTV (tvOS), SiloMac (macOS) all compile most of iosApp/iosApp/; extension targets pull individual shared files (see project.yml). Never hand-edit Silo.xcodeproj; edit project.yml and regenerate.
- The team is mid-way through a single-PR streamlining program on branch player/architecture-remediation (single AVPlayer-based player; the FFmpeg backend, the on-device video bridge tier, the EVENT kill-switch, the ContinuumAPI string dispatcher and the legacy quality helpers are already deleted). Cleanups must not change behavior on any platform. docs/cleanup/app-cleanup-backlog.md §3 lists what is intentionally kept.
- Xcode DerivedData lives at /Volumes/NVMe/DeveloperCache/xcode-derived-data (already configured); a cold build takes several minutes — that is expected, wait for it. The iOS test suite (~1355 tests) takes ~10 minutes including simulator boot.
- BASELINE TEST FAILURES: on the base branch some tests already fail (profile/identity/keychain simulator-environment issues) and are NOT regressions — ProfileLaunchIdentityTests, ProfileLaunchMigrationTests, SettingValuesAPITests, UICustomizationPreferencesTests; the green baseline is "Executed 1528 tests, 3 skipped, up to 14 failures" ALL inside those four families (some hosts see only 2 of them; the 3 skips are keychain-migration tests when the sim host cannot write the keychain). Any failure OUTSIDE those families, or a change in the total count you can't explain by tests you removed/added, is yours to fix.
`

const BUILD_CMDS = {
  ios: `xcodebuild build -project Silo.xcodeproj -scheme Silo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E '^\\*\\* BUILD|error:' | head -40`,
  tvos: `xcodebuild build -project Silo.xcodeproj -scheme SiloTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E '^\\*\\* BUILD|error:' | head -40`,
  macos: `xcodebuild build -project Silo.xcodeproj -scheme SiloMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E '^\\*\\* BUILD|error:' | head -40`,
}
const SIM_TEMPLATE_UDID = (args && args.simTemplateUdid) || '89473B29-E0D9-4FB2-83DA-D16856E3BC70' // iPhone 17 Pro, iOS 26.5
function testCmd(id) {
  return `SIM=$(xcrun simctl clone ${SIM_TEMPLATE_UDID} "cleanup-${id}") && echo "sim=$SIM" && xcodebuild test -project Silo.xcodeproj -scheme Silo -destination "id=$SIM" CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E 'Executed|\\*\\* TEST|error:|failed' | tail -20; xcrun simctl shutdown "$SIM" >/dev/null 2>&1; xcrun simctl delete "$SIM"`
}

function specBlock(pkg) {
  if (pkg.spec_path) {
    return `BRIEF AND FINDINGS: read ${pkg.spec_path} FIRST (JSON: "brief" = ordered implementer brief with hard boundaries; "findings" = the verified findings with evidence, files, anchors and proposed changes). Follow the brief's step order. Findings were already verified by a skeptic; still re-check each before deleting — grep the whole repo for the symbol, including string-keyed uses.`
  }
  return `BRIEF:\n${pkg.brief}\n\nFINDINGS (already verified by a skeptic; still re-check each before deleting — grep the whole repo for the symbol, including string-keyed uses):\n${JSON.stringify(pkg.findings, null, 2)}`
}

function fixerPrompt(pkg) {
  const scopes = (pkg.build_scopes && pkg.build_scopes.length) ? pkg.build_scopes : ['ios', 'tvos', 'macos']
  const buildBlock = scopes.map(s => `  # ${s}\n  ${BUILD_CMDS[s]}`).join('\n')
  return `You are implementing ONE cleanup work package in silo-apple. You are inside a dedicated git worktree (run \`git rev-parse --show-toplevel\` and use that absolute path for everything; do NOT touch any other checkout of this repo).
${REPO_CONTEXT}
PACKAGE ${pkg.id}: ${pkg.title}
Area: ${pkg.area}   Risk: ${pkg.risk}   Estimated net LOC: ${pkg.est_loc_delta}
Files you may edit: ${pkg.files.join(', ')}
Relevant tests: ${(pkg.tests && pkg.tests.length) ? pkg.tests.join(', ') : '(none identified)'}

${specBlock(pkg)}

RULES
- Cleanup only: remove/simplify. Do not add new abstractions, protocols, or "helper" layers. Do not rename for taste. Do not reformat untouched code. Behavior on iOS, tvOS, macOS and the extensions must be identical afterwards.
- Stay inside the file list above. If a finding genuinely requires touching another file (a caller, a test, project.yml), you may — but keep it minimal and list it under files_outside_package with the reason. If a finding turns out to be wrong (symbol IS used, behavior WOULD change), skip it and record why; never force it.
- Tests: if you delete code that tests reference, delete or trim those tests too (they live in iosApp/Tests/). Do not write new tests unless a finding says so.
- If you edit iosApp/project.yml, you must regenerate the project. In a fresh worktree Silo.xcodeproj does not exist yet, so you must generate it before building anyway.

STEPS
0. BASE — MANDATORY FIRST ACTION. The harness creates worktrees from the repository's default branch, which is NOT the branch this cleanup targets. Run, in the worktree root:
     git reset --hard ${BASE_REF} && git rev-parse HEAD
   HEAD MUST print ${BASE_REF}. If it does not, stop and report status=failed. Record it as base_sha. Do not read or edit any file before this step.
1. git checkout -b ${BRANCH_PREFIX}/${pkg.id}
2. Read every file in the package before editing. Apply the findings in the order the brief gives so intermediate states compile.
3. Verify — from <root>/iosApp:
  xcodegen generate
${buildBlock}
${RUN_TESTS ? `  # tests — ALWAYS use your own cloned simulator (other packages run tests concurrently on this machine); the command clones, runs, and deletes it:\n  ${testCmd(pkg.id)}` : '  # tests: skipped by workflow args'}
  A build that prints "** BUILD FAILED **" or any "error:" line means you are not done — fix it. If tests fail on something you didn't touch, note it in notes rather than "fixing" unrelated tests.
4. Commit everything on ${BRANCH_PREFIX}/${pkg.id} with a clear message ("cleanup(${pkg.area}): <what>", body listing the finding ids applied). Do NOT push. Do NOT merge into any other branch. Do NOT delete the worktree.
5. Report via the structured output tool: worktree path, branch, base_sha, head_sha (git rev-parse HEAD after commit), applied/skipped per finding, files changed, loc_delta from git diff --shortstat base_sha..head_sha, build/test results, and notes.`
}

function reviewerPrompt(pkg, fix) {
  return `You are independently reviewing a cleanup commit in silo-apple before it is merged. Read-only: do NOT edit files, do NOT commit.
${REPO_CONTEXT}
PACKAGE ${pkg.id}: ${pkg.title} (area ${pkg.area}, risk ${pkg.risk})
${pkg.spec_path ? `Brief + findings the implementer followed: READ ${pkg.spec_path} first (JSON with "brief" and "findings").` : `Brief the implementer followed:\n${pkg.brief}\nFindings they were given:\n${JSON.stringify((pkg.findings || []).map(f => ({ id: f.id, title: f.title, category: f.category, files: f.files, proposed_change: f.proposed_change, risk: f.risk })), null, 2)}`}

Implementer report:
${JSON.stringify(fix, null, 2)}

HOW TO REVIEW
- Expected base commit: ${BASE_REF}. Confirm \`git merge-base ${BASE_REF} ${fix.head_sha}\` prints ${BASE_REF} and that ${fix.base_sha} == ${BASE_REF}; if not, verdict=reject (wrong base — the branch would not land on the target).
- From the main repo checkout (cwd) run: git diff ${fix.base_sha}..${fix.head_sha} --stat  and  git diff ${fix.base_sha}..${fix.head_sha}
  (If you need to build, use the worktree at ${fix.worktree_path}; if it no longer exists, git worktree add ${SCRATCH}/review-${pkg.id} ${fix.branch} and build there from its iosApp/ folder.)
- For every deletion, satisfy yourself the symbol has no remaining reference anywhere (grep the whole repo incl. Tests, TopShelf, extensions, project.yml, plists; remember string-keyed uses and #if os(...) blocks and tvOS/ + macOS/ folders).
- For every simplification, trace the before/after logic on all three platforms and confirm identical behavior — including nil/edge cases, ordering, threading (@MainActor), and Combine/async lifetimes.
- Check the diff for scope creep: unrelated reformatting, renames, new abstractions, or edits outside the package's file list that aren't justified in the report.
- Check the reported build/test results are credible (the report says which schemes were built; if a shared file changed and macOS wasn't built, that's a finding).
- Do NOT nitpick style. Only raise things that would be a real problem for behavior, compile on some platform, or maintainability.

Verdict: approve (merge as-is), request-changes (list concrete fixes — the implementer gets ONE repair round), reject (fundamentally wrong; explain). Report via the structured output tool.`
}

function repairPrompt(pkg, fix, review) {
  return `You are doing a ONE-round repair on a cleanup commit in silo-apple after independent review.
${REPO_CONTEXT}
PACKAGE ${pkg.id}: ${pkg.title}
Branch: ${fix.branch}   base_sha: ${fix.base_sha}   current head: ${fix.head_sha}
Worktree: ${fix.worktree_path}  — if that path no longer exists, run: git worktree add ${SCRATCH}/repair-${pkg.id} ${fix.branch}  and work there. Use \`git rev-parse --show-toplevel\` inside it for absolute paths. Do NOT touch any other checkout.

Reviewer verdict: ${review.verdict}
Reviewer summary: ${review.summary}
Behavior risk noted: ${review.behavior_risk}
Issues to address:
${JSON.stringify(review.issues, null, 2)}

${pkg.spec_path ? `Original brief + findings: READ ${pkg.spec_path}.` : `Original brief:\n${pkg.brief}`}

Address every blocker/major issue (minor ones if cheap). If an issue is wrong, say so in notes with evidence rather than changing code. Then rebuild the affected schemes (cd <root>/iosApp && xcodegen generate && the xcodebuild commands for ${(pkg.build_scopes || ['ios', 'tvos', 'macos']).join(', ')} with CODE_SIGNING_ALLOWED=NO)${RUN_TESTS ? `, run the iOS test suite on a cloned simulator (\`${testCmd(pkg.id + '-repair')}\`)` : ''}, and commit on the SAME branch (do not amend, do not push, do not merge). Report via the structured output tool with the new head_sha.`
}

// ---------------------------------------------------------------------------
// Pipeline: implement -> review -> (repair -> re-review)
// ---------------------------------------------------------------------------
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
    id: r.pkg.id,
    title: r.pkg.title,
    status: fix ? fix.status : 'failed',
    branch: fix ? fix.branch : null,
    base_sha: fix ? fix.base_sha : null,
    head_sha: fix ? fix.head_sha : null,
    worktree: fix ? fix.worktree_path : null,
    loc_delta: fix ? fix.loc_delta : 0,
    builds: fix ? fix.builds : [],
    tests: fix ? fix.tests : null,
    applied: fix ? fix.applied.map(a => a.id) : [],
    skipped: fix ? fix.skipped : [],
    files_outside_package: fix ? fix.files_outside_package : [],
    verdict: review ? review.verdict : 'unreviewed',
    review_summary: review ? review.summary : (r.error || ''),
    open_issues: review ? review.issues.filter(i => i.severity !== 'minor') : [],
    behavior_risk: review ? review.behavior_risk : '',
    had_repair_round: !!r.repair,
  }
})
const approved = summary.filter(s => s.verdict === 'approve')
log(`Fix: ${approved.length}/${summary.length} packages approved; net LOC ${summary.reduce((n, s) => n + (s.loc_delta || 0), 0)}`)
return { approved: approved.map(s => s.id), summary }
