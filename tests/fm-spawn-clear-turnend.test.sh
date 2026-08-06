#!/usr/bin/env bash
# tests/fm-spawn-clear-turnend.test.sh - re-spawn regressions for stale
# state/<id>.turn-ended and state/<id>.status markers.
#
# A re-spawn (recovery relaunch, restart without teardown) must start with a
# clean slate: the previous incarnation's turn-end marker would otherwise read
# as a fresh completed turn to the watcher and wake firstmate before any turn
# has ended in the new incarnation, and a stale terminal status line could
# misclassify the same wake. Drives bin/fm-spawn.sh through the CLI with fake
# tmux panes and a real isolated git worktree, then asserts the stale markers
# are cleared on the re-spawn while a clean first spawn stays a no-op.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-clear-turnend)
fm_git_identity fmtest fmtest@example.invalid

# Fake tmux: answers the pane-path query with the worktree, accepts window
# commands, and logs no launch payload (the launch is observable through the
# spawn's own success line). Modeled on fm-trace-context-spawn.test.sh's
# fakebin, minus its trace-context branches.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# A home + project + linked worktree + brief, the minimum fm-spawn.sh needs to
# reach the per-task state wiring. Prints "home|proj|wt|fakebin|id".
make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  id=$name-z1
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$id"
}

# Hermetic against ambient FM_TRACE_CONTEXT so the run is decided only by the
# fixture; FM_SPAWN_NO_GUARD keeps it off the live watcher guard / state lock.
run_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  shift 5
  env -u FM_TRACE_CONTEXT \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" --mode no-mistakes --yolo off 2>&1
}

# The regression: a re-spawn of a task whose previous incarnation left a
# .turn-ended marker and a status log behind must clear both before launch, so
# the watcher cannot read a phantom completed turn or a stale terminal line.
test_respawn_clears_stale_turnend_and_status() {
  local rec home proj wt fakebin id out status
  rec=$(make_spawn_case respawn)
  IFS='|' read -r home proj wt fakebin id <<EOF
$rec
EOF

  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$id" "$proj")
  status=$?
  expect_code 0 "$status" "first spawn should succeed"
  assert_contains "$out" "spawned $id" "first spawn should report success"

  # Simulate a crashed or incompletely torn-down incarnation that left its
  # turn-end marker and a terminal status line behind.
  printf 'stale marker\n' > "$home/state/$id.turn-ended"
  printf 'done: PR https://example.invalid/stale\n' > "$home/state/$id.status"

  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$id" "$proj")
  status=$?
  expect_code 0 "$status" "re-spawn should succeed"
  assert_contains "$out" "spawned $id" "re-spawn should report success"
  assert_absent "$home/state/$id.turn-ended" "re-spawn must clear the stale turn-ended marker"
  assert_absent "$home/state/$id.status" "re-spawn must clear the stale status log"
  pass "re-spawn clears a pre-existing .turn-ended and .status before launch"
}

# A clean first spawn must be a no-op for the same files (rm -f) and still write
# its meta: the clear is scoped to the wake markers, never the task record.
test_clean_spawn_leaves_no_stale_marker_and_writes_meta() {
  local rec home proj wt fakebin id out status
  rec=$(make_spawn_case clean)
  IFS='|' read -r home proj wt fakebin id <<EOF
$rec
EOF

  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$id" "$proj")
  status=$?
  expect_code 0 "$status" "clean spawn should succeed"
  assert_contains "$out" "spawned $id" "clean spawn should report success"
  assert_absent "$home/state/$id.turn-ended" "a fresh spawn must leave no turn-ended marker"
  assert_absent "$home/state/$id.status" "a fresh spawn must leave no status log"
  assert_present "$home/state/$id.meta" "a fresh spawn must still record its meta"
  pass "clean first spawn: no stale markers, meta still written"
}

test_respawn_clears_stale_turnend_and_status
test_clean_spawn_leaves_no_stale_marker_and_writes_meta

echo "# all fm-spawn-clear-turnend tests passed"
