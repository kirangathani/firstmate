#!/usr/bin/env node
// Semantic policy for the fix-instructions gate: does a shell command submit a
// no-mistakes fix round that carries no substantive --instructions?
//
// Why this exists. A crewmate at a no-mistakes gate has exactly three responses:
// approve, fix, skip. `--action fix` hands the work to no-mistakes' OWN gate
// agent, which is not the crewmate. That agent sees the finding text and the
// diff, and nothing else. It cannot see the crewmate's brief, which lives at
// data/<id>/brief.md inside the firstmate home, outside the project repo, while
// the gate agent runs in a gate worktree of the project. In the firstmate repo
// it also cannot see AGENTS.md, because .no-mistakes.yaml sets
// disable_project_settings: true on purpose so a gate agent never adopts the
// fleet-captain identity. So --instructions is one of only two channels that
// carry a worker's context into a gate agent (the other is the run's --intent,
// owned by bin/fm-nm-intent.sh). An empty one silently drops that channel.
//
// Measured cost of leaving it unenforced: task nm-flow-view-r7 spent four review
// rounds on successive variants of ONE defect, because each round was a fresh
// gate agent that fixed the symptom and reintroduced the class.
//
// SCOPE OF THE RULE (a settled captain ruling; do not widen or narrow it).
// This enforces PRESENCE and LENGTH, never quality. Presence-only was explicitly
// rejected because a one-word argument satisfies it. Additionally requiring named
// content checked by keyword or structure was explicitly rejected because a
// structural check on prose produces false refusals. A worker who routes the
// command through a script file sidesteps this text match; that is known and
// accepted.
//
// The shell tokenizer and command-position analysis are imported from
// bin/fm-arm-command-policy.mjs, the sole owner of firstmate's shell
// classification, so this guard never duplicates shell lexing. This policy never
// evaluates, expands, sources, or runs any byte of the submitted command; it
// inspects lexical command positions only.
//
// See docs/fix-instructions-gate.md for the full contract.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

// The substance floor, in characters of cooked instruction text after trimming.
//
// Justification for 120 rather than any other number: the refusal message asks
// for three distinct things - the design reasoning behind the code the finding
// touches, the principle the fix must preserve, and what the fix must not break
// or reintroduce. Written as tersely as a real answer can be, each of those is a
// clause of roughly 40 characters, so 120 is the shortest text that could
// plausibly carry all three. It is calibrated as "too short to be an answer at
// all", not as a quality bar - a floor high enough to reject a one-word or
// one-phrase argument, and low enough that a genuine two-sentence answer always
// clears it. Raising it would start rejecting real answers, which is the failure
// mode a prose check must avoid.
export const MIN_INSTRUCTIONS_CHARS = 120;

const REQUIRED_CONTENT =
  "The instructions must carry, in prose: the design reasoning behind the code the finding touches, the principle the fix must preserve, and what the fix must not break or reintroduce.";

const REASONS = {
  "fix-instructions-missing":
    `a no-mistakes fix round was submitted with no --instructions. The gate agent that applies the fix is not you: it sees the finding text and the diff and nothing else, and it cannot read this task's brief or this repo's AGENTS.md. Re-run the same command with --instructions. ${REQUIRED_CONTENT}`,
  "fix-instructions-thin":
    `the --instructions on this no-mistakes fix round are shorter than ${MIN_INSTRUCTIONS_CHARS} characters, roughly a couple of sentences, so they cannot carry the context the gate agent needs. The gate agent sees the finding text and the diff and nothing else, and it cannot read this task's brief or this repo's AGENTS.md. ${REQUIRED_CONTENT}`,
};

// no-mistakes axi respond flags that consume the following word as their value.
// Taken from `no-mistakes axi respond --help` on v1.37.0: --action, --step,
// --findings, --add-finding, --instructions. Everything else there (-y/--yes,
// -h/--help) is boolean. A flag firstmate does not know about is treated as
// boolean, which can only ever make this policy allow more, never deny more.
const VALUE_FLAGS = new Set(["--action", "--step", "--findings", "--add-finding", "--instructions"]);

// Literal nested-shell sinks whose -c payload is re-classified one level down.
const SHELL_SINKS = new Set(["sh", "bash", "zsh", "dash", "ksh"]);

const MAX_DEPTH = 3;

function basename(value) {
  const parts = value.split("/");
  return parts.at(-1) ?? value;
}

function deny(code) {
  return { decision: "deny", code, reason: REASONS[code] };
}

