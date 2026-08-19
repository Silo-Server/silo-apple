export const meta = {
  name: 'player-stage2-fix',
  description: 'Stage 2 control-plane extraction, one WAVE per run: Opus implementer per package in its own worktree (design-driven, behaviour-identical unless the spec lists a change), independent Opus review against the design doc, one repair round',
  whenToUse: 'Player architecture remediation Stage 2 (hard cutover). Pass {baseRef, wave, packages} where each package has spec_path (JSON with design_ref, brief, deliverables, invariants, tests_required, deletions, behavior_changes_allowed). Packages in one wave must be file-disjoint; waves are sequential — merge the approved branches, then run the next wave with the new tip as baseRef. Branches stage2/<id> are left for the orchestrator to merge.',
  phases: [
    { title: 'Implement', detail: 'one Opus implementer per package, isolated worktree, effort high/max', model: 'opus' },
    { title: 'Review', detail: 'independent Opus review against the Stage 2 design doc', model: 'opus' },
    { title: 'Repair', detail: 'one round of fixes if the reviewer objects', model: 'opus' },
  ],
}

if (!args || !Array.isArray(args.packages) || args.packages.length === 0) throw new Error('args.packages is required')
const PACKAGES = args.packages
const BASE_REF = args.baseRef
const WAVE = args.wave || '?'
const FIXER_MODEL = args.fixerModel || 'opus'
const REVIEWER_MODEL = args.reviewerModel || 'opus'
const RUN_TESTS = args.runTests !== false
const BRANCH_PREFIX = args.branchPrefix || 'stage2'
if (!/^[0-9a-f]{40}$/.test(BASE_REF || '')) throw new Error('args.baseRef must be a full 40-char commit SHA, got: ' + BASE_REF)
const SCRATCH = args.scratchDir || '/Volumes/NVMe/DeveloperCache/scratch/silo-apple-stage2/worktrees'
const REVIEW_DOC = 'docs/cleanup/player-review/2026-08-17-architecture-review.md'
const DESIGN_DOC = args.designDoc || 'docs/cleanup/player-review/2026-08-19-stage2-design.md'

