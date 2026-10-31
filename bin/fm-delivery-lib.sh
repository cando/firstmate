#!/usr/bin/env bash
# fm-delivery-lib.sh - the watcher's terminal-delivery ledger and its
# retired-window rule.
#
# The watcher blocks until it has one actionable reason, prints it, and exits.
# An arm that ATTACHED to that cycle holds no handle on the watcher's stdout, so
# the only durable evidence the cycle delivered anything is the row the watcher
# appends here with its own pid and process identity before it releases the
# singleton lock (docs/watcher-continuity.md "Terminal-delivery ledger").
#
# This library owns that ledger: its paths and bounds, its row format, the
# publish path, and the rule deciding whether a recorded reason is still
# reportable. bin/fm-push-transition-lib.sh (the watcher's publisher) and
# bin/fm-watch-arm.sh (the reader) share it instead of keeping private copies.
#
# A row outlives the window it names. A task can be retired moments after the
# cycle that surfaced it delivered, and bin/fm-teardown.sh then removes that
# task's state/<id>.meta while the row stays. The ledger is append-only and every
# later attach scans it, so such a row replayed a finished task's wake on every
# subsequent cycle: identical "stale: <window>" interruptions naming a window
# that no longer existed, each one costing a captain-facing turn. A reason naming
# a window this home no longer records is therefore retired: it is never
# reported, and the next write or read drops it from the ledger.
#
# Only reasons that name a window carry this test. A `signal:` row names status
# files rather than a window, and it stays reportable because the cycle that
# wrote it is the very close that needs explaining.

FM_DELIVERY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-wake-lib.sh
. "$FM_DELIVERY_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$FM_DELIVERY_LIB_DIR/fm-backend.sh"

WATCH_DELIVERY_LOG="$STATE/.watch-deliveries.log"
WATCH_DELIVERY_LOCK="$STATE/.watch-deliveries.lock"
WATCH_DELIVERY_MAX_BYTES=${FM_WATCH_DELIVERY_MAX_BYTES:-65536}
WATCH_DELIVERY_KEEP_LINES=${FM_WATCH_DELIVERY_KEEP_LINES:-64}
case "$WATCH_DELIVERY_MAX_BYTES" in ''|*[!0-9]*|0) WATCH_DELIVERY_MAX_BYTES=65536 ;; esac
case "$WATCH_DELIVERY_KEEP_LINES" in ''|*[!0-9]*|0) WATCH_DELIVERY_KEEP_LINES=64 ;; esac

watch_delivery_clean_identity() {
  printf '%s' "$1" | tr '\t\r\n' '   '
}

watch_delivery_clean_reason() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-4096
}

# Print the window a delivery reason names, failing when it names none. Only the
# watcher's `stale: <window> ...` reasons name one; the other wake kinds report a
# check, a status file, a process-event result, or the heartbeat.
watch_delivery_reason_window() {  # <reason>
  local reason=$1 window
  case "$reason" in
    'stale: '*) ;;
    *) return 1 ;;
  esac
  window=${reason#stale: }
  window=${window%% *}
  # A token of this shape is a backend target; anything else is not a window this
  # ledger can test, so it stays reportable rather than being dropped.
  case "$window" in
    ''|*[!A-Za-z0-9._:-]*) return 1 ;;
  esac
  printf '%s' "$window"
}

# Print the backend targets this home still records, one per line. One scan per
# caller pass keeps the retired-window test below a string comparison instead of
# a per-row record lookup.
watch_delivery_recorded_targets() {  # <state-dir>
  local state=$1 meta target
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    target=$(fm_backend_target_of_meta "$meta" 2>/dev/null || true)
    [ -n "$target" ] || continue
    printf '%s\n' "$target"
  done
}

# True when <reason> names a window absent from <recorded-targets> (a newline
# separated list from watch_delivery_recorded_targets): the task behind that
# window is retired, so its wake is finished work rather than something to
# report again.
watch_delivery_reason_retired() {  # <reason> <recorded-targets>
  local window
  window=$(watch_delivery_reason_window "$1") || return 1
  case $'\n'"$2"$'\n' in
    *$'\n'"$window"$'\n'*) return 1 ;;
  esac
  return 0
}

