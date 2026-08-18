export const meta = {
  name: 'app-cleanup-survey-v2',
  description: 'DRY / KISS / YAGNI survey of silo-apple: Sonnet mechanical inventory → Opus finders → Opus skeptics → disjoint work packages (read-only)',
  whenToUse: 'Second-generation survey for the single-PR cleanup program on player/architecture-remediation. Review the packages it returns, then run app-cleanup-fix with them as args.',
  phases: [
    { title: 'Inventory', detail: 'one Sonnet scanner per slice: duplicates, twins, giants, orphans', model: 'sonnet' },
    { title: 'Survey', detail: 'one Opus finder per slice, seeded with the inventory', model: 'opus' },
    { title: 'Verify', detail: 'one Opus skeptic per finder batch', model: 'opus' },
    { title: 'Package', detail: 'group survivors into file-disjoint work packages', model: 'opus' },
  ],
}

// ---------------------------------------------------------------------------
// Configuration (override via args)
// ---------------------------------------------------------------------------
const MAX_PACKAGES = (args && args.maxPackages) || 8
const MAX_FINDINGS_PER_AREA = (args && args.maxFindingsPerArea) || 15
const SCANNER_MODEL = (args && args.scannerModel) || 'sonnet'
const FINDER_MODEL = (args && args.finderModel) || 'opus'
const VERIFIER_MODEL = (args && args.verifierModel) || 'opus'
const PACKAGER_MODEL = (args && args.packagerModel) || 'opus'
const FINDER_EFFORT = (args && args.finderEffort) || 'high'
const BASE_SHA = (args && args.baseSha) || 'HEAD'

