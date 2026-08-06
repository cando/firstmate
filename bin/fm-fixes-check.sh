#!/usr/bin/env bash
# Check whether the firstmate fork's local fixes have been adopted upstream.
#
# The fork (origin = cando/firstmate) carries local fix commits on top of the
# public upstream template (upstream = kunchenguid/firstmate). This script
# compares each fix's files against upstream's current version and reports
# whether the fix is still needed, superseded (upstream now has the same or a
# better change), or needs a re-verify (upstream rewrote the file).
#
# Run it after `git fetch upstream` as part of the fork-sync routine (see
# FIXES.md and data/captain.md). It is read-only: it never modifies the repo.
#
# Usage: fm-fixes-check.sh [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() { echo "usage: fm-fixes-check.sh [--help]" >&2; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 0 ] || { usage; exit 1; }

# A fix is a commit on the fork's main that is NOT in upstream's main.
# The authoritative list is the git diff, not this script's memory.
mapfile -t FIX_COMMITS < <(git -C "$FM_ROOT" log --format='%h %s' upstream/main..origin/main 2>/dev/null || true)
if [ "${#FIX_COMMITS[@]}" -eq 0 ]; then
  echo "no local fixes (upstream/main..origin/main is empty) - fork matches upstream"
  exit 0
fi

echo "local fixes on the fork (upstream/main..origin/main):"
echo "----------------------------------------------------"
for line in "${FIX_COMMITS[@]}"; do
  c=${line%% *}
  subject=${line#* }
  echo "  $c  $subject"
done
echo

# For each fix commit, compare its changed files against upstream's version.
# A file whose content now matches upstream (no diff) means the fix's change
# is present upstream -> superseded. A file that differs could be a genuine
# remaining fix OR an upstream rewrite that needs a re-verify - the grep
# heuristic tries to tell them apart, but the human check in FIXES.md is
# authoritative.
echo "per-fix adoption check (file diffs vs upstream/main):"
echo "------------------------------------------------------"
for line in "${FIX_COMMITS[@]}"; do
  c=${line%% *}
  subject=${line#* }
  echo "  $c  $subject"
  # Files the fix commit touched (added/modified/deleted).
  files=$(git -C "$FM_ROOT" show --format='' --name-only "$c" 2>/dev/null | grep -v '^$' || true)
  [ -n "$files" ] || { echo "    (no files - nothing to compare)"; continue; }
  superseded=1
  for f in $files; do
    # Only compare files that still exist in both sides (a fix that added a
    # file upstream still lacks is clearly still needed).
    if ! git -C "$FM_ROOT" cat-file -e "upstream/main:$f" 2>/dev/null; then
      echo "    $f: upstream does not have this file -> fix still needed"
      superseded=0
      continue
    fi
    if git -C "$FM_ROOT" cat-file -e "$c:$f" 2>/dev/null; then
      # Both sides have the file: identical blob means upstream adopted it.
      up=$(git -C "$FM_ROOT" rev-parse "upstream/main:$f" 2>/dev/null || echo none)
      fix=$(git -C "$FM_ROOT" rev-parse "$c:$f" 2>/dev/null || echo none)
      if [ "$up" = "$fix" ]; then
        echo "    $f: IDENTICAL to upstream -> superseded (upstream adopted it)"
        continue
      fi
      # Differ: either a remaining fix or an upstream rewrite. Show the
      # diffstat so the human (or FIXES.md) can judge.
      echo "    $f: differs from upstream (see diffstat below)"
      git -C "$FM_ROOT" diff --stat "upstream/main:$f" "$c:$f" 2>/dev/null | sed 's/^/      /' || true
      superseded=0
    else
      echo "    $f: removed by the fix -> differs from upstream (re-verify)"
      superseded=0
    fi
  done
  if [ "$superseded" -eq 1 ]; then
    echo "    => ALL changed files identical to upstream: superseded"
  else
    echo "    => still needed or needs re-verify (see FIXES.md)"
  fi
  echo
done

echo "Done. Update FIXES.md statuses accordingly; a superseded fix can be"
echo "dropped on the next rebase (it is redundant once upstream has it)."
