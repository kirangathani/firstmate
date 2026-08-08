import { spawn } from "node:child_process";
import { existsSync, readdirSync, realpathSync } from "node:fs";
import { resolve } from "node:path";

const COORDINATOR_KEY = "__firstmateOpenCodeWatchArm";
const ARM_READY_TIMEOUT_MS = Number(process.env.FM_OPENCODE_ARM_READY_TIMEOUT_MS || 12000);
const ARM_RETIRE_TIMEOUT_MS = positiveInteger("FM_WATCH_ARM_RETIRE_TIMEOUT_MS", 1000);
const REARM_RETRY_BASE_MS = positiveInteger("FM_WATCH_REARM_RETRY_BASE_MS", 250);
const REARM_RETRY_MAX_MS = positiveInteger("FM_WATCH_REARM_RETRY_MAX_MS", 4000);
const REARM_RETRY_LIMIT = positiveInteger("FM_WATCH_REARM_RETRY_LIMIT", 5);

let child = null;
let armStatus = "idle";
let retryTimer = null;
let retryFailures = 0;
let launchInFlight = null;
let restorationInFlight = null;
let armClose = new WeakMap();
let armReadiness = new WeakMap();

function positiveInteger(name, fallback) {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

function setArmStatus(status) {
  armStatus = status;
}

function waitForArmReady(armChild) {
  const readiness = armReadiness.get(armChild);
  if (!readiness) return Promise.resolve("failed");
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve("timeout"), ARM_READY_TIMEOUT_MS);
    timer.unref();
    void readiness.then((status) => {
      clearTimeout(timer);
      resolve(status);
    });
  });
}

