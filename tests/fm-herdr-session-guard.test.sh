#!/usr/bin/env bash
# Tests for the tracked Herdr session-guard Pi extension.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-session-guard)
GUARD="$ROOT/.pi/extensions/fm-herdr-session-guard.ts"
# Node 24 warns when these test-only dynamic imports load tracked ESM plugins
# from a clean checkout with no tracked .opencode/package.json. The warning is
# unrelated to plugin output, which the assertions intentionally require empty.
export NODE_NO_WARNINGS=1

# A fake herdr socket server plus a fake pi API, driven from one node process.
# The socket speaks the newline-delimited JSON surface the real herdr server
# uses: agent.get returns the pane agent snapshot and pane.report_agent records
# the repair and optionally flips the server into the repaired state.
run_guard_scenario() {  # <scenario-name> <mode> <accept-repair> <away-marker>
  local name=$1 mode=$2 accept_repair=$3 away_marker=$4 out status
  local state_dir sock_path
  state_dir="$TMP_ROOT/$name-state"
  sock_path="$TMP_ROOT/$name.sock"
  mkdir -p "$state_dir"
  if [ "$away_marker" = away ]; then
    : > "$state_dir/.afk"
  fi
  out=$(FM_STATE_OVERRIDE="$state_dir" \
    FM_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/fm-operational-input.sh" \
    HERDR_ENV=1 \
    HERDR_SOCKET_PATH="$sock_path" \
    HERDR_PANE_ID=w1:p1 \
    FM_HERDR_GUARD_CHECK_DEFER_MS=5 \
    FM_HERDR_GUARD_CHECK_INTERVAL_MS=3600000 \
    FM_HERDR_GUARD_ESCALATION_THRESHOLD=3 \
    GUARD="$GUARD" \
    MODE="$mode" \
    ACCEPT_REPAIR="$accept_repair" \
    node --input-type=module 2>&1 <<'EOF'
import { createServer } from "node:net";
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mode = process.env.MODE;
const acceptRepair = process.env.ACCEPT_REPAIR === "1";
const sockPath = process.env.HERDR_SOCKET_PATH;
const sessionFile = "/home/cando/.pi/agent/sessions/--home-cando-development-firstmate--/live.jsonl";

let paneState = mode; // broken | healthy | noagent | reject
const repairs = [];
let prompts = [];
const handlers = {};
const events = {};

const pi = {
  on(event, handler) {
    handlers[event] = handler;
  },
  events: {
    on(event, handler) {
      events[event] = handler;
    },
  },
  sendUserMessage: async (content, _options) => {
    prompts.push(content);
  },
};

const server = createServer((socket) => {
  let buffer = "";
  socket.setEncoding("utf8");
  socket.on("data", (chunk) => {
    buffer += chunk;
    let newline;
    while ((newline = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      if (!line.trim()) continue;
      let request;
      try {
        request = JSON.parse(line);
      } catch {
        continue;
      }
      const id = request.id;
      if (request.method === "agent.get") {
        let agent = null;
        if (paneState === "broken" || paneState === "healthy" || paneState === "reject") {
          agent = {
            agent: "pi",
            agent_session:
              paneState === "healthy"
                ? { agent: "pi", kind: "path", source: "herdr:pi", value: sessionFile }
                : null,
          };
        }
        socket.write(`${JSON.stringify({ id, result: { agent, type: "agent_info" } })}\n`);
      } else if (request.method === "pane.report_agent") {
        repairs.push(request.params);
        if (acceptRepair && paneState === "broken") {
          paneState = "healthy";
        }
        socket.write(`${JSON.stringify({ id, result: { type: "ok" } })}\n`);
      } else {
        socket.write(`${JSON.stringify({ id, error: { code: "not_implemented", message: "test stub" } })}\n`);
      }
    }
  });
});

const ctx = (idle) => ({
  hasUI: true,
  cwd: "/home/cando/development/firstmate",
  isIdle: () => idle === true,
  sessionManager: {
    getSessionFile: () => sessionFile,
    getSessionId: () => "019fc731-ebf3-7079-80df-ea1647965951",
  },
});

await new Promise((resolveListen) => server.listen(sockPath, resolveListen));
const mod = await import(pathToFileURL(process.env.GUARD).href);
mod.default(pi);
await handlers.session_start({ type: "session_start", reason: "startup" }, ctx(false));
await new Promise((resolveWait) => setTimeout(resolveWait, 60));

// Emit enough turn events to run several check cycles.
for (let i = 0; i < 5; i += 1) {
  await handlers.turn_start({ type: "turn_start" }, ctx(false));
  await new Promise((resolveWait) => setTimeout(resolveWait, 40));
}

console.log(JSON.stringify({ repairs, prompts, paneState }));
server.close();
writeFileSync(`${process.env.FM_STATE_OVERRIDE}/result.json`, JSON.stringify({ repairs, prompts }));
EOF
)
  status=$?
  expect_code 0 "$status" "guard $name scenario must exit 0"
  printf '%s\n' "$out"
}

test_guard_repairs_missing_binding() {
  local out repairs prompts
  out=$(run_guard_scenario repair-broken broken 1 no-away)
  repairs=$(printf '%s' "$out" | tail -1 | jq -r '.repairs | length')
  prompts=$(printf '%s' "$out" | tail -1 | jq -r '.prompts | length')
  [ "$repairs" -ge 1 ] || fail "guard must repair a missing binding, got $repairs repairs"
  printf '%s' "$out" | tail -1 | jq -e '.repairs[0].source == "herdr:pi" and .repairs[0].agent == "pi" and .repairs[0].agent_session_path == "/home/cando/.pi/agent/sessions/--home-cando-development-firstmate--/live.jsonl"' >/dev/null \
    || fail "guard repair must report source herdr:pi agent pi with the session path"
  [ "$prompts" -eq 0 ] || fail "guard must not escalate when the repair lands, got $prompts prompts"
  pass "guard re-reports the missing agent_session binding exactly like herdr's integration"
}

test_guard_is_read_only_when_healthy() {
  local out repairs
  out=$(run_guard_scenario repair-healthy healthy 1 no-away)
  repairs=$(printf '%s' "$out" | tail -1 | jq -r '.repairs | length')
  [ "$repairs" -eq 0 ] || fail "guard must not repair a healthy binding, got $repairs repairs"
  pass "guard stays read-only on a healthy pane"
}

test_guard_ignores_panes_without_pi() {
  local out repairs
  out=$(run_guard_scenario repair-noagent noagent 1 no-away)
  repairs=$(printf '%s' "$out" | tail -1 | jq -r '.repairs | length')
  [ "$repairs" -eq 0 ] || fail "guard must not repair a pane that reports no pi agent, got $repairs repairs"
  pass "guard ignores panes that do not report a pi agent"
}

test_guard_escalates_once_when_repair_cannot_land() {
  local out prompts first
  out=$(run_guard_scenario repair-reject reject 0 no-away)
  prompts=$(printf '%s' "$out" | tail -1 | jq -r '.prompts | length')
  [ "$prompts" -eq 1 ] || fail "guard must escalate exactly once per broken episode, got $prompts prompts"
  first=$(printf '%s' "$out" | tail -1 | jq -r '.prompts[0]')
  case "$first" in
    $'\u2063FIRSTMATE_OP: v1 herdr-guard: '*)
      ;;
    *)
      fail "guard escalation must use the herdr-guard operational kind: $first"
      ;;
  esac
  case "$first" in
    *"Restart pi"*) ;;
    *) fail "guard escalation must carry the restart instruction: $first" ;;
  esac
  case "$first" in
    *"no agent_session"*) ;;
    *) fail "guard escalation must name the missing binding: $first" ;;
  esac
  pass "guard surfaces one bounded escalation with the exact reason and restart instruction"
}

