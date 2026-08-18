export const meta = {
  name: 'app-cleanup-survey',
  description: 'Survey silo-apple for low-quality / YAGNI code, verify each finding, and package into disjoint cleanup work packages (read-only)',
  whenToUse: 'First half of the app cleanup loop. Run this, review the packages it returns, then run app-cleanup-fix with them as args.',
  phases: [
    { title: 'Survey', detail: 'one Fable finder per app slice', model: 'fable' },
    { title: 'Verify', detail: 'one Fable skeptic per finder batch', model: 'fable' },
    { title: 'Package', detail: 'group survivors into disjoint work packages', model: 'fable' },
  ],
}

// ---------------------------------------------------------------------------
// Configuration (override via args)
// ---------------------------------------------------------------------------
const MAX_PACKAGES = (args && args.maxPackages) || 6
const MAX_FINDINGS_PER_AREA = (args && args.maxFindingsPerArea) || 12
const FINDER_MODEL = (args && args.finderModel) || 'fable'
const FINDER_EFFORT = (args && args.finderEffort) || 'medium'

const DEFAULT_AREAS = [
  {
    key: 'player-core',
    title: 'Player core (view model, session bridge, route planning, source proxy, stats, settings)',
    paths: ['iosApp/iosApp/Screens/Player/*.swift'],
    notes: 'Top-level Player files only (not subfolders). PlayerViewModel.swift is ~6.4k LOC and PlaybackSessionBridge ~1.5k; look hard for dead branches, unused published state, leftover multi-backend scaffolding from before the one-player consolidation, and settings/prefs plumbing that nothing reads.',
  },
  {
    key: 'player-avroute-subtitles',
    title: 'AVPlayer route + loopback pipeline, subtitles, protocol v3',
    paths: ['iosApp/iosApp/Screens/Player/AVPlayerRoute/', 'iosApp/iosApp/Screens/Player/Subtitles/', 'iosApp/iosApp/Screens/Player/ProtocolV3/', 'iosApp/iosApp/Screens/Player/Shared/'],
    notes: 'LoopbackSegmentWriter (~5.2k) and AVPlayerBackend (~3.8k) dominate. Look for retired paths (pre-v3 protocol shims, compatibility-player leftovers), duplicated box-parsing helpers, unused policy structs, and log/diagnostic scaffolding that never ships. The on-device video bridge (LoopbackVideoBridge) is intentionally present but dormant on the live path — read docs/tvos-player/09-video-bridge.md before calling any of it dead.',
  },
  {
    key: 'player-ui',
    title: 'Player UI on all platforms + audio player + player-related settings screens',
    paths: ['iosApp/iosApp/Screens/Player/iOS/', 'iosApp/iosApp/Screens/Player/tvOS/', 'iosApp/iosApp/Screens/Player/Sheets/', 'iosApp/iosApp/macOS/', 'iosApp/iosApp/Screens/Audio/', 'iosApp/iosApp/Screens/Settings/PlaybackSettingsView.swift', 'iosApp/iosApp/Screens/Settings/SubtitleSettingsView.swift', 'iosApp/iosApp/tvOS/Screens/Settings/TVPlaybackSettingsView.swift', 'iosApp/iosApp/tvOS/Screens/Settings/TVSubtitleSettingsView.swift'],
    notes: 'Look for controls/settings surfaced in the UI whose backing option no longer does anything, duplicated per-platform helpers that could share one implementation without a new abstraction, unused view modifiers, and dead HUD states. Read docs/tvos-focus.md before proposing anything that touches tvOS focus.',
  },
  {
    key: 'screens-shared-ui',
    title: 'Non-player screens, components, overlays, navigation, design system, theme',
    paths: ['iosApp/iosApp/Screens/', 'iosApp/iosApp/Components/', 'iosApp/iosApp/Overlays/', 'iosApp/iosApp/Navigation/', 'iosApp/iosApp/DesignSystem/', 'iosApp/iosApp/Theme/', 'iosApp/iosApp/ContentView.swift', 'iosApp/iosApp/iOSApp.swift', 'iosApp/iosApp/iOS/'],
    notes: 'EXCLUDE Screens/Player and Screens/Audio (covered by other finders). Look for unused views/components, duplicated formatting helpers, dead feature-flag branches, view models holding state nothing observes, and leftovers from removed features (e.g. account creation/admin UI was removed in #160 — check for orphaned pieces).',
  },
  {
    key: 'tvos-topshelf',
    title: 'tvOS-specific screens and Top Shelf extension',
    paths: ['iosApp/iosApp/tvOS/', 'iosApp/TopShelf/'],
    notes: 'EXCLUDE tvOS/Screens/Settings/TVPlaybackSettingsView.swift and TVSubtitleSettingsView.swift (covered by player-ui). Look for duplicated code vs. the shared/iOS equivalents that could reuse an existing shared implementation, unused focus helpers, and dead caching layers. Read docs/tvos-focus.md before proposing anything that touches focus.',
  },
  {
    key: 'infra',
    title: 'Networking, shared utilities, downloads, control/remote, pairing, notifications, startup, extensions',
    paths: ['iosApp/iosApp/Networking/', 'iosApp/iosApp/Shared/', 'iosApp/iosApp/Downloads/', 'iosApp/iosApp/Control/', 'iosApp/iosApp/Pairing/', 'iosApp/iosApp/Notifications/', 'iosApp/iosApp/Startup/', 'iosApp/iosApp/Extensions/', 'iosApp/NotificationService/', 'iosApp/DownloadsActivity/'],
    notes: 'Look for API models/fields nothing decodes into UI, unused endpoints, duplicated request helpers, stale compatibility fallbacks for server versions no longer supported, unused stores/caches, and dead notification/deep-link handlers. Do NOT propose changing wire contracts — those are owned by silo-server.',
  },
]
const AREAS = (args && args.areas) || DEFAULT_AREAS