function runProcess(command, args, options = {}) {
  return new Promise((resolve) => {
    const proc = spawn(command, args, {
      stdio: ["ignore", "pipe", "pipe"],
      ...options,
    });
    let stdout = "";
    let stderr = "";
    proc.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    proc.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    proc.on("error", (error) => resolve({ code: 127, stdout, stderr: String(error?.message ?? error) }));
    proc.on("close", (code) => resolve({ code: code ?? 0, stdout, stderr }));
  });
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

function effectivePaths(root) {
  const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || fmRoot;
  const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
  const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
  return { root: fmRoot, home: fmHome, state, config };
}

async function isPrimaryRoot(root, home) {
  if (!root) return false;
  if (!existsSync(`${root}/AGENTS.md`) || !existsSync(`${root}/bin`)) return false;
  if (existsSync(`${root}/.fm-secondmate-home`)) return false;
  if (home && home !== root && existsSync(`${home}/.fm-secondmate-home`)) return false;
  const gitDir = await runProcess("git", ["-C", root, "rev-parse", "--git-dir"]);
  const commonDir = await runProcess("git", ["-C", root, "rev-parse", "--git-common-dir"]);
  if (gitDir.code !== 0 || commonDir.code !== 0) return false;
  return gitDir.stdout.trim() === commonDir.stdout.trim();
}

function shouldArm(paths) {
  if (existsSync(`${paths.state}/.afk`)) return false;
  if (existsSync(`${paths.config}/x-mode.env`)) return true;
  try {
    return readdirSync(paths.state).some((name) => name.endsWith(".meta"));
  } catch {
    return false;
  }
}

// Session-lock ownership (state/.lock: which session controls this home's
// fleet) is resolved by bin/fm-session-lock-lib.sh through `bin/fm-lock.sh
// ownership`, never reimplemented here. The walk runs from the spawned child, so
// this plugin's own process is still one of the ancestors it finds.
//
// A RESOLVER FAILURE is not a verdict. Delegating to a subprocess adds a failure
// mode the previous in-process read could not have: a missing or non-executable
// bin/fm-lock.sh, or a spawn error, would otherwise be indistinguishable from
// "not owned", so supervision would silently never arm with no diagnostic naming
// the real cause. Only a recognised word on stdout is a verdict; anything else
// resolves to "unresolved" and is surfaced with the resolver's own error.
let lastOwnershipError = "";

async function resolveSessionOwnership(paths) {
  const result = await runProcess(`${paths.root}/bin/fm-lock.sh`, ["ownership"], {
    env: { ...process.env, FM_HOME: paths.home, FM_STATE_OVERRIDE: paths.state },
  });
  const verdict = result.stdout.trim();
  if (verdict === "owned" || verdict === "other" || verdict === "missing") return verdict;
  const detail = result.stderr.trim() || `no ownership verdict on stdout${verdict ? `: ${verdict}` : ""}`;
  lastOwnershipError = `${paths.root}/bin/fm-lock.sh ownership failed (exit ${result.code}): ${detail}`;
  return "unresolved";
}

function classifyArmClose(stdout, stderr, code, signal) {
  const combined = `${stdout}\n${stderr}`;
  const reason = combined.split(/\r?\n/).find((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line));
  if (reason) return { kind: "actionable", message: reason };
  // The arm's own session-lock gate can refuse after this plugin's pre-check, if
  // the lock changed in between. That refusal is exit 0 with no actionable line
  // and is correct behavior, so it must never be reported as a watcher failure.
  const readOnly = combined.split(/\r?\n/).find((line) => /^watcher: read-only\b/.test(line));
  if (readOnly) return { kind: "read-only", message: readOnly };
  const healthy = combined.split(/\r?\n/).find((line) => /^watcher: healthy\b/.test(line));
  if (healthy) {
    return {
      kind: "failure",
      message: `watcher: FAILED - OpenCode arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`,
    };
  }
  const failed = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
  if (failed) return { kind: "failure", message: failed };
  if (signal) {
    return {
      kind: "failure",
      message: `watcher: FAILED - OpenCode arm child ended from ${signal}${combined.trim() ? `\n${combined.trim()}` : ""}`,
    };
  }
  if (code && code !== 0) {
    return {
      kind: "failure",
      message: `watcher: FAILED - fm-watch-arm.sh exited ${code}${combined.trim() ? `\n${combined.trim()}` : ""}`,
    };
  }
  return {
    kind: "failure",
    message: "watcher: FAILED - OpenCode arm cycle ended without an actionable reason",
  };
}

function observeArmOutput(stdout, stderr, settleReadiness) {
  const combined = `${stdout}\n${stderr}`;
  if (combined.split(/\r?\n/).some((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line))) {
    setArmStatus("wake");
    settleReadiness("wake");
    return;
  }
  if (combined.split(/\r?\n/).some((line) => /^watcher: (?:started|attached)\b/.test(line))) {
    setArmStatus("armed");
    settleReadiness("armed");
    return;
  }
  if (combined.split(/\r?\n/).some((line) => /^watcher: read-only\b/.test(line))) {
    setArmStatus("read-only");
    settleReadiness("read-only");
    return;
  }
  if (combined.split(/\r?\n/).some((line) => /^watcher: healthy\b/.test(line))) {
    setArmStatus("external");
    settleReadiness("external");
    return;
  }
  if (combined.split(/\r?\n/).some((line) => /^watcher: FAILED/.test(line))) {
    setArmStatus("failed");
    settleReadiness("failed");
  }
}

async function sendPrompt(client, sessionID, text) {
  await client.session.promptAsync({
    path: { id: sessionID },
    body: {
      parts: [
        {
          type: "text",
          text,
        },
      ],
    },
  });
}

function wakePrompt(reason) {
  return `WATCHER FIRED - drain queued wakes with bin/fm-wake-drain.sh and handle the reported wake. Watcher continuity is plugin-owned.\n\n${reason}`;
}

function surfaceFailure(client, sessionID, reason) {
  void sendPrompt(client, sessionID, wakePrompt(reason)).catch(() => {
  });
}

function retryDelay(attempt) {
  return Math.min(REARM_RETRY_MAX_MS, REARM_RETRY_BASE_MS * 2 ** Math.max(0, attempt - 1));
}

function waitForRetry(attempt) {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, retryDelay(attempt));
    timer.unref();
  });
}

async function retireArm(armChild) {
  if (!armChild) return true;
  armChild.kill("SIGTERM");
  const closed = armClose.get(armChild);
  if (!closed) return false;
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(false), ARM_RETIRE_TIMEOUT_MS);
    timer.unref();
    void closed.then(() => {
      clearTimeout(timer);
      resolve(true);
    });
  });
}

function restorationFailure(status) {
  if (status === "read-only") {
    return "watcher: FAILED - OpenCode cannot restore continuity because this session no longer owns the lock";
  }
  if (status === "ownership-unresolved") {
    return `watcher: FAILED - OpenCode could not resolve session-lock ownership, so it did not arm\n${lastOwnershipError || "bin/fm-lock.sh ownership produced no verdict"}`;
  }
  return `watcher: FAILED - OpenCode could not verify a ready successor watcher (${status || "idle"})`;
}

