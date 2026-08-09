#!/usr/bin/env node
// fm-flow-tui.mjs - the fleet pipeline view's renderer.
//
// Reads an fm-flow-snapshot.v1 document on stdin and draws one horizontal row
// per agent. docs/flow-tui.md owns the wire format and the design reasoning;
// this header owns the flags.
//
// Usage:
//   bin/fm-flow.sh                                    (the captain-facing entry point)
//   fm-flow-snapshot.sh --json | fm-flow-tui.mjs [--cols N] [--rows N] [--tick N]
//   fm-flow-snapshot.sh --json | fm-flow-tui.mjs --watch [--refresh-cmd CMD]
//
//   --cols N          terminal width to render for (default: the tty's, else 130)
//   --rows N          terminal height to render for (default: the tty's, else 45)
//   --tick N          animation frame to draw, fixed. Passing it also pins the
//                     stated data age to 0, so one-shot output is deterministic,
//                     which is what allows byte-exact frame tests.
//   --watch           live mode: alternate screen, raw-mode keys, diff repaint.
//   --refresh-cmd C   watch only. Shell command re-run every --refresh-ms whose
//                     stdout must be a fresh snapshot. OPT-IN, no default.
//   --refresh-ms N    watch only, default 10000. Snapshot re-read cadence. Only
//                     one refresh runs at a time, so a collector slower than
//                     this sets the real cadence and the interval never stacks.
//   --open-cmd C      watch only. Shell command run when the captain presses
//                     enter on an agent, with FM_FLOW_ID, FM_FLOW_WINDOW,
//                     FM_FLOW_WORKTREE, FM_FLOW_PROJECT and FM_FLOW_PR in its
//                     environment. OPT-IN, no default. The viewer SUSPENDS for
//                     it - alternate screen off, raw mode off, the controlling
//                     terminal handed over on stdin and stdout - so the command
//                     may itself be a full-screen program such as `tmux
//                     attach`, and the view is restored when it returns.
//   --open-hint T     watch only. What the selected agent's row says enter will
//                     do. The caller owns this text because the caller owns
//                     --open-cmd, and only it knows what that command does to
//                     the captain's terminal or how to get back. Default:
//                     "enter: open this worker's window".
//
// THE TWO CHANNELS ARE SEPARATE, AND THAT IS THE WHOLE POINT.
// The snapshot arrives on stdin, so stdin is a PIPE and can never be a
// keyboard. Keystrokes are therefore read from the controlling terminal
// directly, /dev/tty, which is a different file descriptor from stdin. The
// shipped version armed its key handler behind `process.stdin.isTTY`, which is
// false for every invocation that has data, so no key ever reached it.
//
// This program shells out to NOTHING unless the operator hands it an explicit
// command with --refresh-cmd or --open-cmd, and never in one-shot mode. That
// is what keeps byte-exact frame tests possible: `render()` is a pure function
// of the snapshot plus the frame options, and the default renderer cannot
// reach past its input to change what it draws.
//
// Exit codes: 0 a frame was emitted, 1 stdin was not a readable snapshot,
// 2 usage error.

import fs from "node:fs";
import tty from "node:tty";
import { execFile, spawnSync } from "node:child_process";

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

// The ellipsis is ONE column wide, on purpose. A three-dot "..." costs three of
// the columns it is trying to buy back, and in a 15-column cell that is a fifth
// of the value.
const ELLIPSIS = "…";

// Shorten to `w` columns VISIBLY, and say so. A cell that quietly drops its
// tail produced the captain's `11/11 - your wo`: unreadable, and indis-
// tinguishable from a value that really is that short. Nothing in this frame
// may cut text without leaving the mark that says it was cut.
//
// Callers must still choose text that fits. This is the floor under them, not
// the layout: an ellipsis is a deliberate shortening, which is better than a
// silent one and worse than a phrase that fits.
export function fit(s, w) {
  const str = String(s ?? "");
  if (!Number.isFinite(w) || w <= 0) return "";
  if (str.length <= w) return str;
  if (w === 1) return ELLIPSIS;
  return str.slice(0, w - 1) + ELLIPSIS;
}

function pad(s, w) {
  const t = fit(s, w);
  if (t.length >= w) return t;
  const left = Math.floor((w - t.length) / 2);
  return " ".repeat(left) + t + " ".repeat(w - t.length - left);
}

