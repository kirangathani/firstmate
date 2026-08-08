#!/usr/bin/env node
// fm-flow-tui.mjs - the fleet pipeline view's renderer.
//
// Reads an fm-flow-snapshot.v1 document on stdin and draws one horizontal row
// per agent. docs/flow-tui.md owns the wire format and the design reasoning;
// this header owns the flags.
//
// Usage:
//   fm-flow-snapshot.sh --json | fm-flow-tui.mjs [--cols N] [--rows N] [--tick N]
//   fm-flow-snapshot.sh --json | fm-flow-tui.mjs --watch
//
//   --cols N   terminal width to render for (default: the tty's, else 130)
//   --rows N   terminal height to render for (default: the tty's, else 45)
//   --tick N   animation frame to draw, fixed. Makes one-shot output
//              deterministic, which is what allows byte-exact frame tests.
//   --watch    live mode: alternate screen, raw-mode keys, diff repaint.
//
// This program shells out to NOTHING. Every fact it draws arrives in the JSON.
// That is what makes byte-exact frame tests possible: the renderer cannot
// reach past its input to change what it draws.
//
// Exit codes: 0 a frame was emitted, 1 stdin was not a readable snapshot,
// 2 usage error.

const ESC = "\x1b[";
const R = `${ESC}0m`;

// Colour policy: use the terminal's OWN palette slots, never absolute RGB.
// `\x1b[92m` means "this theme's bright green", so the view re-skins itself
// when the captain changes terminal theme. Hardcoded 256-colour values stay
// neon against a muted palette and stop matching the moment the theme changes.
const sgr = (codes) => (s) => `${ESC}${codes}m${s}${R}`;
const dim = sgr("2");
const green = sgr("92");
const greenBold = sgr("1;92");
const yellow = sgr("93");
const red = sgr("91");
const cyan = sgr("96");
const white = sgr("97");
const magenta = sgr("95");

// The marching trail. Hard rule, learned by looking at it against the
// captain's skin: NO cell of the trail may be darker than the border it runs
// along, or it reads as a hole punched in the box rather than a trail behind a
// head. That rules out slot 32 and every dim variant. The palette offers one
// bright green and one foreground, so length comes from holding each step
// across several cells rather than from more hues.
const TAIL = ["1;92", "1;92", "92", "92", "92", "1;97", "97"].map(sgr);

const STEPS = [
  { key: "intent", label: "intent" },
  { key: "rebase", label: "rebase" },
  { key: "review", label: "review" },
  { key: "test", label: "test" },
  { key: "document", label: "docs" },
  { key: "lint", label: "lint" },
  { key: "pr", label: "push+PR", folds: ["push", "pr"] },
];
const W = 9;
const CIW = 13;
const MW = 9;
const NCELLS = STEPS.length + 2;
const BLOCK = 6;

// --- display-state model ----------------------------------------------------
//
// Motion is a claim about autonomy: it says the system is progressing WITHOUT
// the captain. It is shown only for `live`. Animating a stage that is blocked
// on the captain would tell them work is happening when the thing it waits for
// is them, and a failed stage has stopped, so neither gets motion.
//
// Every status no-mistakes can emit maps to exactly one state here. An
// unrecognised status maps to `unknown`, NEVER to `pending`: pending reads as
// "not started yet", which is a different and unearned claim.
//
// `skipped` gets its own state rather than folding into `done` or `pending`.
// A gate that was deliberately skipped is neither finished nor unreached, and
// firstmate discloses skips at merge, so the view must not hide one.
const STATE_BY_STATUS = new Map([
  ["running", "live"],
  ["fixing", "live"],
  ["awaiting_approval", "waiting"],
  ["fix_review", "waiting"],
  ["completed", "done"],
  ["failed", "failed"],
  ["cancelled", "failed"],
  ["pending", "pending"],
  ["skipped", "skipped"],
]);

export function stepState(status) {
  if (status == null || status === "") return "pending";
  return STATE_BY_STATUS.get(status) ?? "unknown";
}

