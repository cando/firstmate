// Firstmate primary-pane Herdr agent-session guard.
//
// Herdr's own pi integration (HERDR_INTEGRATION_ID=pi, installed by herdr at
// ~/.pi/agent/extensions/herdr-agent-state.ts and managed by herdr) is the
// only source of a pi pane's agent_session binding and live working/idle state.
// That integration captures the pi session file only at session_start and
// agent_start and reports it only then. When the capture or report is missed,
// herdr 0.7.5 clears the pane's binding on the first state report without a
// session ref and never restores it, so the pane shows agent=pi with no
// agent_session and no spinner while the agent is working. A pi restart fixes
// it because a fresh integration instance re-reports the session.
//
// This guard runs inside the same pi (it is loaded from this repo's own
// .pi/extensions, so every firstmate-home pi under herdr runs it) and keeps
// the pane's binding anchored: at session and turn boundaries and on a short
// timer it reads its own pane over the herdr socket and, when the pane
// reports a pi agent with no agent_session, re-reports the binding exactly
// like herdr's integration would (source herdr:pi, agent pi, the current pi
// session file). The repair is idempotent when the binding is healthy, so the
// guard is read-only on a healthy pane and never fights the integration's own
// reports. When a repair cannot succeed it escalates once per broken episode
// through the firstmate operational channel so the captain sees the exact
// reason and the restart instruction.
//
// The guard deliberately mirrors herdr's integration activation gate
// (ctx.hasUI === true) and its state tracking (agent_start / agent_settled /
// herdr:blocked), so its state reports agree with the integration's when both
// run. All socket requests are newline-delimited JSON on HERDR_SOCKET_PATH,
// the same transport herdr's own integration uses.
import net from "node:net";
import { existsSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.ts";

const HERDR_ENV = process.env.HERDR_ENV;
const socketPath = process.env.HERDR_SOCKET_PATH;
const socketEndpoint =
  process.platform === "win32" && socketPath ? `\\\\.\\pipe\\${socketPath}` : socketPath;
const paneId = process.env.HERDR_PANE_ID;
const source = "herdr:pi";
const agentLabel = "pi";

const extensionFile = fileURLToPath(import.meta.url);
const root = resolve(dirname(extensionFile), "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmState = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const afkMarker = resolve(fmState, ".afk");

const checkIntervalMs = positiveInteger("FM_HERDR_GUARD_CHECK_INTERVAL_MS", 60000);
const checkDeferMs = positiveInteger("FM_HERDR_GUARD_CHECK_DEFER_MS", 200);
const escalationThreshold = positiveInteger("FM_HERDR_GUARD_ESCALATION_THRESHOLD", 3);

function positiveInteger(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

function enabled(): boolean {
  return HERDR_ENV === "1" && !!socketPath && !!paneId;
}

type AgentState = "working" | "blocked" | "idle";

type Binding = {
  ok: boolean;
  agent: string | null;
  hasSession: boolean;
};

let nextRequestId = 0;

function requestId(prefix: string): string {
  nextRequestId += 1;
  return `${prefix}:${Date.now()}:${nextRequestId}:${Math.random().toString(36).slice(2)}`;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolveSleep) => {
    const timer = setTimeout(resolveSleep, ms);
    timer.unref?.();
  });
}

function sendRequestOnce(request: unknown, timeoutMs: number): Promise<string | undefined> {
  if (!enabled()) {
    return Promise.resolve(undefined);
  }
  const replyId = (request as { id: string }).id;
  return new Promise((resolveReply) => {
    let done = false;
    let timeout: ReturnType<typeof setTimeout> | undefined;
    let buffer = "";
    const finish = (body?: string) => {
      if (done) return;
      done = true;
      if (timeout) {
        clearTimeout(timeout);
      }
      socket.destroy();
      resolveReply(body);
    };
    const socket = net.createConnection(socketEndpoint!);
    socket.on("error", () => finish(undefined));
    socket.on("connect", () => socket.write(`${JSON.stringify(request)}\n`));
    socket.on("data", (chunk: Buffer) => {
      buffer += chunk.toString();
      for (const line of buffer.split("\n")) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        try {
          const parsed = JSON.parse(trimmed) as { id?: unknown };
          if (parsed?.id === replyId) {
            finish(trimmed);
            return;
          }
        } catch {
          // a partial or unrelated line; keep reading
        }
      }
    });
    socket.on("end", () => finish(undefined));
    socket.on("close", () => finish(undefined));
    timeout = setTimeout(() => finish(undefined), timeoutMs);
    timeout.unref?.();
  });
}