// ---------------------------------------------------------------------------
// Schemas
// ---------------------------------------------------------------------------
const FINDING_PROPS = {
  id: { type: 'string', description: 'short slug, unique within this batch, e.g. "pvm-dead-airplay-flag"' },
  title: { type: 'string' },
  category: { type: 'string', enum: ['dead-code', 'yagni', 'duplication', 'over-abstraction', 'stale-compat', 'needless-complexity', 'misleading-comments'] },
  files: { type: 'array', items: { type: 'string' }, description: 'repo-relative paths that would be edited (include tests / project.yml if they must change)' },
  anchor: { type: 'string', description: 'primary file:line' },
  evidence: { type: 'string', description: 'how you verified it (grep commands + hit counts, call sites, docs/git-log references)' },
  proposed_change: { type: 'string', description: 'concrete edit plan an implementer can follow' },
  est_loc_delta: { type: 'integer', description: 'estimated net lines of code change; negative = removal' },
  risk: { type: 'string', enum: ['low', 'medium', 'high'] },
  confidence: { type: 'number', minimum: 0, maximum: 1 },
  platforms: { type: 'array', items: { type: 'string', enum: ['ios', 'tvos', 'macos', 'extensions'] } },
}
const FINDINGS_SCHEMA = {
  type: 'object',
  properties: {
    findings: { type: 'array', items: { type: 'object', properties: FINDING_PROPS, required: ['id', 'title', 'category', 'files', 'anchor', 'evidence', 'proposed_change', 'est_loc_delta', 'risk', 'confidence', 'platforms'] } },
    area_summary: { type: 'string', description: '3-6 sentences: overall quality of this slice and the biggest levers' },
  },
  required: ['findings', 'area_summary'],
}
const VERDICTS_SCHEMA = {
  type: 'object',
  properties: {
    verdicts: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string' },
          verdict: { type: 'string', enum: ['keep', 'adjust', 'drop'] },
          reason: { type: 'string' },
          adjusted_proposal: { type: 'string', description: 'when verdict=adjust: the corrected plan' },
          adjusted_files: { type: 'array', items: { type: 'string' } },
          adjusted_risk: { type: 'string', enum: ['low', 'medium', 'high'] },
          duplicate_of: { type: 'string', description: 'id of another finding in this batch this duplicates, if any' },
        },
        required: ['id', 'verdict', 'reason'],
      },
    },
  },
  required: ['verdicts'],
}
const PACKAGES_SCHEMA = {
  type: 'object',
  properties: {
    packages: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string', description: 'kebab-case, used as git branch suffix cleanup/<id>' },
          title: { type: 'string' },
          area: { type: 'string' },
          finding_ids: { type: 'array', items: { type: 'string' } },
          files: { type: 'array', items: { type: 'string' }, description: 'every file this package may edit; MUST be disjoint from other packages' },
          brief: { type: 'string', description: 'implementer brief: ordered steps, gotchas, what NOT to touch, how to verify' },
          est_loc_delta: { type: 'integer' },
          build_scopes: { type: 'array', items: { type: 'string', enum: ['ios', 'tvos', 'macos'] }, description: 'schemes that must build green' },
          tests: { type: 'array', items: { type: 'string' }, description: 'test files/classes most relevant to this package (may be empty)' },
          risk: { type: 'string', enum: ['low', 'medium', 'high'] },
        },
        required: ['id', 'title', 'area', 'finding_ids', 'files', 'brief', 'est_loc_delta', 'build_scopes', 'tests', 'risk'],
      },
    },
    deferred: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, reason: { type: 'string' } }, required: ['id', 'reason'] } },
  },
  required: ['packages', 'deferred'],
}