# Rewrite the ledger without its retired-window rows, bounded to the newest
# WATCH_DELIVERY_KEEP_LINES rows so a repeated rewrite cannot grow it. The caller
# must hold WATCH_DELIVERY_LOCK.
watch_delivery_rewrite_locked() {  # <state-dir>
  local state=$1 log targets tmp kept lines pid ident reason
  log="$WATCH_DELIVERY_LOG"
  [ -f "$log" ] || return 0
  targets=$(watch_delivery_recorded_targets "$state")
  tmp="$log.tmp.${FM_WATCH_DELIVERY_PID:-$$}"
  : > "$tmp" 2>/dev/null || return 0
  while IFS=$'\t' read -r pid ident reason; do
    [ -n "$pid$ident$reason" ] || continue
    watch_delivery_reason_retired "$reason" "$targets" && continue
    printf '%s\t%s\t%s\n' "$pid" "$ident" "$reason" >> "$tmp" 2>/dev/null || {
      rm -f "$tmp" 2>/dev/null || true
      return 0
    }
  done < "$log"
  lines=$(wc -l < "$tmp" 2>/dev/null | tr -d '[:space:]')
  case "$lines" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$lines" -gt "$WATCH_DELIVERY_KEEP_LINES" ]; then
        kept="$tmp.keep"
        tail -n "$WATCH_DELIVERY_KEEP_LINES" "$tmp" > "$kept" 2>/dev/null \
          && mv -f "$kept" "$tmp" 2>/dev/null
        rm -f "$kept" 2>/dev/null || true
      fi
      ;;
  esac
  mv -f "$tmp" "$log" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

watch_delivery_publish() {
  # Identity/reason cleaning are sequential $(): sibling $() args to one
  # printf are a bash 5.2 parse-error landmine when a CHLD trap is set.
  local reason=$1 i size tmp raw ident cleaned_reason
  [ -n "$FM_WATCH_DELIVERY_PID" ] || return 0
  [ -n "$FM_WATCH_DELIVERY_IDENTITY" ] || return 0
  i=0
  while ! fm_lock_try_acquire "$WATCH_DELIVERY_LOCK"; do
    [ "$i" -lt 20 ] || return 0
    sleep 0.02
    i=$((i + 1))
  done
  ident=$(watch_delivery_clean_identity "$FM_WATCH_DELIVERY_IDENTITY")
  cleaned_reason=$(watch_delivery_clean_reason "$reason")
  printf '%s\t%s\t%s\n' \
    "$FM_WATCH_DELIVERY_PID" \
    "$ident" \
    "$cleaned_reason" >> "$WATCH_DELIVERY_LOG" 2>/dev/null || true
  # Prune retired windows on write. A row naming a window this home no longer
  # records can never be reported again, and leaving it behind is exactly what
  # kept replaying a finished task's wake.
  watch_delivery_rewrite_locked "$STATE"
  size=$(wc -c < "$WATCH_DELIVERY_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$size" -ge "$WATCH_DELIVERY_MAX_BYTES" ]; then
        tmp="$WATCH_DELIVERY_LOG.tmp.$FM_WATCH_DELIVERY_PID"
        raw="$tmp.raw"
        tail -n "$WATCH_DELIVERY_KEEP_LINES" "$WATCH_DELIVERY_LOG" 2>/dev/null \
          | tail -c "$WATCH_DELIVERY_MAX_BYTES" > "$raw" 2>/dev/null \
          && awk 'NR > 1 || /^[0-9]+\t/' "$raw" > "$tmp" 2>/dev/null \
          && mv -f "$tmp" "$WATCH_DELIVERY_LOG" 2>/dev/null
        rm -f "$tmp" "$raw" 2>/dev/null || true
      fi
      ;;
  esac
  fm_lock_release "$WATCH_DELIVERY_LOCK"
}