const PAINT = {
  live: white,
  done: white,
  waiting: yellow,
  failed: red,
  pending: dim,
  skipped: dim,
  unknown: magenta,
};

export function dur(ms) {
  if (ms == null) return "";
  if (ms < 1000) return `${ms}ms`;
  const s = ms / 1000;
  if (s < 60) return `${s.toFixed(1)}s`;
  const m = Math.floor(s / 60);
  const r = Math.round(s % 60);
  if (m < 60) return `${m}m${String(r).padStart(2, "0")}s`;
  return `${Math.floor(m / 60)}h${String(m % 60).padStart(2, "0")}m`;
}

function pad(s, w) {
  if (s.length >= w) return s.slice(0, w);
  const left = Math.floor((w - s.length) / 2);
  return " ".repeat(left) + s + " ".repeat(w - s.length - left);
}

// Border cells of a 3-row box, clockwise from the top-left, so a marching
// highlight can walk them in order.
function perimeter(w) {
  const cells = [];
  for (let c = 0; c < w + 2; c++) cells.push(`0,${c}`);
  cells.push(`1,${w + 1}`);
  for (let c = w + 1; c >= 0; c--) cells.push(`2,${c}`);
  cells.push("1,0");
  return cells;
}

// ONE renderer for step boxes, the CI container, and pre-merge, so they cannot
// drift apart in how they signal the same thing.
function box(label, state, width, opts = {}) {
  const { dashed = false, badge = false, timer = "", anim = 0 } = opts;
  const base = PAINT[state] ?? dim;
  const [tl, tr, bl, br, hz, vt] = dashed
    ? ["+", "+", "+", "+", "-", ":"]
    : ["┌", "┐", "└", "┘", "─", "│"];

  const grid = [
    (tl + hz.repeat(width) + tr).split(""),
    (vt + pad(label, width) + vt).split(""),
    (bl + hz.repeat(width) + br).split(""),
  ];
  if (badge) grid[0][width] = "*";

  const hi = new Map();
  if (state === "live") {
    const per = perimeter(width);
    const head = anim % per.length;
    TAIL.forEach((fn, i) => hi.set(per[(head - i + per.length) % per.length], fn));
  }

  const row = (r) =>
    grid[r].map((ch, c) => (hi.get(`${r},${c}`) ?? base)(ch)).join("");

  return { top: row(0), mid: row(1), bot: row(2), timer: pad(timer, width + 2) };
}

// A run whose worker is gone cannot be reported as live, however the database
// still describes it. Nothing updates a dead run's row, so it stays `running`
// forever; drawing motion there would animate a pipeline that stopped days ago.
function liveIsCredible(agent) {
  return agent.endpoint_alive !== false;
}

function stepFor(agent, spec) {
  const byKey = new Map((agent.steps ?? []).map((s) => [s.step, s]));
  if (!spec.folds) return byKey.get(spec.key);
  // push and pr are folded into one box: both are seconds and neither is a
  // gate. The fold shows the least-advanced of the two, so the box cannot
  // claim completion while half of it is still pending.
  const parts = spec.folds.map((k) => byKey.get(k)).filter(Boolean);
  if (parts.length === 0) return undefined;
  const rank = { failed: 0, unknown: 1, waiting: 2, live: 3, pending: 4, skipped: 5, done: 6 };
  const worst = parts.slice().sort(
    (a, b) => rank[stepState(a.status)] - rank[stepState(b.status)],
  )[0];
  return {
    ...worst,
    duration_ms: parts.reduce((t, p) => t + (p.duration_ms ?? 0), 0),
    findings: parts.reduce((t, p) => t + (p.findings ?? 0), 0),
  };
}