async function sendRequest(request: unknown): Promise<string | undefined> {
  const first = await sendRequestOnce(request, 500);
  if (first !== undefined) return first;
  return sendRequestOnce(request, 1500);
}

async function checkBinding(): Promise<Binding> {
  const reply = await sendRequest({
    id: requestId("fm-herdr-guard:check"),
    method: "agent.get",
    params: { target: paneId },
  });
  if (reply === undefined) {
    return { ok: false, agent: null, hasSession: false };
  }
  try {
    const parsed = JSON.parse(reply) as {
      result?: {
        agent?: { agent?: string | null; agent_session?: unknown } | null;
      };
    };
    const agent = parsed?.result?.agent;
    if (agent === null || agent === undefined) {
      return { ok: true, agent: null, hasSession: false };
    }
    const label = agent.agent ?? null;
    const session = agent.agent_session;
    return {
      ok: true,
      agent: label,
      hasSession: session !== null && session !== undefined,
    };
  } catch {
    return { ok: false, agent: null, hasSession: false };
  }
}

// The default session directory pi derives from a session cwd
// (dist/core/session-manager.js getDefaultSessionDirPath): a leading slash is
// stripped, remaining slashes and colons become dashes, and the result is
// wrapped in a double-dash pair under ~/.pi/agent/sessions/. The newest
// *.jsonl in that directory is the live session file, which is exactly what
// herdr's integration reports as agent_session_path.
function sessionDirForCwd(cwd: string): string {
  const agentDir = join(process.env.HOME ?? "/", ".pi", "agent");
  const safePath = `--${cwd.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`;
  return join(agentDir, "sessions", safePath);
}

function newestSessionFile(cwd: string): string | undefined {
  const dir = sessionDirForCwd(cwd);
  let entries: string[];
  try {
    entries = readdirSync(dir);
  } catch {
    return undefined;
  }
  const jsonl = entries
    .filter((name) => name.endsWith(".jsonl"))
    .sort()
    .reverse();
  return jsonl.length > 0 ? join(dir, jsonl[0]) : undefined;
}

