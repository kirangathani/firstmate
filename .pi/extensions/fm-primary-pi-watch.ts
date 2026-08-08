// Firstmate primary watcher bridge for Pi.
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

type ArmResult = {
  ok: boolean;
  message: string;
};

// "unresolved" is not a verdict about the lock: it means the resolver itself
// failed, which is a different thing from "no live session holds the lock" and
// must not be answered with advice that cannot fix it.
type LockOwnership = "owned" | "missing" | "other" | "unresolved";

type CloseClassification = {
  kind: "actionable" | "failure" | "read-only";
  message: string;
};

// How an arm child settled. "read-only" is a STAND-DOWN, not an unready
// successor: the arm's own session-lock gate refused because another live
// session owns the fleet. It has to be distinguishable from "unready" all the
// way up, or the restoration wrapper reports a correct refusal as a failure.
type ArmReadiness = "ready" | "unready" | "read-only";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const armScript = `${fmRoot}/bin/fm-watch-arm.sh`;
const marker = `${state}/.pi-watch-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;
const retryBaseMs = positiveInteger("FM_WATCH_REARM_RETRY_BASE_MS", 250);
const retryMaxMs = positiveInteger("FM_WATCH_REARM_RETRY_MAX_MS", 4000);
const retryLimit = positiveInteger("FM_WATCH_REARM_RETRY_LIMIT", 5);
const armReadyTimeoutMs = positiveInteger("FM_PI_ARM_READY_TIMEOUT_MS", 12000);
const armRetireTimeoutMs = positiveInteger("FM_WATCH_ARM_RETIRE_TIMEOUT_MS", 1000);

let child: ChildProcess | null = null;
let retryTimer: ReturnType<typeof setTimeout> | null = null;
let retryFailures = 0;
let stopping = false;
let seq = 0;
let restoring = false;
const armReadiness = new WeakMap<ChildProcess, Promise<ArmReadiness>>();
const armClose = new WeakMap<ChildProcess, Promise<void>>();

function positiveInteger(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

// Session-lock ownership (state/.lock: which session controls this home's
// fleet, never the state/.watch.lock watcher singleton) is resolved by
// bin/fm-session-lock-lib.sh through `bin/fm-lock.sh ownership`, so this
// extension carries no second copy of the ancestry walk. The child process runs
// below this one, so the walk still finds this Pi session among its ancestors.
//
// Only a recognised word on stdout is a verdict. A missing or non-executable
// bin/fm-lock.sh, or a spawn error, is a RESOLVER failure: reading it as
// "missing" would answer it with "run bin/fm-session-start.sh", advice that
// cannot fix a missing script, so it resolves to "unresolved" and the real cause
// is surfaced instead.
let lastOwnershipError = "";

function lockOwnership(): LockOwnership {
  const result = spawnSync(`${fmRoot}/bin/fm-lock.sh`, ["ownership"], {
    encoding: "utf8",
    env: { ...process.env, FM_HOME: fmHome, FM_STATE_OVERRIDE: state },
  });
  const ownership = (result.stdout || "").trim();
  if (ownership === "owned" || ownership === "other" || ownership === "missing") return ownership;
  const detail = result.error?.message
    || (result.stderr || "").trim()
    || `no ownership verdict on stdout${ownership ? `: ${ownership}` : ""}`;
  lastOwnershipError = `${fmRoot}/bin/fm-lock.sh ownership failed (exit ${result.status ?? "none"}): ${detail}`;
  return "unresolved";
}

// The verdict is resolved once per arm and passed in, so a single arm does not
// spawn bin/fm-lock.sh twice for the same question.
function markLoaded(ownership: LockOwnership = lockOwnership()): void {
  if (ownership === "other") return;
  mkdirSync(state, { recursive: true });
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

function actionableLine(output: string): string {
  const lines = output.split(/\r?\n/);
  return lines.find((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line)) || "";
}

function classifyClose(stdout: string, stderr: string, code: number | null, signal: NodeJS.Signals | null): CloseClassification {
  const combined = `${stdout}\n${stderr}`.trim();
  const reason = actionableLine(combined);
  if (reason) return { kind: "actionable", message: reason };
  // The arm's own session-lock gate can refuse after this extension's pre-check,
  // if the lock changed in between. That refusal is exit 0 with no actionable
  // line and is correct behavior, never a watcher failure.
  const readOnly = combined.split(/\r?\n/).find((line) => /^watcher: read-only\b/.test(line));
  if (readOnly) return { kind: "read-only", message: readOnly };
  const healthy = combined.split(/\r?\n/).find((line) => /^watcher: healthy\b/.test(line));
  if (healthy) {
    return {
      kind: "failure",
      message: `watcher: FAILED - Pi extension arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`,
    };
  }
  const failed = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
  if (failed) return { kind: "failure", message: failed };
  if (signal) {
    return {
      kind: "failure",
      message: `watcher: FAILED - Pi extension arm child ended from ${signal}${combined ? `\n${combined}` : ""}`,
    };
  }
  if (code && code !== 0) {
    return {
      kind: "failure",
      message: `watcher: FAILED - fm-watch-arm.sh exited ${code}${combined ? `\n${combined}` : ""}`,
    };
  }
  return {
    kind: "failure",
    message: "watcher: FAILED - Pi extension arm cycle ended without an actionable reason",
  };
}

export default function (pi: ExtensionAPI) {
  function stopArm(): void {
    stopping = true;
    if (retryTimer) clearTimeout(retryTimer);
    retryTimer = null;
    if (child) child.kill("SIGTERM");
    child = null;
  }

  const cleanupOnProcessExit = () => {
    stopArm();
  };
  process.once("exit", cleanupOnProcessExit);

  async function sendWake(message: string): Promise<void> {
    await pi.sendUserMessage(
      `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.`,
      { deliverAs: "followUp" },
    );
  }

  function surfaceFailure(message: string): void {
    void sendWake(message).catch(() => {
      // Pi owns delivery errors; continuity restoration never waits on prompting.
    });
  }

  function retryDelay(attempt: number): number {
    return Math.min(retryMaxMs, retryBaseMs * 2 ** Math.max(0, attempt - 1));
  }

  function waitForRetry(attempt: number): Promise<void> {
    return new Promise((resolveRetry) => {
      const timer = setTimeout(resolveRetry, retryDelay(attempt));
      timer.unref();
    });
  }

  function waitForReadiness(armChild: ChildProcess): Promise<ArmReadiness> {
    const readiness = armReadiness.get(armChild);
    if (!readiness) return Promise.resolve("unready");
    return new Promise((resolveReady) => {
      const timer = setTimeout(() => resolveReady("unready"), armReadyTimeoutMs);
      timer.unref();
      void readiness.then((ready) => {
        clearTimeout(timer);
        resolveReady(ready);
      });
    });
  }

  async function retireArm(armChild: ChildProcess | null): Promise<boolean> {
    if (!armChild) return true;
    armChild.kill("SIGTERM");
    const closed = armClose.get(armChild);
    if (!closed) return false;
    return new Promise((resolveRetired) => {
      const timer = setTimeout(() => resolveRetired(false), armRetireTimeoutMs);
      timer.unref();
      void closed.then(() => {
        clearTimeout(timer);
        resolveRetired(true);
      });
    });
  }

  // Standing down is an OUTCOME, not a failure: it still says why supervision
  // was not restored, but it carries no `watcher: FAILED` and nothing retries it.
  const readOnlyStandDown = "watcher: read-only - Pi extension stood down instead of restoring continuity because this session no longer owns the lock; another live firstmate session is supervising this home";

  async function restoreAfterActionableClose(predecessorArmPid: string): Promise<string> {
    let failure = "";
    let retried = false;
    for (let attempt = 0; attempt <= retryLimit; attempt += 1) {
      if (stopping) return "";
      const replacement = startArm(predecessorArmPid);
      const successorChild = child;
      if (replacement.ok && successorChild) {
        const readiness = await waitForReadiness(successorChild);
        if (readiness === "ready") return "";
        // Standing down for a fleet another live session owns is correct and
        // terminal: no retry, and never reported as a supervision failure.
        if (readiness === "read-only") return readOnlyStandDown;
        failure = "watcher: FAILED - Pi extension could not verify a ready successor watcher";
        if (!(await retireArm(successorChild))) {
          return `${failure}\nwatcher: FAILED - Pi extension could not restore watcher continuity because the unready successor arm did not exit within ${armRetireTimeoutMs}ms`;
        }
      } else if (replacement.ok) {
        failure = "watcher: FAILED - Pi extension could not verify a ready successor watcher";
      } else if (/read-only/.test(replacement.message)) {
        return readOnlyStandDown;
      } else if (/no live session/.test(replacement.message)) {
        // Nobody holds the lock, so nobody is supervising: still a failure the
        // model has to act on, but there is nothing a retry could change.
        return `watcher: FAILED - Pi extension cannot restore continuity because this session no longer owns the lock\n${replacement.message}`;
      } else {
        failure = `watcher: FAILED - Pi extension could not start the successor watcher cycle\n${replacement.message}`;
      }
      if (attempt === retryLimit) break;
      await waitForRetry(attempt + 1);
      retried = true;
    }
    // The retry sentence is only true on a path that actually retried.
    return retried
      ? `${failure}\nwatcher: FAILED - Pi extension could not restore watcher continuity after ${retryLimit} retries`
      : failure;
  }

  function scheduleRetry(message: string, predecessorArmPid: string): void {
    if (stopping || child || retryTimer) return;
    const ownership = lockOwnership();
    if (ownership === "unresolved") {
      surfaceFailure(`watcher: FAILED - Pi extension could not resolve session-lock ownership, so it did not restore continuity\n${lastOwnershipError}\n${message}`);
      return;
    }
    if (ownership !== "owned") {
      surfaceFailure(`watcher: FAILED - Pi extension cannot restore continuity because this session no longer owns the lock\n${message}`);
      return;
    }
    retryFailures += 1;
    if (retryFailures > retryLimit) {
      surfaceFailure(`watcher: FAILED - Pi extension could not restore watcher continuity after ${retryLimit} retries\n${message}`);
      return;
    }
    const timer = setTimeout(() => {
      if (retryTimer === timer) retryTimer = null;
      const result = startArm(predecessorArmPid);
      if (!result.ok) {
        surfaceFailure(`watcher: FAILED - Pi extension could not launch a continuity retry\n${result.message}`);
      }
    }, retryDelay(retryFailures));
    timer.unref();
    retryTimer = timer;
  }

  function startArm(predecessorArmPid = ""): ArmResult {
    if (stopping) return { ok: false, message: "watcher: not armed - Pi session is shutting down" };
    const ownership = lockOwnership();
    if (ownership === "other") return { ok: false, message: "watcher: read-only - session lock is held by another firstmate session" };
    if (ownership === "unresolved") {
      return {
        ok: false,
        message: `watcher: not armed - could not resolve session-lock ownership, so supervision was not armed\n${lastOwnershipError}`,
      };
    }
    if (ownership === "missing") {
      return {
        ok: false,
        message: "watcher: not armed - no live session holds the lock; run bin/fm-session-start.sh to reclaim it, then call fm_watch_arm_pi to re-arm",
      };
    }
    markLoaded(ownership);
    if (child) return { ok: true, message: "watcher: healthy - Pi extension already has an arm child" };
    if (retryTimer) return { ok: true, message: "watcher: continuity retry already scheduled by the Pi extension" };
    const id = ++seq;
    const env = {
      ...process.env,
      FM_HOME: fmHome,
      FM_ROOT_OVERRIDE: fmRoot,
      FM_CONFIG_OVERRIDE: config,
      FM_WATCH_ARM_SCRIPT: armScript,
      FM_WATCH_PREDECESSOR_ARM_PID: predecessorArmPid,
    };
    const armChild = spawn("bash", ["-lc", "config_dir=\"${FM_CONFIG_OVERRIDE:-$FM_HOME/config}\"; [ -f \"$config_dir/x-mode.env\" ] && . \"$config_dir/x-mode.env\"; exec \"$FM_WATCH_ARM_SCRIPT\" --restart"], {
      cwd: fmRoot,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    child = armChild;
    let stdout = "";
    let stderr = "";
    let settled = false;
    let readinessSettled = false;
    let resolveReadiness: (ready: ArmReadiness) => void = () => {};
    let resolveClosed: () => void = () => {};
    const readiness = new Promise<ArmReadiness>((resolveReady) => {
      resolveReadiness = resolveReady;
    });
    armReadiness.set(armChild, readiness);
    const closed = new Promise<void>((resolveClosedChild) => {
      resolveClosed = resolveClosedChild;
    });
    armClose.set(armChild, closed);
    const settleReadiness = (ready: ArmReadiness): void => {
      if (readinessSettled) return;
      readinessSettled = true;
      resolveReadiness(ready);
    };
    const observeEstablishedArm = (): void => {
      if (/^watcher: (?:started|attached)\b/m.test(`${stdout}\n${stderr}`)) {
        settleReadiness("ready");
      }
    };
    const releaseChild = (): void => {
      if (child === armChild) child = null;
    };
    armChild.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
      observeEstablishedArm();
    });
    armChild.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
      observeEstablishedArm();
    });
    armChild.on("close", (code: number | null, signal: NodeJS.Signals | null) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      releaseChild();
      if (stopping) {
        settleReadiness("unready");
        return;
      }
      // Classified BEFORE readiness settles, so a stand-down close is not first
      // reported upward as an unready successor.
      const classification = classifyClose(stdout, stderr, code, signal);
      const predecessor = String(armChild.pid ?? "");
      if (classification.kind === "read-only") {
        // The arm declined for a lock this session does not hold. Retrying would
        // only decline again, and it is not a supervision failure to report.
        settleReadiness("read-only");
        return;
      }
      settleReadiness("unready");
      if (classification.kind === "actionable") {
        retryFailures = 0;
        restoring = true;
        void (async () => {
          const failure = await restoreAfterActionableClose(predecessor);
          restoring = false;
          if (stopping) return;
          const message = failure ? `${classification.message}\n\n${failure}` : classification.message;
          await sendWake(message);
        })().catch(() => {
        });
        return;
      }
      if (restoring) return;
      scheduleRetry(classification.message, predecessor);
    });
    armChild.on("error", (error: Error) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      settleReadiness("unready");
      releaseChild();
      if (stopping) return;
      if (restoring) return;
      scheduleRetry(`watcher: FAILED - Pi extension arm child ${id} failed: ${error.message}`, String(armChild.pid ?? ""));
    });
    return { ok: true, message: `watcher: started Pi extension arm child ${id}` };
  }

  pi.on?.("session_start", () => {
    markLoaded();
  });
  pi.on?.("session_shutdown", () => {
    stopArm();
    process.off("exit", cleanupOnProcessExit);
  });

  pi.registerCommand?.("fm-watch-arm-pi", {
    description: "Arm firstmate watcher supervision through the Pi extension instead of foreground bash.",
    handler: async (_args, ctx) => {
      const result = startArm();
      ctx.ui.notify(result.message, result.ok ? "info" : "warning");
    },
  });

  pi.registerTool?.({
    name: "fm_watch_arm_pi",
    label: "Arm firstmate watcher",
    description: "Arm Pi watcher supervision. Always use this tool instead of running bin/fm-watch-arm.sh through bash.",
    promptSnippet: "Arm firstmate watcher supervision through Pi without a foreground bash arm.",
    promptGuidelines: [
      "For Pi watcher supervision, call fm_watch_arm_pi instead of running bin/fm-watch-arm.sh through bash.",
    ],
    parameters: Type.Object({}),
    execute: async () => {
      const result = startArm();
      return {
        content: [{ type: "text", text: result.message }],
        details: result,
      };
    },
  });

  markLoaded();
}