function stepBox(agent, spec, anim) {
  if (agent.collection?.ok === false) {
    return box(spec.label, "unknown", W, { timer: "?" });
  }
  const st = stepFor(agent, spec);
  let state = stepState(st?.status ?? "pending");
  if (state === "live" && !liveIsCredible(agent)) state = "unknown";

  let timer = "";
  if (state === "failed") timer = "FAIL";
  else if (state === "waiting") timer = st?.findings ? `${st.findings} find` : "parked";
  else if (state === "live") timer = "running";
  else if (state === "done") timer = dur(st?.duration_ms);
  else if (state === "skipped") timer = "skipped";
  else if (state === "unknown") timer = st ? "stale" : "?";

  const b = box(spec.label, state, W, { timer, anim });
  return { ...b, timer: timer ? (PAINT[state] ?? dim)(b.timer) : b.timer };
}

// CI green does NOT mean ready to merge: the pre-merge gate only runs when a
// merge is attempted. So a fully green run parks HERE, amber, asking for the
// captain's word, rather than advancing into a stage nothing has started.
function ciBox(agent, anim) {
  const ci = agent.ci;
  if (!ci || ci.collection?.ok === false) {
    // No PR yet is a real "not reached". Having a PR whose checks were not
    // collected is NOT: drawing it dim would claim CI has not started when the
    // truth is that nobody looked.
    if (!agent.pr?.url) return box("GITHUB CI", "pending", CIW, { dashed: true });
    const b = box("GITHUB CI", "unknown", CIW, { dashed: true, timer: "not read" });
    return { ...b, timer: magenta(b.timer) };
  }
  const { passed = 0, total = 0, failed = 0, pending = 0 } = ci;
  if (failed > 0) {
    const b = box("GITHUB CI", "failed", CIW, { dashed: true, timer: `${passed}/${total} FAIL` });
    return { ...b, timer: red(b.timer) };
  }
  if (pending > 0) {
    const state = liveIsCredible(agent) ? "live" : "unknown";
    const b = box("GITHUB CI", state, CIW, {
      dashed: true,
      timer: `${passed}/${total} running`,
      anim,
    });
    return { ...b, timer: (PAINT[state] ?? dim)(b.timer) };
  }
  if (total === 0) return box("GITHUB CI", "pending", CIW, { dashed: true });
  const b = box("GITHUB CI", "waiting", CIW, { dashed: true, timer: `${passed}/${total} - your word` });
  return { ...b, timer: yellow(b.timer) };
}

// The final box is the pre-merge check: the base branch's own assertions run
// against this branch. It cannot show a verdict before the captain acts,
// because it does not run until a merge is attempted.
function premergeBox() {
  return box("pre-merge", "pending", MW);
}

function agentBlock(agent, n, selected, cell, anim) {
  const cells = STEPS.map((s) => stepBox(agent, s, anim));
  cells.push(ciBox(agent, anim));
  cells.push(premergeBox());

  // Selection is reverse video, deliberately NOT green: green already means
  // "the agent is here" and must keep exactly one meaning.
  if (selected && cell >= 0 && cell < cells.length) {
    const c = cells[cell];
    const mark = (s) => `${ESC}7m${s.replace(/\x1b\[[0-9;]*m/g, "")}${R}`;
    cells[cell] = { top: mark(c.top), mid: mark(c.mid), bot: mark(c.bot), timer: c.timer };
  }

  const arrow = dim("────→");
  const gap = "     ";
  const top = [], mid = [], bot = [], tim = [];
  cells.forEach((c, i) => {
    if (i > 0) { top.push(gap); mid.push(arrow); bot.push(gap); tim.push(gap); }
    top.push(c.top); mid.push(c.mid); bot.push(c.bot); tim.push(c.timer);
  });

  const onHead = selected && cell < 0;
  const marker = selected ? greenBold("▸") : " ";
  const name = onHead
    ? `${ESC}7m Agent ${n}  ${agent.id} ${R}`
    : `${cyan(`Agent ${n}`)}  ${white(agent.id)}`;
  const notes = [];
  if (agent.collection?.ok === false) notes.push(magenta(`unreadable: ${agent.collection.reason}`));
  else if (agent.endpoint_alive === false) notes.push(magenta("worker gone"));
  const head =
    `${marker} ${name}  ${dim(shortProject(agent.project))}` +
    (notes.length ? `  ${notes.join("  ")}` : "") +
    (onHead ? `  ${dim("enter: open this worker's pane")}` : "");

  return [head, "  " + top.join(""), "  " + mid.join(""), "  " + bot.join(""), "  " + tim.join("")];
}