async function restoreAfterActionableClose(paths, sessionID, client, predecessorArmPid) {
  let failure = "";
  for (let attempt = 0; attempt <= REARM_RETRY_LIMIT; attempt += 1) {
    const { status, armChild } = await ensureArm(paths, sessionID, client, predecessorArmPid, true);
    if (status === "armed") return "";
    // An actionable line belongs to this arm's close handler.
    // Do not retire it before that handler can start the successor cycle.
    if (status === "wake") return "";
    failure = restorationFailure(status);
    if (!(await retireArm(armChild))) {
      setArmStatus("failed");
      return `${failure}\nwatcher: FAILED - OpenCode could not restore watcher continuity because the unready successor arm did not exit within ${ARM_RETIRE_TIMEOUT_MS}ms`;
    }
    if (status === "read-only" || status === "not-primary" || status === "skipped") break;
    if (attempt === REARM_RETRY_LIMIT) break;
    await waitForRetry(attempt + 1);
  }
  setArmStatus("failed");
  return `${failure}\nwatcher: FAILED - OpenCode could not restore watcher continuity after ${REARM_RETRY_LIMIT} retries`;
}

async function scheduleRetry(paths, sessionID, client, reason, predecessorArmPid) {
  if (child || retryTimer) return;
  const ownership = await resolveSessionOwnership(paths);
  if (ownership === "unresolved") {
    setArmStatus("failed");
    surfaceFailure(client, sessionID, `${restorationFailure("ownership-unresolved")}\n${reason}`);
    return;
  }
  if (ownership !== "owned") {
    setArmStatus("failed");
    surfaceFailure(client, sessionID, `watcher: FAILED - OpenCode cannot restore continuity because this session no longer owns the lock\n${reason}`);
    return;
  }
  retryFailures += 1;
  if (retryFailures > REARM_RETRY_LIMIT) {
    setArmStatus("failed");
    surfaceFailure(client, sessionID, `watcher: FAILED - OpenCode could not restore watcher continuity after ${REARM_RETRY_LIMIT} retries\n${reason}`);
    return;
  }
  setArmStatus("retrying");
  const timer = setTimeout(() => {
    if (retryTimer === timer) retryTimer = null;
    void ensureArm(paths, sessionID, client, predecessorArmPid).then((status) => {
      if (["armed", "starting", "wake"].includes(status)) return;
      surfaceFailure(client, sessionID, `watcher: FAILED - OpenCode could not launch a continuity retry (${status})`);
    });
  }, retryDelay(retryFailures));
  timer.unref();
  retryTimer = timer;
}

function spawnArm(paths, sessionID, client, predecessorArmPid = "") {
  setArmStatus("starting");
  const env = {
    ...process.env,
    FM_HOME: paths.home,
    FM_ROOT_OVERRIDE: paths.root,
    FM_CONFIG_OVERRIDE: paths.config,
    FM_WATCH_PREDECESSOR_ARM_PID: predecessorArmPid,
  };
  const armChild = spawn("bash", ["-lc", 'config_dir="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"; [ -f "$config_dir/x-mode.env" ] && . "$config_dir/x-mode.env"; exec "$FM_ROOT_OVERRIDE/bin/fm-watch-arm.sh" --restart'], {
    cwd: paths.root,
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  child = armChild;
  let stdout = "";
  let stderr = "";
  let settled = false;
  let resolveClosed = null;
  let readinessSettled = false;
  let resolveReadiness = null;
  const readiness = new Promise((resolve) => {
    resolveReadiness = resolve;
  });
  armReadiness.set(armChild, readiness);
  const settleReadiness = (status) => {
    if (readinessSettled) return;
    readinessSettled = true;
    resolveReadiness(status);
  };
  const closed = new Promise((resolveClosedChild) => {
    resolveClosed = resolveClosedChild;
  });
  armClose.set(armChild, closed);
  const releaseChild = () => {
    if (child === armChild) child = null;
  };
  armChild.stdout.on("data", (chunk) => {
    stdout += chunk.toString();
    observeArmOutput(stdout, stderr, settleReadiness);
  });
  armChild.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
    observeArmOutput(stdout, stderr, settleReadiness);
  });
  armChild.on("close", (code, signal) => {
    if (settled) return;
    settled = true;
    resolveClosed();
    releaseChild();
    const classification = classifyArmClose(stdout, stderr, code, signal);
    settleReadiness(classification.kind === "actionable" ? "wake" : classification.kind === "read-only" ? "read-only" : "failed");
    const predecessor = String(armChild.pid ?? "");
    if (classification.kind === "read-only") {
      // The arm declined for a lock this session does not hold. Retrying would
      // only decline again, and it is not a supervision failure to report.
      setArmStatus("read-only");
      return;
    }
    if (classification.kind === "actionable") {
      retryFailures = 0;
      setArmStatus("wake");
      const previousRestoration = restorationInFlight;
      const restoration = previousRestoration
        ? previousRestoration.catch(() => "").then(() => restoreAfterActionableClose(paths, sessionID, client, predecessor))
        : restoreAfterActionableClose(paths, sessionID, client, predecessor);
      restorationInFlight = restoration;
      void restoration.then((failure) => {
        if (restorationInFlight === restoration) restorationInFlight = null;
        const message = failure ? `${classification.message}\n\n${failure}` : classification.message;
        return sendPrompt(client, sessionID, wakePrompt(message));
      }).catch(() => {
      });
      return;
    }
    if (restorationInFlight) {
      setArmStatus("failed");
      return;
    }
    void scheduleRetry(paths, sessionID, client, classification.message, predecessor);
  });
  armChild.on("error", (error) => {
    if (settled) return;
    settled = true;
    resolveClosed();
    releaseChild();
    settleReadiness("failed");
    if (restorationInFlight) {
      setArmStatus("failed");
      return;
    }
    void scheduleRetry(
      paths,
      sessionID,
      client,
      `watcher: FAILED - OpenCode arm child failed: ${error.message}`,
      String(armChild.pid ?? ""),
    );
  });
  return armChild;
}