// file-disjointness is a hard precondition for a wave
{
  const owner = new Map()
  for (const p of PACKAGES) for (const f of (p.files || [])) {
    if (owner.has(f) && owner.get(f) !== p.id) throw new Error(`wave ${WAVE}: file ${f} is claimed by both ${owner.get(f)} and ${p.id} — packages in one wave must be file-disjoint`)
    owner.set(f, p.id)
  }
}

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
Repository: silo-apple (Swift/SwiftUI clients for iOS, tvOS, macOS). App sources iosApp/iosApp/, tests iosApp/Tests/ (XCTest, target SiloTests, @testable import Silo), Top Shelf iosApp/TopShelf/. Target membership is in iosApp/project.yml (XcodeGen); SiloTests sources are a directory glob, so a NEW Swift file under iosApp/iosApp/ or iosApp/Tests/ needs only \`cd iosApp && xcodegen generate\` — never hand-edit Silo.xcodeproj, never commit it. Silo (iOS), SiloTV (tvOS), SiloMac (macOS) compile most of iosApp/iosApp/ (SiloMac excludes Screens/Player/tvOS/**; extension targets pull named files — check project.yml before adding a file a target must see).
- PROGRAM: branch player/architecture-remediation is a single-PR streamlining program (docs/cleanup/HANDOFF.md is the entry point). The independent architecture review ${REVIEW_DOC} (§2 ownership map, §4 trouble spots, §5 essential vs accidental, §8 target architecture, §9 staged plan, §11 test/validation matrix; per-slice evidence under docs/cleanup/player-review/slices/) ranked 16 defects; R1/R2 fixed 14 and added the typed PlaybackFailure channel, injected AVPlayer and 73+ characterization tests; rounds 5–6 removed ~2.6k lines of duplication. THIS is Stage 2 (review §9): extract the playback control plane — pure reducer, session actor, engine session, ONE RecoveryPolicy, TrackSelectionCoordinator — and ship it as a HARD CUTOVER (owner decision P11, 2026-08-18: no runtime flag, no staged rollout; the legacy VM core + backend ladders are deleted in the same effort; rollback is a new TestFlight build). The design that every package follows is ${DESIGN_DOC} — READ IT FIRST, then your spec, then the review sections it cites. Review/slice line numbers are from 2026-08-17 and have drifted; the design doc's anchors are from the wave base — re-grep anyway.
- NON-NEGOTIABLES: (1) behaviour identical on iOS, tvOS, macOS and in the extensions except where your spec's behavior_changes_allowed lists a change (then list it in behavior_changes, per platform); (2) every effect carries identity (LoadID / SessionIdentity) and every mutation is conditional on it — no by-value generation capture, no string session-id compares; (3) ONE owner per policy — no second ladder, no second replan slot, no new "pending*" optional; (4) do not touch the essential media plane the review fences off: ISOBoxSurgery, LoopbackSegmentPlan/Cutter, the subtitle renderer, the writer's mux internals (its LIFECYCLE may move under the engine session only if your spec says so); (5) docs/tvos-focus.md for any tvOS focus code; (6) backlog §3 intentionally-kept list stands; (7) no wire/contract changes (silo-server / silo-android are separate repos).
- VERIFICATION: Xcode DerivedData at /Volumes/NVMe/DeveloperCache/xcode-derived-data; cold builds take minutes, the suite ~10 min — wait. BASELINE: the suite is genuinely green — at the Stage 2 base it reads "Executed 1539 tests, with 3 tests skipped and 0 failures" (3 keychain-migration skips on an unsigned test host). ANY failure is yours to fix; a changed total must be explained by tests you added/removed/rewrote (characterization tests that pinned the legacy mechanism are REWRITTEN as reducer/policy tests when the spec says so — never deleted silently; the spec names which). Take a same-host control at the base SHA before reading a delta.
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
  return `You are implementing ONE Stage 2 work package (wave ${WAVE}) in silo-apple. You are inside a dedicated git worktree (run \`git rev-parse --show-toplevel\` and use that absolute path for everything; do NOT touch any other checkout of this repo).
${REPO_CONTEXT}
PACKAGE ${pkg.id}: ${pkg.title}
Area: ${pkg.area}   Risk: ${pkg.risk}   Wave: ${WAVE}
Files you may edit or create: ${pkg.files.join(', ')}
Tests you may add/edit: ${(pkg.tests && pkg.tests.length) ? pkg.tests.join(', ') : '(as the spec says)'}
${pkg.depends_on && pkg.depends_on.length ? `Depends on (already merged into the base): ${pkg.depends_on.join(', ')}` : ''}

SPEC: read ${pkg.spec_path} FIRST. It is JSON with: design_ref (sections of ${DESIGN_DOC} this package realises), brief (ordered steps with hard boundaries), deliverables (the exact types/functions/files to create or move — names are binding), invariants (behaviour that must be provably unchanged — the reviewer will trace each), tests_required (characterization/reducer/policy tests to add or rewrite — names are binding), deletions (legacy code that MUST be gone at head when listed, with the grep the reviewer will run), behavior_changes_allowed (the only permitted runtime differences). Then read the design doc sections in design_ref and the review/slice sections they cite.

RULES
- Design-driven, not free-form: realise the deliverables as named; no additional abstractions, protocols, managers or helper layers beyond them. If a deliverable cannot be realised without breaking an invariant or an actor-isolation boundary, STOP that step, keep the code compiling, and report it under skipped with evidence — never force it, never "improve" the design unilaterally.
- Tests first where the spec says so: write/port the characterization tests named in tests_required BEFORE cutting code over, run them against the legacy path (they must pass), then cut over and run them again.
- Keep every intermediate commit-able: apply the brief's steps in order so the tree compiles on all three schemes after each step.
- Stay inside the file list (new files named in deliverables count as inside). If a step genuinely requires another file (a caller, project.yml), keep it minimal and list it under files_outside_package with the reason.
- Do not reformat untouched code; do not rename for taste; do not leave legacy code commented out — deletions are real deletions.
- Every runtime difference must be intentional, within behavior_changes_allowed, and listed in behavior_changes per platform. "I think it's equivalent" is not enough for anything in invariants — trace it and say how.
- If you edit iosApp/project.yml, regenerate. In a fresh worktree Silo.xcodeproj does not exist yet, so generate before building anyway.

STEPS
0. BASE — MANDATORY FIRST ACTION. The harness creates worktrees from the repository's default branch, NOT this wave's base. Run in the worktree root:
     git reset --hard ${BASE_REF} && git rev-parse HEAD
   HEAD MUST print ${BASE_REF}. If not, stop and report status=failed. Record it as base_sha. Do not read or edit any file before this step.
1. git checkout -b ${BRANCH_PREFIX}/${pkg.id}
2. Read the design doc sections, the spec, every file in the package and the cited review/slice sections before editing.
3. Implement in the brief's order. Verify — from <root>/iosApp:
  xcodegen generate
${buildBlock}
${RUN_TESTS ? `  # tests — ALWAYS use your own cloned simulator (other packages run concurrently); the command clones, runs, and deletes it:\n  ${testCmd(pkg.id)}\n  # take a same-host CONTROL at the base SHA once (git stash / a second clone is NOT allowed in this worktree — use \`git worktree add ${SCRATCH}/control-${pkg.id} ${BASE_REF}\` and run the same command there from its iosApp/ folder, then remove that worktree).` : '  # tests: skipped by workflow args'}
  "** BUILD FAILED **" or any "error:" line means you are not done. A failing test you did not touch is still yours to explain.
4. Commit on ${BRANCH_PREFIX}/${pkg.id} with a clear message ("stage2(<area>): <what>", body listing deliverables realised, deletions, tests added/rewritten, behavior changes). One commit per brief step is fine; do NOT push, do NOT merge, do NOT delete the worktree.
5. Report via the structured output tool: applied = deliverables realised (id = deliverable name), skipped = deliverables not realised with evidence, tests_added, deletions confirmed (in notes, with the grep output), behavior_changes, loc_delta from git diff --shortstat base..head.`
}

function reviewerPrompt(pkg, fix) {
  return `You are independently reviewing a Stage 2 (wave ${WAVE}) commit in silo-apple before merge. Read-only: do NOT edit files, do NOT commit.
${REPO_CONTEXT}
PACKAGE ${pkg.id}: ${pkg.title} (area ${pkg.area}, risk ${pkg.risk})
Spec the implementer followed: READ ${pkg.spec_path} first (design_ref, brief, deliverables, invariants, tests_required, deletions, behavior_changes_allowed), then the design doc sections it references and the review/slice sections those cite.

Implementer report:
${JSON.stringify(fix, null, 2)}

HOW TO REVIEW
- Expected base: ${BASE_REF}. Confirm \`git merge-base ${BASE_REF} ${fix.head_sha}\` prints ${BASE_REF} and ${fix.base_sha} == ${BASE_REF}; if not, verdict=reject.
- From the main checkout (cwd): git diff ${fix.base_sha}..${fix.head_sha} --stat  and  git diff ${fix.base_sha}..${fix.head_sha}. (To build/test, use the worktree at ${fix.worktree_path}; if gone: git worktree add ${SCRATCH}/review-${pkg.id} ${fix.branch} and work from its iosApp/ folder on your OWN cloned simulator.)
- DELIVERABLES: every named type/function/file exists with the named shape and lives where the spec says; nothing extra was invented (no second abstraction layer, no new manager). Fill findings_verified with one entry per deliverable (id = deliverable name, fixed = realised).
- INVARIANTS: trace EACH listed invariant before/after on all three platforms — ordering, nil/edge cases, actor isolation and reentrancy, task lifetimes, identity stamping (LoadID/SessionIdentity on every effect; mutation conditional on identity; no by-value generation capture left where the spec says it must be gone), seek deadlines, the product-essential "keep the live backend across an in-place replan on tvOS" path, teardown completeness. A plausible-sounding "equivalent" is not verification — re-derive it from the code.
- DELETIONS: run the greps the spec lists; legacy ladders/fields/latches the spec says must be gone must have zero references (app, Tests, TopShelf, extensions, docs).
- TESTS: the tests_required exist by name and assert the new behaviour (reducer/policy tables, not the legacy mechanism); rewritten characterization tests still pin the same product/wire contract; the reported suite total is explained; build coverage matches files touched (SiloMac for shared files, SiloTV for tvOS/ files).
- BEHAVIOUR: behavior_changes must be complete, honest and inside behavior_changes_allowed; anything else is a blocker.
- Scope creep (unrelated edits, renames, reformatting) is a real finding; style is not.

Verdict: approve / request-changes (concrete fixes; ONE repair round) / reject (wrong base or the design was not followed). Report via the structured output tool.`
}