// Parse the words after the command word into no-mistakes subcommand
// positionals plus the last-wins value of each flag firstmate cares about.
// Returns the flag VALUE TOKENS, not just their strings, because a token that is
// not `literal` (it contains $VAR, $(...), or a backtick) cannot be measured
// statically and must not be judged.
function parseRespondInvocation(words) {
  const positionals = [];
  const flags = new Map();
  for (let i = 0; i < words.length; i += 1) {
    const token = words[i];
    const value = token.value;
    if (value === "--") {
      positionals.push(...words.slice(i + 1));
      break;
    }
    if (VALUE_FLAGS.has(value)) {
      const next = words[i + 1];
      if (next) flags.set(value, next);
      i += 1;
      continue;
    }
    const equals = value.indexOf("=");
    if (value.startsWith("--") && equals > 2 && VALUE_FLAGS.has(value.slice(0, equals))) {
      flags.set(value.slice(0, equals), { ...token, value: value.slice(equals + 1) });
      continue;
    }
    if (value.startsWith("-") && value !== "-") continue;
    positionals.push(token);
  }
  return { positionals, flags };
}

function classifyRespondNode(position) {
  const { positionals, flags } = parseRespondInvocation(position.words.slice(position.index + 1));
  if (positionals.length < 2) return undefined;
  if (positionals[0].value !== "axi" || positionals[1].value !== "respond") return undefined;

  const action = flags.get("--action");
  // No --action, a dynamic --action, or any action other than fix: not this
  // policy's business. `respond` without --action is a usage error no-mistakes
  // itself rejects.
  if (!action || !action.literal || action.value !== "fix") return undefined;

  const instructions = flags.get("--instructions");
  if (!instructions) return deny("fix-instructions-missing");
  // An unexpanded $VAR, $(...), or backtick payload cannot be measured without
  // running it, and this policy never runs a byte of the command. Allowing here
  // is deliberate: a false refusal of a genuine long instruction is worse than
  // missing a dynamic bypass, and the threat model is a forgetful worker, not an
  // adversary. Same stance the sibling seatbelts take on opaque dataflow.
  if (!instructions.literal) return undefined;
  if (instructions.value.trim().length < MIN_INSTRUCTIONS_CHARS) return deny("fix-instructions-thin");
  return undefined;
}

// Literal `sh -c '<payload>'` / `eval '<payload>'` bodies are re-classified so a
// fix round wrapped in one extra shell is still seen. A dynamic payload is
// skipped for the same reason a dynamic --instructions value is.
function nestedPayloads(position) {
  const payloads = [];
  const command = position.command;
  if (!command) return payloads;
  const name = basename(command.value);
  const rest = position.words.slice(position.index + 1);
  if (SHELL_SINKS.has(name)) {
    for (let i = 0; i < rest.length; i += 1) {
      if (!/^-[a-zA-Z]*c$/.test(rest[i].value)) continue;
      const payload = rest[i + 1];
      if (payload && payload.literal) payloads.push(payload.value);
      break;
    }
    return payloads;
  }
  if (name === "eval") {
    const literal = rest.filter((word) => word.literal).map((word) => word.value);
    if (literal.length === rest.length && literal.length > 0) payloads.push(literal.join(" "));
  }
  return payloads;
}

function classify(command, depth) {
  if (depth > MAX_DEPTH) return { decision: "allow" };
  const lexed = new Lexer(command).tokenize();
  // Fail open on syntax this classifier cannot tokenize, matching the sibling
  // cd-guard. The threat model is a worker who forgot --instructions, and that
  // command always tokenizes; a malformed or deliberately obfuscated command is
  // out of scope by the same captain-accepted limit recorded in the header.
  if (lexed.error) return { decision: "allow" };

  const { nodes } = splitProgram(lexed.tokens);
  for (const node of nodes) {
    for (const token of node) {
      if (token.type !== "group") continue;
      const nested = classify(token.content, depth + 1);
      if (nested.decision === "deny") return nested;
    }
    const position = commandPosition(node);
    if (!position.command) continue;
    if (position.command.literal && basename(position.command.value) === "no-mistakes") {
      const verdict = classifyRespondNode(position);
      if (verdict) return verdict;
      continue;
    }
    for (const payload of nestedPayloads(position)) {
      const nested = classify(payload, depth + 1);
      if (nested.decision === "deny") return nested;
    }
  }
  return { decision: "allow" };
}

function decision(command) {
  return classify(command, 0);
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--command") {
      if (i + 1 >= argv.length) throw new Error("--command requires a value");
      result.command = argv[i + 1];
      result.commandSet = true;
      i += 1;
      continue;
    }
    if (name.startsWith("--command=")) {
      result.command = name.slice("--command=".length);
      result.commandSet = true;
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (!args.commandSet || !args.command) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(args.command);
      if (result.decision === "allow") {
        process.stdout.write("allow\n");
      } else {
        process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
      }
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