async function beginArm(paths, sessionID, client, predecessorArmPid) {
  if (!sessionID) return { status: "skipped", armChild: null };
  if (!(await isPrimaryRoot(paths.root, paths.home))) return { status: "not-primary", armChild: null };
  const ownership = await resolveSessionOwnership(paths);
  if (ownership === "unresolved") return { status: "ownership-unresolved", armChild: null };
  if (ownership !== "owned") return { status: "read-only", armChild: null };
  if (child) return { status: "existing", armChild: child };
  if (retryTimer) return { status: "retrying", armChild: null };
  if (!shouldArm(paths)) return { status: "not-needed", armChild: null };
  return { status: "spawned", armChild: spawnArm(paths, sessionID, client, predecessorArmPid) };
}

function armAttempt(status, armChild, includeArmChild) {
  return includeArmChild ? { status, armChild } : status;
}

// Coalescing onto an in-flight launch is only sound when that launch answered the
// same lock-ownership precondition this call has. `beginArm` refuses with
// "read-only" when the session did not own the fleet lock, and that refusal is a
// snapshot of the lock at the moment it was taken, not a standing answer. Serving
// it to a call made AFTER the session acquired the lock silently denies arming for
// that event, and nothing on this path retries, so supervision stays off while every
// surface reports fine. A refusal that the current lock state contradicts is
// therefore re-launched once against that current state instead of being reused.
async function ensureArm(paths, sessionID, client, predecessorArmPid = "", includeArmChild = false) {
  let launchResult = null;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    if (!launchInFlight) {
      const launch = beginArm(paths, sessionID, client, predecessorArmPid);
      launchInFlight = launch;
      try {
        launchResult = await launch;
      } finally {
        if (launchInFlight === launch) launchInFlight = null;
      }
      break;
    }
    launchResult = await launchInFlight;
    if (launchResult.status !== "read-only") break;
    if ((await resolveSessionOwnership(paths)) !== "owned") break;
  }
  const armChild = launchResult.armChild;
  if (!armChild) {
    return armAttempt(launchResult.status, null, includeArmChild);
  }
  return armAttempt(await waitForArmReady(armChild), armChild, includeArmChild);
}

export const FmPrimaryWatchArm = async ({ client, directory, worktree }) => {
  const root = worktree ? resolvePath(worktree) : await resolveRoot(directory);
  const paths = effectivePaths(root);
  globalThis[COORDINATOR_KEY] = {
    ensureArmed: (sessionID, activeClient) => ensureArm(paths, sessionID, activeClient ?? client),
  };

  return {
    event: async ({ event }) => {
      if (event.type !== "session.idle") return;
      const sessionID = event.properties?.sessionID;
      if (!sessionID) return;
      void ensureArm(paths, sessionID, client);
    },
  };
};