// ---------------------------------------------------------------------------
// Prompts
// ---------------------------------------------------------------------------
const REPO_CONTEXT = `
Repository: silo-apple (Swift/SwiftUI clients for iOS, tvOS, macOS). Repo root is the cwd.
- App sources: iosApp/iosApp/ ; tests: iosApp/Tests/ ; Top Shelf: iosApp/TopShelf/ ; extensions: iosApp/NotificationService/, iosApp/DownloadsActivity/
- Target membership is defined in iosApp/project.yml (XcodeGen). The Silo (iOS), SiloTV (tvOS) and SiloMac targets all compile most of iosApp/iosApp/ — a file is NOT dead just because iOS doesn't call it; check tvOS/ and macOS/ folders, #if os(...) blocks, and extension targets that pull individual files (see project.yml sources lists for SiloTVTopShelf / SiloNotificationService / SiloDownloadsActivity).
- Symbols may be referenced by string: Codable keys, UserDefaults/AppStorage keys, Notification.Name, NSUserActivity types, Info.plist entries, xcassets names, SF Symbol names, test fixture JSON. Grep those before calling something unused.
- The team is mid-way through a large player consolidation on branch player/one-player-cleanup: the app was reduced to a single AVPlayer-based player plus an on-device video bridge (intentionally present but dormant on the live path). Read docs/tvos-player/README.md and skim git log --oneline -30 so you understand what was already removed and what is intentionally kept.
- Sibling repos silo-server and silo-android are NOT checked out here; do not propose wire-contract or cross-client behavior changes.
`

const FINDER_RULES = `
WHAT COUNTS AS A FINDING (prefer things that DELETE code):
- dead-code: types/functions/properties/cases/branches with zero references (verify with grep across the WHOLE repo incl. Tests, TopShelf, extensions, project.yml, plists, Resources).
- yagni: speculative generality — options nothing sets, protocols with a single conformer that exist "for testing" but no test uses, hooks/callbacks never wired, configurable knobs with one value, feature flags permanently on/off.
- duplication: near-identical logic in 2+ places (often per-platform copies) that can collapse onto ONE existing implementation without inventing a new abstraction.
- over-abstraction: wrappers/managers/coordinators that only forward calls, layers of indirection with one caller, builder/factory ceremony for a single product.
- stale-compat: fallbacks for retired protocol versions / removed backends / old server versions / OS versions below the deployment target.
- needless-complexity: a function whose logic collapses substantially once dead branches are removed (only when the resulting delta is clearly negative; do not propose "split this big file" for its own sake).
- misleading-comments: comments/docs describing code that no longer exists (low priority; only worth listing if bundled with a code change in the same file).

DO NOT PROPOSE: formatting/style changes, renames for taste, adding new abstractions or protocols, behavior changes, anything touching server contracts, anything that changes tvOS focus behavior unless you have read docs/tvos-focus.md and can show it is a pure removal, or splitting files purely by size.

QUALITY BAR: every finding must have (a) a file:line anchor, (b) evidence you actually ran (grep counts, call-site lists), (c) a concrete edit plan, (d) an honest risk. Confidence < 0.6 findings should be omitted rather than padded. Rank by (|LOC removed| x confidence) / risk. Return at most ${MAX_FINDINGS_PER_AREA}.
`