export default function (pi: {
  events?: {
    on?: (event: string, handler: (data: unknown) => void) => void;
  };
  on?: (event: string, handler: (event: unknown, ctx: unknown) => void) => void;
  sendUserMessage?: (content: string, options: { deliverAs: string }) => Promise<void>;
}) {
  if (!enabled()) {
    return;
  }

  let rootSession = false;
  let agentActive = false;
  let blockedCount = 0;
  let sessionPath: string | undefined;
  let failureCount = 0;
  let escalationSent = false;
  let timer: ReturnType<typeof setInterval> | undefined;
  let pendingCheck: ReturnType<typeof setTimeout> | undefined;

  function desiredState(): AgentState {
    if (blockedCount > 0) {
      return "blocked";
    }
    if (agentActive) {
      return "working";
    }
    return "idle";
  }

  function captureSessionRef(ctx: any): void {
    let file: unknown;
    try {
      file = ctx?.sessionManager?.getSessionFile?.();
    } catch {
      file = undefined;
    }
    if (typeof file === "string" && file.startsWith("/")) {
      sessionPath = file;
      return;
    }
    // Fall back to the on-disk live session file so a repair never depends on
    // the session manager having resolved the file at event time.
    let cwd: unknown;
    try {
      cwd = ctx?.cwd ?? process.env.PWD;
    } catch {
      cwd = undefined;
    }
    if (typeof cwd === "string" && cwd.startsWith("/") && sessionPath === undefined) {
      sessionPath = newestSessionFile(cwd);
    }
  }

  async function sendRepair(): Promise<boolean> {
    const path = sessionPath;
    if (typeof path !== "string" || path.length === 0) {
      return false;
    }
    const seq = Date.now() * 1000 + nextRequestId;
    const reply = await sendRequest({
      id: requestId("fm-herdr-guard:repair"),
      method: "pane.report_agent",
      params: {
        pane_id: paneId,
        source,
        agent: agentLabel,
        state: desiredState(),
        seq,
        agent_session_path: path,
      },
    });
    return reply !== undefined;
  }

  async function checkAndRepair(): Promise<void> {
    if (!enabled() || !rootSession) {
      return;
    }
    const binding = await checkBinding();
    if (!binding.ok || binding.agent !== agentLabel) {
      return;
    }
    if (binding.hasSession) {
      failureCount = 0;
      escalationSent = false;
      return;
    }
    const repaired = await sendRepair();
    if (repaired) {
      await sleep(checkDeferMs);
      const after = await checkBinding();
      if (after.ok && after.agent === agentLabel && after.hasSession) {
        failureCount = 0;
        escalationSent = false;
        return;
      }
    }
    failureCount += 1;
    if (failureCount >= escalationThreshold && !escalationSent) {
      escalationSent = true;
      void escalate();
    }
  }

  function scheduleCheck(): void {
    if (!rootSession || pendingCheck !== undefined) {
      return;
    }
    pendingCheck = setTimeout(() => {
      pendingCheck = undefined;
      void checkAndRepair();
    }, checkDeferMs);
    pendingCheck.unref?.();
  }

  function startTimer(): void {
    if (timer !== undefined) {
      return;
    }
    timer = setInterval(() => {
      void checkAndRepair();
    }, checkIntervalMs);
    timer.unref?.();
  }

  function stopTimer(): void {
    if (timer !== undefined) {
      clearInterval(timer);
      timer = undefined;
    }
  }

  async function escalate(): Promise<void> {
    // Away mode: the away supervisor owns escalation delivery, so skip direct
    // injection exactly like the watcher extension does.
    try {
      if (existsSync(afkMarker)) {
        console.error("[fm-herdr-session-guard] away mode active; skipping binding escalation");
        return;
      }
    } catch {
      // a missing or unreadable marker is treated as not-away
    }
    const path = sessionPath ?? "unknown";
    const content = encodeFirstmateOperationalInput(
      "herdr-guard",
      `Herdr lost the agent binding for the primary pane (${paneId}): the pane reports agent=pi with no agent_session, so herdr shows it idle with no spinner while it is working. The in-pane guard could not re-attach the binding (session file: ${path}). Restart pi in this pane to re-attach it; herdr's pi integration only reports the session at session start, and a missed report is not recovered until pi restarts.`,
    );
    await pi.sendUserMessage?.(content, { deliverAs: "followUp" });
  }

  pi.events?.on?.("herdr:blocked", (data) => {
    if (!rootSession) {
      return;
    }
    const active = (data as { active?: boolean })?.active;
    if (!active) {
      blockedCount = Math.max(0, blockedCount - 1);
      scheduleCheck();
      return;
    }
    blockedCount += 1;
    scheduleCheck();
  });

  pi.on?.("session_start", (_event, ctx) => {
    const context = ctx as { hasUI?: boolean };
    if (context?.hasUI !== true) {
      return;
    }
    rootSession = true;
    captureSessionRef(ctx);
    agentActive = (ctx as { isIdle?: () => boolean })?.isIdle?.() === false;
    startTimer();
    scheduleCheck();
  });

  pi.on?.("session_shutdown", (event) => {
    if (!rootSession) {
      return;
    }
    if ((event as { reason?: string })?.reason === "quit") {
      rootSession = false;
      stopTimer();
    }
    // A session switch (new/resume/fork/reload) replaces the session file; the
    // next session_start refreshes the ref, so drop the stale one now so the
    // guard never re-anchors the previous session during the switch window.
    sessionPath = undefined;
  });

  pi.on?.("agent_start", (_event, ctx) => {
    if (!rootSession) {
      return;
    }
    captureSessionRef(ctx);
    agentActive = true;
    scheduleCheck();
  });

  pi.on?.("agent_settled", (_event, ctx) => {
    if (!rootSession) {
      return;
    }
    captureSessionRef(ctx);
    if ((ctx as { isIdle?: () => boolean })?.isIdle?.() === true) {
      agentActive = false;
      scheduleCheck();
    }
  });

  pi.on?.("turn_start", (_event, ctx) => {
    if (!rootSession) {
      return;
    }
    captureSessionRef(ctx);
    scheduleCheck();
  });

  pi.on?.("turn_end", (_event, ctx) => {
    if (!rootSession) {
      return;
    }
    captureSessionRef(ctx);
    scheduleCheck();
  });
}