function shortProject(p) {
  if (!p) return "";
  const parts = String(p).split("/").filter(Boolean);
  return parts[parts.length - 1] ?? "";
}

const visLen = (s) => s.replace(/\x1b\[[0-9;]*m/g, "").length;

export function render(snap, opts) {
  const { rows, cols, anim = 0, sel = 0, cell = -1, top: topIn = 0, flash = "" } = opts;
  const agents = snap.agents ?? [];
  const out = [];

  // The data age must be honest and prominent. A green box that is thirty
  // seconds stale is a lie the captain has no way to detect.
  const ageSec = opts.ageSeconds ?? 0;
  const needs = agents.filter((a) => a.ci && a.ci.pending === 0 && a.ci.failed === 0 && a.ci.total > 0).length;
  const broken = agents.filter((a) => a.collection?.ok === false).length;
  out.push(
    `${white("fleet pipeline")}  ${dim(`${agents.length} agents`)}  ${dim("·")}  ` +
      `${needs ? yellow(`${needs} ready to merge`) : dim("0 ready to merge")}  ${dim("·")}  ` +
      (broken ? magenta(`${broken} unreadable`) : dim("0 unreadable")) +
      `  ${dim(`· updated ${ageSec}s ago`)}`,
  );

  const probe = agents.length ? agentBlock(agents[0], 1, false, -1, anim)[2] : "";
  const rule = dim("─".repeat(Math.max(1, Math.min(cols - 1, visLen(probe) || 40))));
  out.push(rule);

  if (agents.length === 0) {
    out.push(dim("  no agents in flight"));
    out.push(rule);
    return out;
  }

  const chrome = 4;
  const visible = Math.max(1, Math.floor((rows - chrome) / BLOCK));
  let top = topIn;
  if (sel < top) top = sel;
  if (sel >= top + visible) top = sel - visible + 1;
  agents.slice(top, top + visible).forEach((a, i) => {
    out.push(...agentBlock(a, top + i + 1, top + i === sel, cell, anim));
    out.push("");
  });

  out.push(rule);
  const more = agents.length - (top + visible);
  const scroll = (top > 0 ? `^${top} above  ` : "") + (more > 0 ? `v${more} below  ` : "");
  out.push(
    (scroll ? green(scroll) : "") +
      dim("up/down agent   left/right stage   enter open   q quit"),
  );
  if (flash) out.push(yellow(flash));
  return out;
}

// --- entry point ------------------------------------------------------------

function parseArgs(argv) {
  const o = { watch: false, cols: null, rows: null, tick: 0 };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--watch") o.watch = true;
    else if (a === "--cols") o.cols = Number(argv[++i]);
    else if (a === "--rows") o.rows = Number(argv[++i]);
    else if (a === "--tick") o.tick = Number(argv[++i]);
    else if (a === "-h" || a === "--help") o.help = true;
    else { o.bad = a; }
  }
  return o;
}