function finderPrompt(area) {
  return `You are surveying ONE slice of the silo-apple codebase for low-quality code worth cleaning up. Read-only: do not modify any file.
${REPO_CONTEXT}
YOUR SLICE — ${area.title}
Paths: ${area.paths.join(', ')}
Slice notes: ${area.notes}

Read the slice properly (all files, not just the big ones); use grep across the whole repo to check references. Spend your effort on evidence, not prose.
${FINDER_RULES}
Return the findings via the structured output tool.`
}

function verifierPrompt(area, findings) {
  return `You are a skeptical verifier. Another agent surveyed the "${area.title}" slice of silo-apple and produced the findings below. Your job is to REFUTE each one if you can. Read-only: do not modify any file.
${REPO_CONTEXT}
For EACH finding, check:
1. Is the code really unreferenced / really redundant? Run your own greps across the whole repo (iosApp/, Tests/, TopShelf/, NotificationService/, DownloadsActivity/, project.yml, *.plist, Resources/). Remember string-based references (Codable keys, UserDefaults keys, Notification.Name, selectors, SF Symbols, fixture JSON) and platform-conditional code (#if os(tvOS)/os(macOS), files in tvOS/ and macOS/ folders, extension targets).
2. Would the proposed change alter user-visible behavior on ANY platform, or change something silo-server / silo-android depend on? If so it's not a cleanup — drop it or narrow it (adjust).
3. Is it intentionally-kept scaffolding? Check docs/tvos-player/*.md and git log -S for the symbol before deciding.
4. Is the LOC estimate and risk honest? Adjust if not.
5. Are two findings duplicates of each other? Mark duplicate_of on the weaker one and drop it.

Verdicts: keep (as written), adjust (give the corrected proposal/files/risk), drop (give the concrete reason — a grep hit, a doc reference, a behavior it would change). Default to drop when you are unsure; a wrong cleanup costs more than a missed one.

FINDINGS:
${JSON.stringify(findings, null, 2)}

Return one verdict per finding id via the structured output tool.`
}

function packagerPrompt(survivors, areaSummaries) {
  return `You are planning implementation work for a codebase cleanup in silo-apple. Below are verified findings (each already checked by a skeptic) and per-area summaries. Group them into at most ${MAX_PACKAGES} WORK PACKAGES that independent implementer agents will execute IN PARALLEL, each in its own git worktree. Read-only: do not modify any file. You may open files to sanity-check grouping.
${REPO_CONTEXT}
HARD RULES:
- Packages' \`files\` lists MUST be pairwise disjoint (no file appears in two packages). If two findings touch the same file they go in the same package or one is deferred.
- iosApp/project.yml may only appear in ONE package (or none). Same for any shared bridging header.
- Keep each package to roughly <= 800 lines of net change so one implementer can do it carefully with a full build; split large areas or defer the tail.
- Group by locality (same files / same subsystem) so the implementer holds one mental model, and order steps inside the brief so intermediate states compile.
- build_scopes: 'ios' and 'tvos' whenever any file under iosApp/iosApp/ (excluding macOS/) is touched; add 'macos' when a file under iosApp/iosApp/macOS/ is touched OR the touched files are compiled into SiloMac (most shared files are — when in doubt include macos). tvOS/ folder files are tvOS only; iOS/ folder files are iOS only.
- tests: list existing test files under iosApp/Tests/ that exercise the touched code (grep for the type names).
- Prefer to defer (not drop) medium/high-risk findings that don't fit; the deferred list is for a later round.
- The brief must be self-contained: an implementer will see ONLY the brief plus the finding objects (ids listed), not this conversation.

FINDINGS:
${JSON.stringify(survivors, null, 2)}

AREA SUMMARIES:
${JSON.stringify(areaSummaries, null, 2)}

Return packages + deferred via the structured output tool.`
}