function repairPrompt(pkg, fix, review) {
  return `You are doing a ONE-round repair on a Stage 2 (wave ${WAVE}) commit in silo-apple after independent review.
${REPO_CONTEXT}
PACKAGE ${pkg.id}: ${pkg.title}
Branch: ${fix.branch}   base_sha: ${fix.base_sha}   current head: ${fix.head_sha}
Worktree: ${fix.worktree_path} — if gone: git worktree add ${SCRATCH}/repair-${pkg.id} ${fix.branch}. Use \`git rev-parse --show-toplevel\` for absolute paths. Do NOT touch any other checkout.

Reviewer verdict: ${review.verdict}
Reviewer summary: ${review.summary}
Behavior risk noted: ${review.behavior_risk}
Issues to address:
${JSON.stringify(review.issues, null, 2)}
Deliverables the reviewer marked not realised:
${JSON.stringify((review.findings_verified || []).filter(f => !f.fixed), null, 2)}

Original spec: READ ${pkg.spec_path} (and its design_ref sections in ${DESIGN_DOC}).

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
log(`Stage 2 wave: ${approved.length}/${summary.length} packages approved; net LOC ${summary.reduce((n, s) => n + (s.loc_delta || 0), 0)}`)
return { approved: approved.map(s => s.id), summary }
