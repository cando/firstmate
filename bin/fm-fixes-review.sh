#!/usr/bin/env bash
# Build an evidence bundle for the LLM (firstmate) to review whether each
# local fix's INTENT has landed upstream in any form.
#
# The mechanical fm-fixes-check.sh only detects identical files. The real
# question is semantic: did upstream solve the same PROBLEM with different
# code? That judgment needs the fix's intent + both versions + upstream's
# recent history on the touched files - which is what this script gathers.
#
# Output: prints a review bundle (or writes it to a file with -o <path>)
# that firstmate reads during the fork sync and records verdicts into
# FIXES.md: landed-differently / still-needed / needs-reapply.
#
# Usage: fm-fixes-review.sh [-o <outfile>] [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
OUT=""

usage() { echo "usage: fm-fixes-review.sh [-o <outfile>] [--help]" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

emit() {  # print or append to OUT
  if [ -n "$OUT" ]; then printf '%s\n' "$1" >> "$OUT"; else printf '%s\n' "$1"; fi
}

[ -z "$OUT" ] || : > "$OUT"

emit "# Firstmate local-fix upstream-adoption review bundle"
emit "# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by fm-fixes-review.sh"
emit "# For each fix, judge: has upstream solved the same PROBLEM (any code)?"
emit "# Verdicts: landed-differently | still-needed | needs-reapply"
emit ""

mapfile -t FIX_COMMITS < <(git -C "$FM_ROOT" log --format='%h %s' upstream/main..origin/main 2>/dev/null || true)
if [ "${#FIX_COMMITS[@]}" -eq 0 ]; then
  emit "No local fixes (upstream/main..origin/main is empty)."
  exit 0
fi

# Pull each fix's intent row from FIXES.md (the table's Why column is the
# semantic intent; the files column says what to compare).
fixes_md="$FM_ROOT/FIXES.md"

for line in "${FIX_COMMITS[@]}"; do
  c=${line%% *}
  subject=${line#* }
  emit "=================================================================="
  emit "FIX $c: $subject"
  emit ""
  emit "## Intent (from FIXES.md + commit message)"
  # Find the FIXES.md table row for this commit and show its Why column.
  row=$(grep -E "^\| \`$c\`" "$fixes_md" 2>/dev/null | head -1 || true)
  if [ -n "$row" ]; then
    emit "$row"
  else
    emit "(no FIXES.md row for $c - intent is only the commit message)"
  fi
  emit "commit message: $(git -C "$FM_ROOT" log -1 --format='%B' "$c" 2>/dev/null | head -1)"
  emit ""
  emit "## Files the fix touches"
  files=$(git -C "$FM_ROOT" show --format='' --name-only "$c" 2>/dev/null | grep -v '^$' || true)
  [ -n "$files" ] || files="(none)"
  emit "$files"
  emit ""
  for f in $files; do
    # skip tests/docs for the semantic comparison (they prove intent, not the fix)
    case "$f" in
      tests/*|docs/*|README.md|FIXES.md) continue ;;
    esac
    emit "### File: $f"
    if ! git -C "$FM_ROOT" cat-file -e "upstream/main:$f" 2>/dev/null; then
      emit "  upstream: FILE DOES NOT EXIST -> the feature is absent upstream"
      emit "  (strong signal the intent has NOT landed; still-needed unless a"
      emit "  different upstream file now serves the same purpose)"
      continue
    fi
    # Does the fix's file differ from upstream? (identical = landed verbatim)
    up=$(git -C "$FM_ROOT" rev-parse "upstream/main:$f" 2>/dev/null || echo none)
    fix=$(git -C "$FM_ROOT" rev-parse "$c:$f" 2>/dev/null || echo none)
    if [ "$up" = "$fix" ]; then
      emit "  upstream blob == fix blob -> identical (mechanical check already flags superseded)"
      continue
    fi
    emit "  upstream file differs from the fix's version."
    emit "  -- upstream recent commits touching this file (semantic signal):"
    git -C "$FM_ROOT" log --oneline upstream/main -6 -- "$f" 2>/dev/null | sed 's/^/     /' || true
    emit "  -- fix's diffstat vs its parent:"
    git -C "$FM_ROOT" show --stat --format='' "$c" -- "$f" 2>/dev/null | sed 's/^/     /' || true
    emit ""
  done
done

emit "=================================================================="
emit "END. Firstmate: for each FIX, decide landed-differently / still-needed"
emit "/ needs-reapply, then update FIXES.md status and drop superseded fixes"
emit "on the next rebase."
