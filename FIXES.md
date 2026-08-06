# Local fixes on the firstmate fork

This file is the single source of truth for the local fix commits the
captain's fork (`cando/firstmate`) carries on top of the public upstream
template (`kunchenguid/firstmate`). The update routine rebases these onto each
new upstream release, so they stay replayable and independently verifiable.

The authoritative list of local fixes is always the git diff:

```sh
git log --oneline upstream/main..origin/main
```

Each entry below records the commit, the files it touches, and why it exists.
The Status column is updated by `bin/fm-fixes-check.sh` after every fork sync.

## How to check whether a fix was adopted upstream

After `git fetch upstream`, for each fix compare its files against upstream:

```sh
git diff upstream/main -- <fix's files>
git log upstream/main --oneline --grep="<fix's topic>"
```

- If upstream's version of the file already contains the fix's logic (or a
  better equivalent), mark the fix superseded and drop it on the next rebase.
- If upstream rewrote the file and the fix no longer applies, re-verify the
  intent, then re-apply or drop.
- Otherwise keep it; the status stays `needed`.

## Fixes

| Commit | Fix | Files | Why it exists | Status |
|---|---|---|---|---|
| `67faa2e` | pi-watch away-mode skip | `.pi/extensions/fm-primary-pi-watch.ts` | Away-mode daemon owns wake triage while `state/.afk` exists; upstream has no afk handling | needed |
| `5fb739b` | fm-backup.sh | `bin/fm-backup.sh` | On-demand private state backup to `cando/firstmate-state`; a feature upstream lacks | needed |
| `59b12b7` | herdr primary-pane session guard | `.pi/extensions/fm-herdr-session-guard.ts`, `.pi/extensions/lib/fm-operational-input.ts`, `bin/fm-operational-input.sh`, `bin/fm-test-run.sh`, `docs/herdr-backend.md`, `docs/verification/runtime-backends.md`, `tests/fm-herdr-session-guard.test.sh`, `tests/fm-operational-input.test.sh` | Herdr 0.8.0 integration can clear the primary pane's agent_session binding (stuck idle spinner); guard re-anchors it | needed |
| `cf1877e` | watcher stale/turn-end absorb | `bin/fm-watch.sh`, `bin/fm-classify-lib.sh`, `bin/fm-wake-lib.sh`, `tests/fm-watch-triage.test.sh`, `tests/fm-wake-queue.test.sh` | Stop stale pings for done/torn-down tasks and absorb benign turn-end wakes (captain's wake-flood report) | needed |
| `1defd82` | watcher blocked-wake dedupe | `bin/fm-classify-lib.sh`, `bin/fm-push-transition-lib.sh`, `bin/fm-watch.sh`, `tests/fm-watch-triage.test.sh` | A blocked task's turn-ends surface once, then are deduped against the surfaced marker (captain's wake-flood report) | needed |
