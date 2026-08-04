#!/usr/bin/env bash
# fm-backup.sh - push firstmate's durable private state to the private backup repo.
#
# Backs up (captain-private, never public):
#   - firstmate/data/   (backlog, captain preferences, learnings, decisions, briefs, reports)
#   - firstmate/config/ (backend, budgets, dispatch profiles)
#   - slack-sidekick/   (~/.config/slack-sidekick: the bot's archive, drafts, brain)
#
# The target repo is private (cando/firstmate-state) and this script is invoked
# by firstmate when it decides a snapshot is warranted (after milestones, before
# risky operations, or when the backlog has meaningful new state). No timer, no
# cron: the captain chose on-demand pushes over scheduled jobs.
#
# Never pushed by design: state/ (volatile runtime), .env and any token/secret
# files, and the pi provider config (which holds API keys).
#
# Usage: fm-backup.sh [--dry-run]
#   --dry-run   sync files and show what would be committed, but do not commit or push.
# Env:
#   FM_BACKUP_ROOT   backup clone location (default $HOME/firstmate-state)
set -euo pipefail

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
BACKUP_ROOT="${FM_BACKUP_ROOT:-$HOME/firstmate-state}"
SK_DIR="$HOME/.config/slack-sidekick"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

if [ ! -d "$BACKUP_ROOT/.git" ]; then
  echo "error: backup repo missing at $BACKUP_ROOT (clone https://github.com/cando/firstmate-state)" >&2
  exit 1
fi

mkdir -p "$BACKUP_ROOT/firstmate"
rsync -a --delete "$FM_HOME/data/" "$BACKUP_ROOT/firstmate/data/"
rsync -a --delete "$FM_HOME/config/" "$BACKUP_ROOT/firstmate/config/"
if [ -d "$SK_DIR" ]; then
  mkdir -p "$BACKUP_ROOT/slack-sidekick"
  rsync -a --delete "$SK_DIR/" "$BACKUP_ROOT/slack-sidekick/"
fi
# Self-contained backup: the script itself lives in the backup too, so the
# routine survives even if this machine's firstmate checkout is lost.
cp "$FM_ROOT/bin/fm-backup.sh" "$BACKUP_ROOT/fm-backup.sh"

if git -C "$BACKUP_ROOT" diff --quiet && git -C "$BACKUP_ROOT" diff --cached --quiet; then
  echo "no changes to back up"
  exit 0
fi

git -C "$BACKUP_ROOT" add -A
if [ -z "$(git -C "$BACKUP_ROOT" status --porcelain)" ]; then
  echo "no changes to back up"
  exit 0
fi

if [ "$DRY" -eq 1 ]; then
  git -C "$BACKUP_ROOT" status --short | head -20
  echo "dry-run: would commit and push $(git -C "$BACKUP_ROOT" diff --cached --stat | tail -1 | awk '{print $1}') files"
  exit 0
fi

git -C "$BACKUP_ROOT" -c user.name=cando -c user.email=cando@users.noreply.github.com \
  commit -m "state snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null
git -C "$BACKUP_ROOT" push origin main 2>&1 | tail -1
echo "backed up: $(git -C "$BACKUP_ROOT" log --oneline -1)"