const DEFAULT_AREAS = [
  {
    key: 'player-core',
    title: 'Player core: view model, session bridge, route planner, source proxy/origin stream, stats, settings, realtime client',
    paths: ['iosApp/iosApp/Screens/Player/*.swift'],
    notes: `Top-level Player files only (not subfolders). PlayerViewModel.swift is ~8k raw lines and hosts several concerns behind // MARK: fences (route-planning glue, subtitle sink adapter, HUD/entry points, stats enrichment, task registry, live-subtitle diagnostics). The architecture review (docs/cleanup/player-review/2026-08-17-architecture-review.md §4, §5 "Accidental") already names concrete accidental complexity that is NOT gated on the control-plane rewrite: LoadRequest.copyForRecovery reconstructed at four sites; a ~35-field hand reset in teardownMediaPipeline; six mirrored session-id stores; ~30 planner trace tokens consumed by one log line; four capability surfaces (AppleDecodeCapabilities / ApplePlaybackRouteCapabilities / ApplePlaybackV3Capabilities / plan.claims) with overlapping content; quality represented four ways; six UserDefaults debug forks; 14 unregistered Task {} beside a hand-maintained task registry; PlaybackSourceProxy/OriginStream/ChunkFetcher triplicating buffering accounting. Look for those and for anything else of the same kind. DO NOT propose the Stage 2 control-plane extraction (reducer/session actor/RecoveryPolicy/PlaybackBackend protocol) — it is a separate gated program; propose only local DRY/KISS collapses whose behavior is provably identical.`,
  },
  {
    key: 'player-avroute',
    title: 'AVPlayer route + loopback pipeline (backend, writer, store, server, cutter, box surgery) + protocol v3 + shared',
    paths: ['iosApp/iosApp/Screens/Player/AVPlayerRoute/', 'iosApp/iosApp/Screens/Player/ProtocolV3/', 'iosApp/iosApp/Screens/Player/Shared/'],
    notes: `LoopbackSegmentWriter (~6.8k raw) and AVPlayerBackend (~4.6k raw) dominate. The on-device video bridge tier and .passthroughAV1 were DELETED in remediation round 2 — check for residue (parameters, plumbing, comments, planner arms, tests) that survived the deletion. Review §5 names: three "+delay_moov" workarounds and historical patch layers each naming one incident; buffering policy triplicated across proxy/store/writer; the "[CMP-MEM] temporary" block in the backend; SILO_KEEP_DV_HLS threading; diagnostics probes in hot paths (the throughput probe is intentionally kept — see backlog §3 — but its 11 timed/untimed branch pairs could collapse onto one measure(into:) helper); transcodeEC3/AC3 encoder arms with no producer; recovery-ladder constants/timers duplicated across six ladders (consolidating constants is fine; merging the ladders is Stage 2 and OFF LIMITS). Do NOT propose retiring the plan-less EVENT fallback (backlog §2.5 — a product decision) or touching ISOBoxSurgery / Cutter / segment plan logic beyond dedup of helpers.`,
  },
  {
    key: 'player-subtitles',
    title: 'Subtitle pipeline: session, renderer, styling, acquisition UIs, live-AI',
    paths: ['iosApp/iosApp/Screens/Player/Subtitles/'],
    notes: `Review §5 flags: four parallel slot collections in SubtitleSession; three acquisition UIs (~1.4k lines) that likely share most logic; VTT/SRT→ASS conversion + SubtitleStylingOverride (~1.1k) — keeping the feature is a product decision (P8), but internal duplication inside it is fair game; live-AI websocket stack (~2.1k) — same (P7); two forced-subtitle resolvers that disagree (PlayerViewModel vs PlaybackPrefsResolver — the PVM copy lives in player-core, so only report it if the fix is in this slice, else note it for the packager). Look for duplicated index-space translation helpers, duplicated language-label formatting, and view-model state nothing observes.`,
  },
  {
    key: 'player-ui',
    title: 'Player UI on all platforms, audio/audiobook player, player-related settings screens',
    paths: ['iosApp/iosApp/Screens/Player/iOS/', 'iosApp/iosApp/Screens/Player/tvOS/', 'iosApp/iosApp/Screens/Player/Sheets/', 'iosApp/iosApp/macOS/', 'iosApp/iosApp/Screens/Audio/', 'iosApp/iosApp/Screens/Settings/PlaybackSettingsView.swift', 'iosApp/iosApp/Screens/Settings/SubtitleSettingsView.swift', 'iosApp/iosApp/tvOS/Screens/Settings/TVPlaybackSettingsView.swift', 'iosApp/iosApp/tvOS/Screens/Settings/TVSubtitleSettingsView.swift'],
    notes: `Look for per-platform twins (iOS vs tvOS vs macOS overlays, HUDs, sheets, settings rows) that duplicate models/formatting/state logic — share the model and formatting, keep focus ownership per platform (docs/tvos-focus.md). The audiobook engine (Screens/Audio) is a second V3 client with its own capability snapshot (review §4.12) — look for logic it duplicates from the video player that could reuse the existing shared implementation. Controls whose backing option no longer does anything after the one-player consolidation are YAGNI.`,
  },
  {
    key: 'screens-shared-ui',
    title: 'Non-player screens, components, overlays, navigation, design system, theme, app entry',
    paths: ['iosApp/iosApp/Screens/', 'iosApp/iosApp/Components/', 'iosApp/iosApp/Overlays/', 'iosApp/iosApp/Navigation/', 'iosApp/iosApp/DesignSystem/', 'iosApp/iosApp/Theme/', 'iosApp/iosApp/ContentView.swift', 'iosApp/iosApp/iOSApp.swift', 'iosApp/iosApp/iOS/'],
    notes: `EXCLUDE Screens/Player and Screens/Audio (other finders). ~30k lines across Auth, Browse, Calendar, Collections, Detail, Home, Onboarding, People, Personal, Profiles, Recommendations, Requests, Search, Servers, Settings. Look for: duplicated loaders/view-model boilerplate across screens (same fetch→state→error pattern hand-rolled N times where ONE existing helper already exists), duplicated formatting helpers (runtime/date/rating/badge — note backlog 1.18: the 3 divergent runtime formats are a product decision, do not unify their OUTPUT), view models holding state nothing observes, over-general components with a single caller, dead feature-flag branches, leftovers from removed features (account creation/admin UI removed in #160). Prefer collapsing onto an existing implementation over inventing a new one.`,
  },
  {
    key: 'tvos-topshelf',
    title: 'tvOS-specific screens, caching, navigation, components, and the Top Shelf extension',
    paths: ['iosApp/iosApp/tvOS/', 'iosApp/TopShelf/'],
    notes: `EXCLUDE tvOS/Screens/Settings/TVPlaybackSettingsView.swift and TVSubtitleSettingsView.swift (player-ui). Backlog §4.3 names the pattern: copy an iOS type into tvOS/ and let it drift. Candidates not yet audited: tvOS/Screens/Detail/* vs Screens/Detail/* (episode rails, cast rails, similar rails, hero, facts), tvOS/Screens/Libraries vs Screens/Browse, tvOS/Caching vs Networking/ResponseCache + ItemDetailCache, tvOS/Components vs Components. Share models/formatting/loaders; keep focus ownership per platform (docs/tvos-focus.md — read it before proposing anything that touches focus). Round 1 already folded TVSettingsViewModel, TVHeroMetadata, TVDetailFactsSection's model, TVItemDetailView's loaders, WatchlistView, eight focus helpers; the cleanup tail shared similar-item loading and episode formatting — check what is left.`,
  },
  {
    key: 'infra',
    title: 'Networking, shared utilities, downloads, control/remote, pairing, notifications, startup, extensions, app extensions',
    paths: ['iosApp/iosApp/Networking/', 'iosApp/iosApp/Shared/', 'iosApp/iosApp/Downloads/', 'iosApp/iosApp/Control/', 'iosApp/iosApp/Pairing/', 'iosApp/iosApp/Notifications/', 'iosApp/iosApp/Startup/', 'iosApp/iosApp/Extensions/', 'iosApp/NotificationService/', 'iosApp/DownloadsActivity/'],
    notes: `Look for: API models/fields nothing decodes into UI, duplicated request/decoding helpers, stale compatibility fallbacks for server versions no longer supported (OverlayPrefsStore's card_overlays fallback is intentionally kept — backlog §2.4), unused stores/caches (ResponseCache is "intentionally dumb" — survey which keys still have readers, backlog §4.5), duplicated keychain/defaults access patterns, dead notification/deep-link handlers, and Downloads/Pairing/Diagnostics member-level dead code the round-1 survey said was "below the cut" (backlog §4.8). Do NOT propose changing wire contracts (silo-server owns them) or touching the LegacyBrandKeys migration sources / SiloControl v1 peer compat / onboarding legacy-suppression record (backlog §3).`,
  },
  {
    key: 'tests',
    title: 'XCTest suite',
    paths: ['iosApp/Tests/'],
    notes: `~46k lines. Look for: tests that exercise code deleted in the consolidation/remediation (they cannot compile — so instead look for tests kept alive by stubs/shims that exist ONLY to keep an obsolete test compiling); duplicated fixture builders / fake servers / helper extensions re-implemented per test file where a shared helper already exists in the suite; characterization tests that pin behavior of a path that no longer exists online AND offline; copy-pasted test bodies differing only in a literal that could be one parameterized test (only when the collapse is obviously safe). Do NOT weaken coverage of live behavior; do NOT touch the 14 documented environment failures (ProfileLaunch*, SettingValuesAPITests, UICustomizationPreferencesTests) except to note them.`,
  },
]
const AREAS = (args && args.areas) || DEFAULT_AREAS