test_guard_skips_escalation_while_away() {
  local out prompts
  out=$(run_guard_scenario repair-away reject 0 away)
  prompts=$(printf '%s' "$out" | tail -1 | jq -r '.prompts | length')
  [ "$prompts" -eq 0 ] || fail "guard must not inject escalation while away mode is active, got $prompts prompts"
  pass "guard defers escalation to the away supervisor"
}

test_guard_disabled_outside_herdr() {
  local out status
  out=$(HERDR_ENV='' GUARD="$GUARD" FM_STATE_OVERRIDE="$TMP_ROOT/disabled-state" \
    FM_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/fm-operational-input.sh" \
    node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
let handlers = 0;
const pi = {
  on() {
    handlers += 1;
  },
  events: { on() {} },
  sendUserMessage: async () => {},
};
const mod = await import(pathToFileURL(process.env.GUARD).href);
mod.default(pi);
if (handlers !== 0) {
  throw new Error(`disabled guard must register no handlers, got ${handlers}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "guard must be inert outside a herdr pane"
  [ -z "$out" ] || fail "disabled guard printed output: $out"
  pass "guard is inert when herdr environment is absent"
}

test_guard_repairs_missing_binding
test_guard_is_read_only_when_healthy
test_guard_ignores_panes_without_pi
test_guard_escalates_once_when_repair_cannot_land
test_guard_skips_escalation_while_away
test_guard_disabled_outside_herdr