const ANSI = /\x1b\[[0-9;]*m/g;
// Sticky, and deliberately its own object: it carries a mutable lastIndex, and
// sharing that with the global ANSI above would couple two scanners through
// one piece of hidden state for no gain.
const ANSI_AT = /\x1b\[[0-9;]*m/y;
export const visLen = (s) => s.replace(ANSI, "").length;

// Cut a coloured line to `cols` VISIBLE columns. Escape sequences are zero
// width and must survive the cut, and a cut that lands mid-colour has to close
// it or the colour bleeds across the rest of the terminal line.
//
// This is the last line of defence, not the layout: a line that reaches here
// over-wide has already lost. It matters because a single over-wide line
// WRAPS, and a wrapped line desynchronises every absolute cursor address in
// the diff repaint below - which is how the shipped version produced both
// half-drawn boxes on the right and an orphaned row of durations under the
// header.
//
// A line it does cut ends in the ellipsis, in the last visible column, for the
// same reason fit() does: a free-text line - an agent id, a project, a refresh
// error - that simply stops mid-word reads as a rendering fault rather than as
// a line too long for the terminal.
export function clip(line, cols) {
  if (!Number.isFinite(cols) || cols <= 0) return line;
  if (visLen(line) <= cols) return line;
  const keep = Math.max(0, Math.floor(cols) - 1);
  let out = "";
  let vis = 0;
  let i = 0;
  while (i < line.length && vis < keep) {
    ANSI_AT.lastIndex = i;
    const m = ANSI_AT.exec(line);
    if (m) {
      out += m[0];
      i = ANSI_AT.lastIndex;
      continue;
    }
    out += line[i];
    vis++;
    i++;
  }
  return out + ELLIPSIS + R;
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

// --- horizontal layout ------------------------------------------------------
//
// Nine cells at their full spacing need 143 columns. The shipped renderer drew
// all 143 whatever `--cols` said, so on the captain's terminal the tail of
// every row wrapped onto the row below and the right-hand column arrived as
// fragments. A frame must fit the terminal it is drawn on.
//
// Two levers, in order, because losing a stage is worse than losing whitespace:
//   1. tighten the arrow gutter (5 -> 3 -> 1) until all nine cells fit;
//   2. only if even the tightest spacing overflows, show a contiguous WINDOW of
//      cells and say so in the header.
// Either way every cell that is drawn is drawn whole. There is no third option
// where a box is cut in half.
const GAPS = [5, 3, 1];
const CELL_WIDTHS = [...STEPS.map(() => W + 2), CIW + 2, MW + 2];
const INDENT = 2;

const span = (first, count, gap) =>
  CELL_WIDTHS.slice(first, first + count).reduce((a, b) => a + b, 0) +
  gap * Math.max(0, count - 1);

export function layout(cols, focus = 0) {
  const avail = Math.max(1, Math.floor(cols) - INDENT);
  const n = CELL_WIDTHS.length;

  for (const gap of GAPS) {
    const total = span(0, n, gap);
    if (total <= avail) return { gap, first: 0, count: n, width: INDENT + total };
  }

  const gap = GAPS[GAPS.length - 1];
  const fitFrom = (first) => {
    let used = 0;
    let count = 0;
    for (let i = first; i < n; i++) {
      const add = (count === 0 ? 0 : gap) + CELL_WIDTHS[i];
      if (used + add > avail) break;
      used += add;
      count++;
    }
    // A terminal too narrow for even one cell still gets one whole cell and
    // lets clip() take the overflow, because half a box is not information.
    return count > 0 ? { count, used } : { count: 1, used: CELL_WIDTHS[first] };
  };

  const want = Math.max(0, Math.min(n - 1, Math.floor(focus)));
  let first = 0;
  for (;;) {
    const f = fitFrom(first);
    if (want < first + f.count || first >= n - 1) {
      return { gap, first, count: f.count, width: INDENT + f.used };
    }
    first++;
  }
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
  // "N/N your word" is 15 columns at two-digit counts, which is exactly the
  // timer field under a 13-wide box. The dash this phrase used to carry cost
  // two more and pushed it over, which is how it reached the captain as
  // `11/11 - your wo`. fit() still guards the three-digit case; the phrase is
  // chosen so the guard does not have to fire on a real fleet.
  const b = box("GITHUB CI", "waiting", CIW, { dashed: true, timer: `${passed}/${total} your word` });
  return { ...b, timer: yellow(b.timer) };
}

// The final box is the pre-merge check: the base branch's own assertions run
// against this branch. It cannot show a verdict before the captain acts,
// because it does not run until a merge is attempted.
function premergeBox() {
  return box("pre-merge", "pending", MW);
}

const DEFAULT_OPEN_HINT = "enter: open this worker's window";

function agentBlock(agent, n, selected, cell, anim, lay, openHint) {
  const cells = STEPS.map((s) => stepBox(agent, s, anim));
  cells.push(ciBox(agent, anim));
  cells.push(premergeBox());

  // Selection is reverse video, deliberately NOT green: green already means
  // "the agent is here" and must keep exactly one meaning.
  if (selected && cell >= 0 && cell < cells.length) {
    const c = cells[cell];
    const mark = (s) => `${ESC}7m${s.replace(ANSI, "")}${R}`;
    cells[cell] = { top: mark(c.top), mid: mark(c.mid), bot: mark(c.bot), timer: c.timer };
  }

  const shown = cells.slice(lay.first, lay.first + lay.count);
  const arrowGlyph = "─".repeat(Math.max(0, lay.gap - 1)) + "→";
  const arrow = dim(arrowGlyph);
  const gap = " ".repeat(lay.gap);
  const top = [], mid = [], bot = [], tim = [];
  shown.forEach((c, i) => {
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
  // The hint rides the SELECTED agent whatever cell is highlighted, because
  // enter is agent-scoped: it opens the worker, and no cell has an action of
  // its own. It used to appear only while the head itself was selected, so
  // stepping right onto GITHUB CI left the captain with a highlighted cell and
  // nothing on screen saying what enter would do to it.
  const head =
    `${marker} ${name}  ${dim(shortProject(agent.project))}` +
    (notes.length ? `  ${notes.join("  ")}` : "") +
    (selected ? `  ${dim(openHint || DEFAULT_OPEN_HINT)}` : "");

  return [head, "  " + top.join(""), "  " + mid.join(""), "  " + bot.join(""), "  " + tim.join("")];
}

function shortProject(p) {
  if (!p) return "";
  const parts = String(p).split("/").filter(Boolean);
  return parts[parts.length - 1] ?? "";
}

// How many agent blocks fit, and the exact frame that follows from that.
//
// The window, the header and the rows have to be derived from ONE number or
// they disagree, and a disagreement here is not cosmetic: an over-tall frame
// scrolls the terminal, every absolute cursor address in the repaint below
// then points one row too high, and last frame's durations survive under the
// header with no boxes above them. That was the orphaned timing row.
// A block is BLOCK lines: 5 of content plus one blank. `chrome` is the header,
// the two rules, the key hint, and the flash line when one is showing, so the
// whole frame is exactly chrome + visible * BLOCK lines.
export function visibleRows(rows, chrome) {
  return Math.max(1, Math.floor((rows - chrome) / BLOCK));
}

// The header, the two rules, the key hints, and the flash line when one is up.
// One owner, because visibleRows() and the caller that keeps `top` between
// frames must agree to the row about how much room the agents get.
export const chromeRows = (flash) => 4 + (flash ? 1 : 0);

// Where the window starts, given where it started LAST frame.
//
// The rule the captain asked for: up and down move the SELECTOR between agent
// rows, and the window moves only when the selector would otherwise leave it -
// already on the top row and pressing up, already on the bottom row and
// pressing down. Anywhere in between the window stands still.
//
// That rule needs `top` to persist across frames, and it did not. The viewer
// passed no top at all, so every frame recomputed one from `sel` alone against
// a default of 0, which pins the selector to the bottom row of the window
// forever: scrolling back up then dragged the whole window with it even though
// the selector had rows above it to move through. Holding `top` between frames
// is the fix; this function is where it is held to the rule.
export function resolveTop(top, sel, visible, count) {
  const maxTop = Math.max(0, count - visible);
  let t = Number.isFinite(top) ? Math.max(0, Math.min(Math.floor(top), maxTop)) : 0;
  if (sel < t) t = sel;
  else if (sel >= t + visible) t = sel - visible + 1;
  return Math.max(0, Math.min(t, maxTop));
}

// A status header that does not fit is worse than a shorter one: clipping cuts
// the RIGHTMOST segment, and the rightmost segment is the data age, the one
// fact the view exists to keep honest. So segments are dropped by stated
// priority and the survivors keep their reading order. A count that is zero is
// the first thing to go; a count that is not, and the stage window, are not
// droppable while anything less important is still on the line.
const HEADER_JOIN_WIDTH = 5;

export function headerLine(segs, cols) {
  const join = `  ${dim("·")}  `;
  const limit = Number.isFinite(cols) && cols > 0 ? cols : Infinity;
  const keep = new Set([0]);
  let width = visLen(segs[0].s);
  const byPriority = segs
    .map((seg, i) => ({ ...seg, i }))
    .slice(1)
    .sort((a, b) => a.pri - b.pri || a.i - b.i);
  for (const seg of byPriority) {
    if (!seg.s) continue;
    const add = HEADER_JOIN_WIDTH + visLen(seg.s);
    if (width + add > limit) continue;
    width += add;
    keep.add(seg.i);
  }
  return segs.filter((seg, i) => keep.has(i) && seg.s).map((seg) => seg.s).join(join);
}

export function render(snap, opts) {
  const {
    rows, cols, anim = 0, sel = 0, cell = -1, top: topIn = 0,
    flash = "", note = "", openHint = "",
  } = opts;
  const agents = snap.agents ?? [];
  const lay = layout(cols, cell < 0 ? 0 : cell);
  const out = [];

  // The data age must be honest and prominent. A green box that is thirty
  // seconds stale is a lie the captain has no way to detect.
  const ageSec = opts.ageSeconds ?? 0;
  const needs = agents.filter((a) => a.ci && a.ci.pending === 0 && a.ci.failed === 0 && a.ci.total > 0).length;
  const broken = agents.filter((a) => a.collection?.ok === false).length;
  // Records the collector held back because nothing is running behind them.
  // Stated, never drawn: they are not agents, so counting them in "N agents"
  // or giving them a row would put a finished worker on screen beside live
  // ones. Saying how many were held back is what keeps the omission honest.
  const hidden = (snap.omitted ?? []).length;
  // Live workers this view has no row for, because they run no pipeline. The
  // captain reconciles this list against the windows in front of them, so the
  // difference is stated rather than left to be discovered.
  const elsewhere = (snap.out_of_scope ?? []).length;
  out.push(headerLine([
    { s: white("fleet pipeline"), pri: 0 },
    { s: dim(`${agents.length} agents`), pri: 3 },
    { s: needs ? yellow(`${needs} ready to merge`) : dim("0 ready to merge"), pri: needs ? 1 : 4 },
    { s: broken ? magenta(`${broken} unreadable`) : dim("0 unreadable"), pri: broken ? 1 : 5 },
    { s: hidden ? dim(`${hidden} hidden, worker gone`) : "", pri: 3 },
    { s: elsewhere ? dim(`${elsewhere} running no pipeline`) : "", pri: 3 },
    { s: lay.count < NCELLS ? yellow(`stages ${lay.first + 1}-${lay.first + lay.count} of ${NCELLS}`) : "", pri: 1 },
    { s: dim(`updated ${ageSec}s ago`), pri: 2 },
    // Belongs beside the age, not in the key hints: an age that keeps climbing
    // while nothing on screen changes needs its reason on the same line.
    { s: note ? magenta(note) : "", pri: 1 },
  ], cols));

  const ruleW = Math.max(1, Math.min(cols, agents.length ? lay.width : 40));
  const rule = dim("─".repeat(ruleW));
  out.push(rule);

  if (agents.length === 0) {
    out.push(dim("  no agents in flight"));
    out.push(rule);
    return out.map((l) => clip(l, cols));
  }

  const visible = visibleRows(rows, chromeRows(flash));
  const top = resolveTop(topIn, sel, visible, agents.length);
  const shown = agents.slice(top, top + visible);
  shown.forEach((a, i) => {
    out.push(...agentBlock(a, top + i + 1, top + i === sel, cell, anim, lay, openHint));
    out.push("");
  });

  out.push(rule);
  const more = agents.length - (top + shown.length);
  const scroll = (top > 0 ? `^${top} above  ` : "") + (more > 0 ? `v${more} below  ` : "");
  out.push(
    (scroll ? green(scroll) : "") +
      dim("up/down agent   left/right stage   enter open worker   r refresh   q quit"),
  );
  if (flash) out.push(yellow(flash));

  // Both invariants in one place, so the frame the captain sees can never be
  // wider or taller than the box it is being drawn into.
  return out.slice(0, Math.max(1, Math.floor(rows))).map((l) => clip(l, cols));
}

// --- entry point ------------------------------------------------------------

function parseArgs(argv) {
  const o = {
    watch: false, cols: null, rows: null, tick: 0, tickGiven: false,
    refreshCmd: "", refreshMs: 10000, openCmd: "", openHint: "",
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--watch") o.watch = true;
    else if (a === "--cols") o.cols = Number(argv[++i]);
    else if (a === "--rows") o.rows = Number(argv[++i]);
    else if (a === "--tick") { o.tick = Number(argv[++i]); o.tickGiven = true; }
    else if (a === "--refresh-cmd") o.refreshCmd = String(argv[++i] ?? "");
    else if (a === "--refresh-ms") o.refreshMs = Number(argv[++i]);
    else if (a === "--open-cmd") o.openCmd = String(argv[++i] ?? "");
    else if (a === "--open-hint") o.openHint = String(argv[++i] ?? "");
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

const ageOf = (snap) =>
  snap?.generated_epoch
    ? Math.max(0, Math.floor(Date.now() / 1000) - snap.generated_epoch)
    : 0;

const firstLine = (s) => String(s ?? "").split("\n").find((l) => l.trim()) ?? "";

function parseSnapshot(raw) {
  let snap;
  try {
    snap = JSON.parse(raw);
  } catch {
    return { error: "not valid JSON" };
  }
  if (snap?.schema !== "fm-flow-snapshot.v1") {
    return { error: `expected schema fm-flow-snapshot.v1, got ${snap?.schema ?? "none"}` };
  }
  return { snap };
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    process.stdout.write(
      "usage: fm-flow-snapshot.sh --json | fm-flow-tui.mjs [--cols N] [--rows N] [--tick N]\n" +
        "       [--watch [--refresh-cmd CMD] [--refresh-ms N] [--open-cmd CMD] [--open-hint TEXT]]\n" +
        "       bin/fm-flow.sh is the captain-facing entry point and wires all three up.\n",
    );
    return 0;
  }
  if (opts.bad) {
    process.stderr.write(`fm-flow-tui: unknown argument ${opts.bad}\n`);
    return 2;
  }
  if (!opts.watch && (opts.refreshCmd || opts.openCmd || opts.openHint)) {
    process.stderr.write("fm-flow-tui: --refresh-cmd, --open-cmd and --open-hint need --watch\n");
    return 2;
  }
  // Without this the process waits forever on a keyboard that is never going
  // to send it a snapshot, which reads as a hang rather than a mistake.
  if (process.stdin.isTTY) {
    process.stderr.write(
      "fm-flow-tui: no snapshot on stdin; run bin/fm-flow.sh, or pipe fm-flow-snapshot.sh --json\n",
    );
    return 2;
  }

  const raw = await readStdin();
  const { snap, error } = parseSnapshot(raw);
  if (error) {
    process.stderr.write(`fm-flow-tui: stdin is ${error}\n`);
    return 1;
  }

  // A non-numeric --cols/--rows must not reach the layout: NaN propagates
  // silently through every Math.floor below and ends as an empty frame with no
  // hint that a flag was mistyped.
  const dimension = (v, fallback) => (Number.isFinite(v) && v > 0 ? Math.floor(v) : fallback);
  const cols = dimension(opts.cols, dimension(process.stdout.columns, 130));
  const rows = dimension(opts.rows, dimension(process.stdout.rows, 45));

  if (!opts.watch) {
    const frame = render(snap, {
      rows,
      cols,
      anim: opts.tick,
      ageSeconds: opts.tickGiven ? 0 : ageOf(snap),
    });
    process.stdout.write(frame.join("\n") + "\n");
    return 0;
  }

  return watch(snap, cols, rows, opts);
}

// --- keyboard ---------------------------------------------------------------

// The controlling terminal, NOT stdin. stdin is carrying the snapshot.
//
// Returns null when there is no controlling terminal to open - a cron run, a
// CI job, a session whose stdout is redirected. That is a legitimate way to
// use this program, so the caller degrades to a single frame rather than
// crashing or spinning forever on timers nobody is watching.
function openKeyboard() {
  let fd;
  try {
    fd = fs.openSync("/dev/tty", "r");
  } catch {
    return null;
  }
  try {
    const stream = new tty.ReadStream(fd);
    if (!stream.isTTY || typeof stream.setRawMode !== "function") {
      stream.destroy();
      return null;
    }
    return stream;
  } catch {
    try { fs.closeSync(fd); } catch { /* already gone */ }
    return null;
  }
}

// One chunk of raw input can hold several keys: holding an arrow down delivers
// "\x1b[B\x1b[B", and a terminal in application-cursor mode sends "\x1bOB"
// instead of "\x1b[B" for the very same key. Comparing the whole chunk against
// one literal, as the shipped version did, drops both.
export function keysOf(chunk) {
  const s = typeof chunk === "string" ? chunk : chunk.toString("utf8");
  const keys = [];
  let i = 0;
  while (i < s.length) {
    if (s[i] === "\x1b") {
      const rest = s.slice(i);
      const m = /^\x1b(?:\[[0-9;]*[A-Za-z~]|O[A-Za-z])/.exec(rest);
      if (m) {
        keys.push(m[0]);
        i += m[0].length;
        continue;
      }
    }
    keys.push(s[i]);
    i++;
  }
  return keys;
}

const KEY = {
  down: new Set(["j", "\x1b[B", "\x1bOB"]),
  up: new Set(["k", "\x1b[A", "\x1bOA"]),
  right: new Set(["l", "\x1b[C", "\x1bOC"]),
  left: new Set(["h", "\x1b[D", "\x1bOD"]),
  quit: new Set(["q", "\x03", "\x04"]),
  open: new Set(["\r", "\n"]),
  refresh: new Set(["r"]),
  first: new Set(["g", "\x1b[H"]),
  last: new Set(["G", "\x1b[F"]),
};

function watch(snap0, cols0, rows0, opts) {
  let snap = snap0;
  let sel = 0, cell = -1, anim = 0, flash = "", flashUntil = 0;
  // Kept BETWEEN frames, which is the whole of the scroll rule: see
  // resolveTop(). A frame-local top makes the window follow the selector
  // instead of the other way round.
  let top = 0;
  const w = () => process.stdout.columns || cols0;
  const h = () => process.stdout.rows || rows0;
  // With no refresh source the age counter climbs while nothing on screen
  // changes. Saying so beside it is the difference between a stale view and a
  // dishonest one.
  const note = opts.refreshCmd ? "" : "static snapshot";

  const keyboard = openKeyboard();
  if (!keyboard || !process.stdout.isTTY) {
    // No keyboard and/or no screen. Draw the frame that was asked for, say why
    // it is not live, and exit. Spinning two timers forever in a cron job with
    // nobody to press q would be the worse failure.
    try { keyboard?.destroy(); } catch { /* nothing to close */ }
    process.stderr.write(
      `fm-flow-tui: ${keyboard ? "output is not a terminal" : "no controlling terminal"}; ` +
        "drawing one frame instead of watching\n",
    );
    const frame = render(snap, {
      rows: h(),
      cols: w(),
      anim: opts.tick,
      ageSeconds: opts.tickGiven ? 0 : ageOf(snap),
      note,
      openHint: opts.openHint,
    });
    process.stdout.write(frame.join("\n") + "\n");
    return 0;
  }

  const enterScreen = () => process.stdout.write("\x1b[?1049h\x1b[2J\x1b[?25l");
  const leaveScreen = () => process.stdout.write("\x1b[?25h\x1b[?1049l");

  enterScreen();
  let restored = false;
  const restore = () => {
    if (restored) return;
    restored = true;
    try { keyboard.setRawMode(false); } catch { /* terminal already gone */ }
    try { keyboard.destroy(); } catch { /* terminal already gone */ }
    leaveScreen();
  };
  const quit = () => { restore(); process.exit(0); };
  process.on("exit", restore);
  for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(sig, quit);

  const setFlash = (msg) => { flash = msg; flashUntil = Date.now() + 5000; };

  // Flicker-free repaint. The big one first: NEVER clear the screen. `\x1b[2J`
  // blanks the pane and the redraw is a separate operation, so the terminal
  // briefly shows an empty frame - that gap IS the flicker. Instead each row is
  // overwritten in place, `\x1b[K` erases only that line's tail, only CHANGED
  // rows are emitted, and the whole frame goes out in ONE write so the terminal
  // never paints a half-updated screen. DECSET 2026 asks it to hold
  // presentation until the frame is complete; terminals that do not know it
  // ignore it.
  //
  // Every row of this scheme assumes frame line i occupies exactly terminal row
  // i+1. render() now guarantees that by fitting the frame to cols and rows; a
  // resize breaks the assumption for one frame, so a resize throws the cache
  // away instead of diffing against a layout that no longer exists.
  let prev = [];
  let prevW = w(), prevH = h();
  // True while the terminal belongs to an --open-cmd. Every timer in this
  // program calls paint(), so without this the animation would overwrite a
  // full-screen program the captain is looking at, one row at a time.
  let suspended = false;
  const paint = () => {
    if (suspended) return;
    if (w() !== prevW || h() !== prevH) {
      prevW = w(); prevH = h(); prev = [];
      process.stdout.write("\x1b[2J");
    }
    if (flash && Date.now() > flashUntil) flash = "";
    // Held here, not inside render(), so it survives from frame to frame.
    top = resolveTop(top, sel, visibleRows(h(), chromeRows(flash)), (snap.agents ?? []).length);
    const next = render(snap, {
      rows: h(),
      cols: w(),
      anim,
      sel,
      cell,
      top,
      flash,
      note,
      openHint: opts.openHint,
      ageSeconds: ageOf(snap),
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

  // --watch's second half: where fresh data comes from.
  //
  // stdin ended the moment the piped snapshot was read, so a watch loop has no
  // second document to read from it - the shipped version redrew the same
  // frozen frame forever while an animated border implied otherwise. The
  // renderer must therefore re-run the collector, and the collector's ARGUMENTS
  // matter (--no-ci, --task, FM_HOME), so it will not guess them: the command
  // is handed in whole with --refresh-cmd. bin/fm-flow.sh builds the first
  // snapshot and that command from one array, so the two cannot diverge.
  // Without the flag the view stays honestly static and says so.
  let refreshing = false;
  const refresh = () => {
    if (!opts.refreshCmd || refreshing) return;
    refreshing = true;
    execFile(
      "/bin/sh",
      ["-c", opts.refreshCmd],
      { encoding: "utf8", maxBuffer: 256 * 1024 * 1024, timeout: 60000, killSignal: "SIGKILL" },
      (err, stdout, stderr) => {
        refreshing = false;
        if (err) { setFlash(`refresh failed: ${firstLine(stderr) || err.message}`); paint(); return; }
        const { snap: next, error } = parseSnapshot(stdout);
        if (error) { setFlash(`refresh failed: snapshot is ${error}`); paint(); return; }
        snap = next;
        sel = Math.max(0, Math.min(sel, (snap.agents ?? []).length - 1));
        paint();
      },
    );
  };

  // Enter is AGENT-scoped, not cell-scoped: it opens the selected worker's
  // window whichever cell is highlighted. No cell carries an action of its own,
  // including GITHUB CI, and the selected agent's row says so on every frame
  // rather than leaving the captain to find out by pressing it.
  //
  // Two things this must never do, both of which it used to. It must not run
  // the command with the terminal still under the alternate screen and raw
  // mode: `tmux attach` needs a real terminal on stdin and stdout, and with the
  // viewer holding both it could do nothing visible at all. And it must not
  // report success on the strength of an exit code alone - `opened <id>` was
  // printed for a command that had only changed a detached session's current
  // window, which is the exact defect class this fleet cares about most. What
  // the command SAYS it did is what reaches the footer; the exit code only
  // decides whether that is an outcome or a failure.
  const open = () => {
    const a = (snap.agents ?? [])[sel];
    if (!a) return;
    if (!opts.openCmd) {
      setFlash(`no open command wired up; that worker is at ${a.window || "an unrecorded window"}`);
      return;
    }
    // Our OWN stdout, not a fresh open of /dev/tty, and it is handed to the
    // child as both its stdin and its stdout. A terminal is opened read-write,
    // so one descriptor serves for both, and this is the only handle that names
    // a concrete device: `ttyname()` on an fd opened through /dev/tty answers
    // "/dev/tty", and tmux REFUSES a client whose terminal is that
    // (server_client_open, "can't use /dev/tty"). Verified 2026-08-09 - the
    // first cut of this opened /dev/tty and `tmux attach` failed with exactly
    // that message. Watch mode has already established stdout is a terminal.
    const ttyFd = process.stdout.isTTY ? 1 : null;

    suspended = true;
    try { keyboard.setRawMode(false); } catch { /* terminal already gone */ }
    keyboard.pause();
    leaveScreen();

    let res = null;
    let threw = null;
    try {
      // No timeout. The command is allowed to be an interactive session the
      // captain sits in for as long as they like; a timeout here would kill it
      // out from under them.
      res = spawnSync("/bin/sh", ["-c", opts.openCmd], {
        encoding: "utf8",
        stdio: ttyFd == null ? ["ignore", "ignore", "pipe"] : [ttyFd, ttyFd, "pipe"],
        env: {
          ...process.env,
          FM_FLOW_ID: a.id ?? "",
          FM_FLOW_WINDOW: a.window ?? "",
          FM_FLOW_WORKTREE: a.worktree ?? "",
          FM_FLOW_PROJECT: a.project ?? "",
          FM_FLOW_PR: a.pr?.url ?? "",
        },
      });
    } catch (e) {
      // spawnSync itself refusing to start is still a failed open, and the
      // screen has to come back either way.
      threw = e;
    } finally {
      enterScreen();
      try { keyboard.setRawMode(true); } catch { /* terminal already gone */ }
      keyboard.resume();
      suspended = false;
      // The command owned the screen; nothing on it matches the diff cache.
      prev = [];
    }

    if (threw) { setFlash(`open failed: ${threw.message}`); return; }
    const said = firstLine(res.stderr);
    if (res.error) setFlash(`open failed: ${res.error.message}`);
    else if (res.status !== 0) {
      setFlash(`open failed: ${said || `exit ${res.status ?? `signal ${res.signal}`}`}`);
    } else if (ttyFd == null) {
      // No terminal to hand over, so whatever the command did, the captain was
      // not put anywhere. Saying it succeeded would be the original lie again.
      setFlash(said || `${a.id}: open command ran, but there is no terminal to show it in`);
    } else setFlash(said || `${a.id}: open command exited 0 without saying what it did`);
  };

  keyboard.setRawMode(true);
  keyboard.resume();
  keyboard.on("data", (b) => {
    const count = () => (snap.agents ?? []).length;
    for (const k of keysOf(b)) {
      if (KEY.quit.has(k)) { quit(); return; }
      else if (KEY.down.has(k)) sel = Math.min(Math.max(0, count() - 1), sel + 1);
      else if (KEY.up.has(k)) sel = Math.max(0, sel - 1);
      else if (KEY.right.has(k)) cell = Math.min(NCELLS - 1, cell + 1);
      else if (KEY.left.has(k)) cell = Math.max(-1, cell - 1);
      else if (KEY.first.has(k)) sel = 0;
      else if (KEY.last.has(k)) sel = Math.max(0, count() - 1);
      else if (KEY.refresh.has(k)) refresh();
      else if (KEY.open.has(k)) open();
    }
    paint();
  });

  // The border chase needs a frame rate the eye reads as motion; the data
  // behind it does not. Three timers, so a smooth animation never implies the
  // underlying state is polled eight times a second, and the collector runs on
  // its own slower cadence again.
  setInterval(() => { anim = (anim + 1) % 10000; paint(); }, 110);
  setInterval(paint, 1000);
  if (opts.refreshCmd) {
    const every = Number.isFinite(opts.refreshMs) && opts.refreshMs >= 500 ? opts.refreshMs : 10000;
    setInterval(refresh, every);
  }
  paint();
  return new Promise(() => {});
}

const invokedDirectly =
  process.argv[1] && import.meta.url === `file://${process.argv[1]}`;
if (invokedDirectly) {
  main().then((code) => process.exit(code ?? 0));
}