// ---------------------------------------------------------------------------
// Schemas
// ---------------------------------------------------------------------------
const INVENTORY_SCHEMA = {
  type: 'object',
  properties: {
    candidates: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          kind: { type: 'string', enum: ['duplicate-symbol', 'platform-twin', 'giant-function', 'orphan-symbol', 'repeated-pattern', 'debug-fork', 'stale-comment'] },
          anchor: { type: 'string', description: 'file:line (or file:line ↔ file:line for pairs)' },
          note: { type: 'string', description: 'one line: what was found and the grep/measure that found it' },
        },
        required: ['kind', 'anchor', 'note'],
      },
    },
    slice_metrics: { type: 'string', description: 'file count, raw line count, top-5 largest files, top-10 largest functions with line spans' },
  },
  required: ['candidates', 'slice_metrics'],
}
const FINDING_PROPS = {
  id: { type: 'string', description: 'short slug, unique within this batch, e.g. "pvm-copy-for-recovery-x4"' },
  title: { type: 'string' },
  category: { type: 'string', enum: ['dead-code', 'yagni', 'dry-duplication', 'over-abstraction', 'stale-compat', 'kiss-complexity', 'deletion-residue', 'misleading-comments'] },
  files: { type: 'array', items: { type: 'string' }, description: 'repo-relative paths that would be edited (include tests / project.yml if they must change)' },
  anchor: { type: 'string', description: 'primary file:line' },
  evidence: { type: 'string', description: 'how you verified it (grep commands + hit counts, call sites, docs/git-log references, side-by-side excerpt for duplicates)' },
  proposed_change: { type: 'string', description: 'concrete edit plan an implementer can follow, incl. the ONE implementation everything collapses onto' },
  behavior_argument: { type: 'string', description: 'why user-visible behavior on every platform is unchanged (or, for kiss-complexity, what invariant proves equivalence)' },
  est_loc_delta: { type: 'integer', description: 'estimated net lines of code change; negative = removal' },
  risk: { type: 'string', enum: ['low', 'medium', 'high'] },
  confidence: { type: 'number', minimum: 0, maximum: 1 },
  platforms: { type: 'array', items: { type: 'string', enum: ['ios', 'tvos', 'macos', 'extensions'] } },
}
const FINDINGS_SCHEMA = {
  type: 'object',
  properties: {
    findings: { type: 'array', items: { type: 'object', properties: FINDING_PROPS, required: ['id', 'title', 'category', 'files', 'anchor', 'evidence', 'proposed_change', 'behavior_argument', 'est_loc_delta', 'risk', 'confidence', 'platforms'] } },
    area_summary: { type: 'string', description: '3-6 sentences: overall quality of this slice, the biggest DRY/KISS/YAGNI levers, and what you deliberately left alone and why' },
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
          effort: { type: 'string', enum: ['medium', 'high'], description: 'implementer+reviewer effort; high for wide or refactor-shaped packages' },
        },
        required: ['id', 'title', 'area', 'finding_ids', 'files', 'brief', 'est_loc_delta', 'build_scopes', 'tests', 'risk', 'effort'],
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
Repository: silo-apple (Swift/SwiftUI clients for iOS, tvOS, macOS). Repo root is the cwd. Line references are against ${BASE_SHA} (branch player/architecture-remediation).
- App sources: iosApp/iosApp/ ; tests: iosApp/Tests/ ; Top Shelf: iosApp/TopShelf/ ; extensions: iosApp/NotificationService/, iosApp/DownloadsActivity/
- Target membership is defined in iosApp/project.yml (XcodeGen). The Silo (iOS), SiloTV (tvOS) and SiloMac targets all compile most of iosApp/iosApp/ — a symbol is NOT dead just because iOS doesn't call it; check tvOS/ and macOS/ folders, #if os(...) blocks, and extension targets that pull individual files (see project.yml sources lists for SiloTVTopShelf / SiloNotificationService / SiloDownloadsActivity).
- Symbols may be referenced by string: Codable keys, UserDefaults/AppStorage keys, Notification.Name, NSUserActivity types, Info.plist entries, xcassets names, SF Symbol names, test fixture JSON. Grep those before calling something unused.
- PROGRAM CONTEXT — read these first, they are the ground truth for what was already done and what is deliberately kept:
  * docs/cleanup/app-cleanup-backlog.md — §0 round table, §3 "intentionally kept — don't re-flag", §4 "areas worth a closer look", §5 lessons (three times a brief's premise was wrong and the implementers were right to push back).
  * docs/cleanup/player-review/2026-08-17-architecture-review.md — §4 trouble spots, §5 essential vs accidental complexity, §9 staged plan, §10 product decisions. Stage 2 (control-plane extraction: reducer, session actor, RecoveryPolicy, PlaybackBackend protocol) and Stage 3 (route-matrix narrowing) are GATED and OUT OF SCOPE for this survey; product decisions P1–P13 are open and OUT OF SCOPE.
  * git log --oneline -60 — the one-player consolidation, four cleanup rounds, remediation rounds 1–2b, brand migration and a cleanup tail have all landed on this branch. The FFmpeg/VideoToolbox backend, the on-device video bridge tier, .passthroughAV1, the EVENT serving mode kill-switch, the ContinuumAPI string dispatcher and the legacy quality helpers are GONE — look for residue of those deletions rather than re-proposing them.
- Sibling repos silo-server and silo-android are NOT checked out here; do not propose wire-contract or cross-client behavior changes.
- The owner's principles for this program: DRY, YAGNI, KISS. Streamline and simplify; remove anything unnecessary; keep it maintainable long-term. Behavior must stay identical on every platform.
`

const FINDER_RULES = `
WHAT COUNTS AS A FINDING (rank by how much simpler the code gets per unit of risk):
- dry-duplication: the same logic in 2+ places (per-platform twins, per-screen copies, per-ladder constants, hand-rolled loaders) that can collapse onto ONE implementation. Prefer an EXISTING implementation as the survivor. Introducing a small shared helper/extension is acceptable ONLY when it replaces >= 2 near-identical copies, the net LOC is clearly negative, and it adds no protocol/manager/coordinator layer.
- kiss-complexity: logic that is materially simpler when rewritten with identical behavior — nested optionals/flags that encode one state, N-way switches that reduce to a table, repeated guard sequences, functions whose branches collapse once dead arms are removed. Give the invariant that proves equivalence. Not "split this file by size".
- yagni: speculative generality — options nothing sets, protocols with one conformer that no test uses, callbacks never wired, knobs with one value, feature flags permanently on/off, debug forks nobody flips, layered indirection with one caller.
- over-abstraction: wrappers/managers/coordinators that only forward calls; builder/factory ceremony for one product.
- dead-code: zero references across the WHOLE repo (incl. Tests, TopShelf, extensions, project.yml, plists, Resources, string-keyed uses).
- deletion-residue: parameters, plumbing, enum cases, comments, planner arms, fixtures or tests that only made sense before something already deleted (video bridge, passthroughAV1, EVENT kill-switch, CompatibilityPlayer, string dispatcher, legacy quality helpers, continuum brand).
- stale-compat: fallbacks for retired protocol versions / removed backends / OS versions below the deployment target.
- misleading-comments: comments describing code that no longer exists — list only when bundled with a code change in the same file.

DO NOT PROPOSE: formatting/style changes; renames for taste; new protocols/abstractions/"managers"; behavior changes; anything touching server contracts; anything that changes tvOS focus behavior unless you have read docs/tvos-focus.md and can show it is a pure removal or a pure model/formatting share; splitting files purely by size; anything listed in backlog §3 or gated in the review (§9 Stage 2/3, §10 P1–P13); anything the backlog says is a product decision (1.18 runtime formats, 2.4, 2.5).

QUALITY BAR: every finding must have (a) a file:line anchor, (b) evidence you actually ran (grep counts, call-site lists, side-by-side excerpt for duplicates), (c) a concrete edit plan naming the surviving implementation, (d) a behavior_argument, (e) an honest risk. Confidence < 0.6 findings should be omitted rather than padded. Return at most ${MAX_FINDINGS_PER_AREA}, best first. Fewer, well-evidenced findings beat a padded list — the implementers in this program push back on weak briefs and have been right to.
`

function scannerPrompt(area) {
  return `You are producing a MECHANICAL inventory of one slice of the silo-apple codebase to seed a later, judgment-heavy review. Read-only: do not modify any file. Do not evaluate or recommend — just measure and list, with evidence.
${REPO_CONTEXT}
YOUR SLICE — ${area.title}
Paths: ${area.paths.join(', ')}

Produce, using grep/awk/wc/sort (not by reading every file end to end):
1. duplicate-symbol: functions/computed properties/types whose NAME appears defined in 2+ files anywhere in iosApp/ (grep -rn "func <name>(" etc.). For each, list both anchors and whether the bodies look near-identical (diff a few lines). Focus on names defined inside this slice; the twin may live outside it.
2. platform-twin: files in this slice with a same-stem sibling under a different platform folder (e.g. Screens/Detail/X.swift ↔ tvOS/Screens/Detail/TVX.swift, iOS/ ↔ tvOS/ ↔ macOS/), or two files whose top-level type names differ only by a platform prefix.
3. giant-function: the 10 longest function bodies in the slice (approximate by scanning "func " lines and brace depth or blank-line gaps; give file:startLine-endLine and length).
4. orphan-symbol: top-level types/functions/properties defined in the slice whose name has exactly ONE grep hit in the whole repo (its definition) or whose only other hits are in comments. Also enum cases never constructed. List up to 25 with the grep command used.
5. repeated-pattern: a code idiom repeated >= 4 times in the slice (e.g. the same guard-let/generation-check preamble, the same Task { await MainActor.run { … } } shape, the same do/catch → state assignment, the same "if #available" block, hand-rolled loading-state enums). Give one anchor per occurrence group and the count.
6. debug-fork: UserDefaults.standard.bool/string reads, ProcessInfo environment reads, #if DEBUG blocks, and log-only branches; list key names and anchors.
7. stale-comment: comments mentioning symbols that no longer exist (grep the named symbol; zero hits = stale). Names to try: CompatibilityPlayer, PlayerCore, LoopbackVideoBridge, passthroughAV1, LoopbackServingMode, servingMode, ContinuumAPI, continuum, TrackSelectionSheet, transcode/start, video_bridge.
Also report slice_metrics. Be exhaustive but terse — one line per candidate. Return via the structured output tool.`
}

function finderPrompt(area, inventory) {
  return `You are surveying ONE slice of the silo-apple codebase for code that violates DRY / KISS / YAGNI and can be simplified with identical behavior. Read-only: do not modify any file.
${REPO_CONTEXT}
YOUR SLICE — ${area.title}
Paths: ${area.paths.join(', ')}
Slice notes: ${area.notes}

A mechanical scanner already produced this inventory of leads for your slice. Treat every line as a HYPOTHESIS to confirm or refute by reading the code — many will be false positives (name collisions, intentional platform splits, string-keyed references), and the best findings often are not on this list at all.
INVENTORY:
${JSON.stringify(inventory, null, 2)}

Read the slice properly (all files, not just the big ones); use grep across the whole repo to check references. Spend your effort on evidence, not prose. When two things look duplicated, actually diff them and say which one survives and why.
${FINDER_RULES}
Return the findings via the structured output tool.`
}

function verifierPrompt(area, findings) {
  return `You are a skeptical verifier. Another agent surveyed the "${area.title}" slice of silo-apple for DRY/KISS/YAGNI violations and produced the findings below. Your job is to REFUTE each one if you can. Read-only: do not modify any file.
${REPO_CONTEXT}
For EACH finding, check:
1. Is the code really unreferenced / really redundant / really equivalent? Run your own greps across the whole repo (iosApp/, Tests/, TopShelf/, NotificationService/, DownloadsActivity/, project.yml, *.plist, Resources/). Remember string-based references and platform-conditional code (#if os(tvOS)/os(macOS), files in tvOS/ and macOS/ folders, extension targets). For duplicates: diff the two bodies yourself — "similar" is not "identical"; a differing default, ordering, threading (MainActor vs not), or error path makes the collapse a behavior change unless the proposal handles it explicitly.
2. Would the proposed change alter user-visible behavior on ANY platform, tvOS focus, or anything silo-server / silo-android depend on? If so it's not a cleanup — drop it or narrow it (adjust).
3. Is it intentionally kept? Check docs/cleanup/app-cleanup-backlog.md §3, the review's §9 Stage 2/3 gates and §10 product decisions, docs/tvos-player/*.md, and git log -S for the symbol before deciding.
4. Does the proposal introduce a new abstraction layer that is not clearly a net simplification? Downgrade or drop.
5. Is the LOC estimate, risk and behavior_argument honest? Adjust if not.
6. Are two findings duplicates of each other? Mark duplicate_of on the weaker one and drop it.

Verdicts: keep (as written), adjust (give the corrected proposal/files/risk), drop (give the concrete reason — a grep hit, a doc reference, a behavior it would change, a gate). Default to drop when you are unsure; a wrong cleanup costs more than a missed one.

FINDINGS:
${JSON.stringify(findings, null, 2)}

Return one verdict per finding id via the structured output tool.`
}

function packagerPrompt(survivors, areaSummaries) {
  return `You are planning implementation work for a DRY/KISS/YAGNI cleanup in silo-apple. Below are verified findings (each already checked by a skeptic) and per-area summaries. Group them into at most ${MAX_PACKAGES} WORK PACKAGES that independent implementer agents will execute IN PARALLEL, each in its own git worktree, all landing on the same single PR. Read-only: do not modify any file. You may open files to sanity-check grouping.
${REPO_CONTEXT}
HARD RULES:
- Packages' \`files\` lists MUST be pairwise disjoint (no file appears in two packages). If two findings touch the same file they go in the same package or one is deferred.
- iosApp/project.yml may only appear in ONE package (or none). Same for any shared bridging header.
- Keep each package to roughly <= 800 lines of net change so one implementer can do it carefully with a full build; split large areas or defer the tail.
- Split mechanical deletions/residue from refactor-shaped DRY/KISS collapses when they would otherwise share a file only incidentally — but never violate disjointness to do so; when in doubt merge into one package and mark effort: high.
- Group by locality (same files / same subsystem) so the implementer holds one mental model, and order steps inside the brief so intermediate states compile.
- build_scopes: 'ios' and 'tvos' whenever any file under iosApp/iosApp/ (excluding macOS/) is touched; add 'macos' when a file under iosApp/iosApp/macOS/ is touched OR the touched files are compiled into SiloMac (most shared files are — when in doubt include macos). tvOS/ folder files are tvOS only; iOS/ folder files are iOS only.
- tests: list existing test files under iosApp/Tests/ that exercise the touched code (grep for the type names).
- Prefer to defer (not drop) medium/high-risk findings that don't fit; the deferred list is for a later round.
- The brief must be self-contained: an implementer will see ONLY the brief plus the finding objects (ids listed), not this conversation. Tell it which implementation survives for every collapse, what invariant to preserve, and to push back (return "premise wrong" with evidence) rather than force a change whose premise it can refute.

FINDINGS:
${JSON.stringify(survivors, null, 2)}

AREA SUMMARIES:
${JSON.stringify(areaSummaries, null, 2)}

Return packages + deferred via the structured output tool.`
}

// ---------------------------------------------------------------------------
// Phases 1–3 pipelined per area: inventory → find → verify
// ---------------------------------------------------------------------------
phase('Inventory')
const areaResults = await pipeline(
  AREAS,
  area => agent(scannerPrompt(area), { label: `scan:${area.key}`, phase: 'Inventory', schema: INVENTORY_SCHEMA, model: SCANNER_MODEL, effort: 'medium' })
    .then(inv => ({ area, inventory: inv || { candidates: [], slice_metrics: '(scanner failed)' } })),
  async (res, area) => {
    if (!res) return null
    const r = await agent(finderPrompt(area, res.inventory), { label: `find:${area.key}`, phase: 'Survey', schema: FINDINGS_SCHEMA, model: FINDER_MODEL, effort: FINDER_EFFORT })
    return { ...res, findings: (r && r.findings) || [], summary: r ? r.area_summary : '(finder failed)' }
  },
  async (res, area) => {
    if (!res) return null
    res.findings.forEach(f => { f.id = `${area.key}/${f.id}`; f.area = area.key })
    if (res.findings.length === 0) return { ...res, verdicts: [] }
    const v = await agent(verifierPrompt(area, res.findings), { label: `verify:${area.key}`, phase: 'Verify', schema: VERDICTS_SCHEMA, model: VERIFIER_MODEL, effort: 'medium' })
    return { ...res, verdicts: (v && v.verdicts) || [] }
  },
)

const survivors = []
const refuted = []
const areaSummaries = []
const inventories = []
for (const res of areaResults.filter(Boolean)) {
  areaSummaries.push({ area: res.area.key, summary: res.summary, raw_findings: res.findings.length })
  inventories.push({ area: res.area.key, slice_metrics: res.inventory.slice_metrics, candidate_count: res.inventory.candidates.length })
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
// Phase 4: package into disjoint work packages
// ---------------------------------------------------------------------------
phase('Package')
let packages = []
let deferred = []
if (survivors.length > 0) {
  const p = await agent(packagerPrompt(survivors, areaSummaries), { label: 'package', phase: 'Package', schema: PACKAGES_SCHEMA, model: PACKAGER_MODEL, effort: 'high' })
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
return { stats, packages, deferred, refuted, areaSummaries, inventories }
