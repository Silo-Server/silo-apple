# Stage 2 working set

- `../2026-08-19-stage2-design.md` — the design every package implements against (types, ownership, waves, invariants, tests, validation gate, allowed behaviour differences).
- `inventory-1-vm-control-core.md`, `inventory-2-vm-track-half.md`, `inventory-3-backend-bridge-loopback.md`, `inventory-4-tests-views-platform.md` — read-only maps of the code at `acc3004`/`20ba06b` with current line anchors (four Opus mapping agents, 2026-08-19). Specs cite these, not the 08-17 review's lines.
- `specs/spec-s2w1-*.json` — wave-1 packages (binding). `specs/spec-s2w2-*`, `-s2w3-*`, `-s2w4-*` — drafts for later waves; re-anchor (names introduced by earlier waves, line numbers) before launching.
- `specs/wave1-args.json` — the args for `.claude/workflows/player-stage2-fix.js` (mirror: `docs/cleanup/workflows/player-stage2-fix.js`); fill `baseRef` with the full SHA of the branch tip.

Run (one wave per invocation; merge approved `stage2/<id>` branches, verify, then next wave with the new tip):

```
Workflow({ scriptPath: ".claude/workflows/player-stage2-fix.js", args: <contents of specs/wave1-args.json with baseRef filled> })
```