function readStdin() {
  return new Promise((resolve, reject) => {
    let buf = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (d) => (buf += d));
    process.stdin.on("end", () => resolve(buf));
    process.stdin.on("error", reject);
  });
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    process.stdout.write(
      "usage: fm-flow-snapshot.sh --json | fm-flow-tui.mjs [--cols N] [--rows N] [--tick N] [--watch]\n",
    );
    return 0;
  }
  if (opts.bad) {
    process.stderr.write(`fm-flow-tui: unknown argument ${opts.bad}\n`);
    return 2;
  }

  const raw = await readStdin();
  let snap;
  try {
    snap = JSON.parse(raw);
  } catch {
    process.stderr.write("fm-flow-tui: stdin is not valid JSON\n");
    return 1;
  }
  if (snap?.schema !== "fm-flow-snapshot.v1") {
    process.stderr.write(
      `fm-flow-tui: expected schema fm-flow-snapshot.v1, got ${snap?.schema ?? "none"}\n`,
    );
    return 1;
  }

  const cols = opts.cols ?? process.stdout.columns ?? 130;
  const rows = opts.rows ?? process.stdout.rows ?? 45;

  if (!opts.watch) {
    const age = snap.generated_epoch
      ? Math.max(0, Math.floor(Date.now() / 1000) - snap.generated_epoch)
      : 0;
    const frame = render(snap, {
      rows,
      cols,
      anim: opts.tick,
      ageSeconds: opts.tick ? 0 : age,
    });
    process.stdout.write(frame.join("\n") + "\n");
    return 0;
  }

  return watch(snap, cols, rows);
}

function watch(snap, cols0, rows0) {
  let sel = 0, cell = -1, anim = 0, flash = "";
  const startedAt = Date.now();
  const w = () => process.stdout.columns || cols0;
  const h = () => process.stdout.rows || rows0;

  process.stdout.write("\x1b[?1049h\x1b[2J\x1b[?25l");
  const quit = () => {
    process.stdout.write("\x1b[?25h\x1b[?1049l");
    process.exit(0);
  };

  // Flicker-free repaint. The big one first: NEVER clear the screen. `\x1b[2J`
  // blanks the pane and the redraw is a separate operation, so the terminal
  // briefly shows an empty frame - that gap IS the flicker. Instead each row is
  // overwritten in place, `\x1b[K` erases only that line's tail, only CHANGED
  // rows are emitted, and the whole frame goes out in ONE write so the terminal
  // never paints a half-updated screen. DECSET 2026 asks it to hold
  // presentation until the frame is complete; terminals that do not know it
  // ignore it.
  let prev = [];
  const paint = () => {
    const next = render(snap, {
      rows: h(),
      cols: w(),
      anim,
      sel,
      cell,
      flash,
      ageSeconds: Math.floor((Date.now() - startedAt) / 1000),
    });
    let buf = "\x1b[?2026h";
    const n = Math.max(prev.length, next.length);
    for (let i = 0; i < n; i++) {
      const line = next[i] ?? "";
      if (prev[i] === line) continue;
      buf += `\x1b[${i + 1};1H` + line + "\x1b[K";
    }
    buf += "\x1b[?2026l";
    process.stdout.write(buf);
    prev = next;
  };

  if (process.stdin.isTTY) {
    process.stdin.setRawMode(true);
    process.stdin.resume();
    process.stdin.on("data", (b) => {
      const k = b.toString();
      const count = (snap.agents ?? []).length;
      if (k === "q" || k === "\x03") quit();
      if (k === "j" || k === "\x1b[B") sel = Math.min(count - 1, sel + 1);
      if (k === "k" || k === "\x1b[A") sel = Math.max(0, sel - 1);
      if (k === "l" || k === "\x1b[C") cell = Math.min(NCELLS - 1, cell + 1);
      if (k === "h" || k === "\x1b[D") cell = Math.max(-1, cell - 1);
      if (k === "\r" || k === "\n") {
        // Focusing a worker's pane needs a backend verb that does not exist
        // yet, so this states the fact rather than hardcoding tmux and
        // breaking every other runtime.
        flash = "opening a worker's pane is not wired up yet";
      }
      paint();
    });
  }

  // The border chase needs a frame rate the eye reads as motion; the data
  // behind it does not. Two timers, so a smooth animation never implies the
  // underlying state is polled eight times a second.
  setInterval(() => { anim = (anim + 1) % 10000; paint(); }, 110);
  setInterval(paint, 1000);
  paint();
  return new Promise(() => {});
}

const invokedDirectly =
  process.argv[1] && import.meta.url === `file://${process.argv[1]}`;
if (invokedDirectly) {
  main().then((code) => process.exit(code ?? 0));
}