// ---------------------------------------------------------------------------
// Phase 1+2: survey each area, then verify that area's batch (pipelined)
// ---------------------------------------------------------------------------
phase('Survey')
const areaResults = await pipeline(
  AREAS,
  area => agent(finderPrompt(area), { label: `find:${area.key}`, phase: 'Survey', schema: FINDINGS_SCHEMA, model: FINDER_MODEL, effort: FINDER_EFFORT })
    .then(r => ({ area, findings: (r && r.findings) || [], summary: r ? r.area_summary : '(finder failed)' })),
  async (res, area) => {
    if (!res) return null
    // namespace ids by area so they stay unique across batches
    res.findings.forEach(f => { f.id = `${area.key}/${f.id}`; f.area = area.key })
    if (res.findings.length === 0) return { ...res, verdicts: [] }
    const v = await agent(verifierPrompt(area, res.findings), { label: `verify:${area.key}`, phase: 'Verify', schema: VERDICTS_SCHEMA, model: FINDER_MODEL, effort: FINDER_EFFORT })
    return { ...res, verdicts: (v && v.verdicts) || [] }
  },
)

const survivors = []
const refuted = []
const areaSummaries = []
for (const res of areaResults.filter(Boolean)) {
  areaSummaries.push({ area: res.area.key, summary: res.summary, raw_findings: res.findings.length })
  const byId = new Map(res.verdicts.map(v => [v.id, v]))
  for (const f of res.findings) {
    const v = byId.get(f.id)
    if (!v) { refuted.push({ ...f, verdict: 'drop', reason: 'no verdict returned by verifier' }); continue }
    if (v.verdict === 'drop') { refuted.push({ ...f, verdict: 'drop', reason: v.reason, duplicate_of: v.duplicate_of }); continue }
    if (v.verdict === 'adjust') {
      survivors.push({ ...f, proposed_change: v.adjusted_proposal || f.proposed_change, files: (v.adjusted_files && v.adjusted_files.length) ? v.adjusted_files : f.files, risk: v.adjusted_risk || f.risk, verifier_note: v.reason })
    } else {
      survivors.push({ ...f, verifier_note: v.reason })
    }
  }
}
log(`Survey: ${survivors.length} findings survived verification, ${refuted.length} refuted, across ${areaSummaries.length} areas`)

// ---------------------------------------------------------------------------
// Phase 3: package into disjoint work packages
// ---------------------------------------------------------------------------
phase('Package')
let packages = []
let deferred = []
if (survivors.length > 0) {
  const p = await agent(packagerPrompt(survivors, areaSummaries), { label: 'package', phase: 'Package', schema: PACKAGES_SCHEMA, model: FINDER_MODEL, effort: 'high' })
  packages = (p && p.packages) || []
  deferred = (p && p.deferred) || []
}

// Enforce disjointness in code: later packages lose colliding files -> their colliding findings get deferred.
const owner = new Map()
const findingById = new Map(survivors.map(f => [f.id, f]))
for (const pkg of packages) {
  const collisions = pkg.files.filter(f => owner.has(f))
  if (collisions.length) {
    log(`Package ${pkg.id}: dropping files already owned elsewhere: ${collisions.join(', ')}`)
    const collidingSet = new Set(collisions)
    const keepIds = []
    for (const fid of pkg.finding_ids) {
      const f = findingById.get(fid)
      if (f && f.files.some(x => collidingSet.has(x))) deferred.push({ id: fid, reason: `file collision with another package (${collisions.join(', ')})` })
      else keepIds.push(fid)
    }
    pkg.finding_ids = keepIds
    pkg.files = pkg.files.filter(f => !collidingSet.has(f))
  }
  pkg.files.forEach(f => owner.set(f, pkg.id))
}
packages = packages.filter(p => p.finding_ids.length > 0)
// Attach the full finding objects so the fix workflow is self-contained.
for (const pkg of packages) pkg.findings = pkg.finding_ids.map(id => findingById.get(id)).filter(Boolean)
const packagedIds = new Set(packages.flatMap(p => p.finding_ids))
for (const f of survivors) if (!packagedIds.has(f.id) && !deferred.some(d => d.id === f.id)) deferred.push({ id: f.id, reason: 'not placed by packager' })

const stats = {
  areas: areaSummaries.length,
  raw_findings: areaSummaries.reduce((n, a) => n + a.raw_findings, 0),
  survivors: survivors.length,
  refuted: refuted.length,
  packages: packages.length,
  deferred: deferred.length,
  est_loc_delta_packaged: packages.reduce((n, p) => n + (p.est_loc_delta || 0), 0),
}
log(`Packaged ${stats.packages} packages (est ${stats.est_loc_delta_packaged} LOC), ${stats.deferred} deferred`)
return { stats, packages, deferred, refuted, areaSummaries }
