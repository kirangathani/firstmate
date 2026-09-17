#!/usr/bin/env bash
# The report over firstmate's own latency ledger.
#
#   fm-latency.sh report [--last N]
#
# bin/fm-latency-lib.sh is the ledger's one owner - its columns, its format,
# its never-break-the-caller contract, and every write path - and this script
# only reads what that library wrote. docs/configuration.md's "Self-latency
# ledger" section says what the ledger records, what it cannot see, and how to
# read the numbers below.
#
# Nothing here writes to the ledger, so a report can be run at any time,
# including while the fleet is busy, without disturbing a measurement.
#
# Environment: FM_HOME, FM_DATA_OVERRIDE, FM_LATENCY_LEDGER, as the library.
# Exit: 0 on a report (including "no ledger yet"), 2 on a usage error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-latency-lib.sh
. "$SCRIPT_DIR/fm-latency-lib.sh"

LEDGER=$(fm_latency_ledger)
# Global, not a cmd_report local: the EXIT trap below fires after that function
# has returned, where a local is out of scope and `set -u` would abort inside
# the trap itself.
REPORT_WORK=
# shellcheck disable=SC2317,SC2329 # Invoked by the EXIT trap.
report_cleanup() { [ -z "$REPORT_WORK" ] || command rm -rf -- "$REPORT_WORK"; }
trap report_cleanup EXIT

usage() {
  cat >&2 <<'USAGE'
usage: fm-latency.sh report [--last N]
USAGE
  exit 2
}

cmd_report() {
  local last=20 tab work
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --last) shift; last=${1-}; case "$last" in ''|*[!0-9]*|0) usage ;; esac ;;
      *) usage ;;
    esac
    shift
  done
  if [ ! -s "$LEDGER" ]; then
    echo "latency: no ledger yet at $LEDGER" >&2
    return 0
  fi
  tab=$(printf '\t')
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-latency-report.XXXXXX") || return 0
  REPORT_WORK=$work

  # The tail, aligned. An empty TSV cell is invisible to `column -t`, which
  # would shift every later column left, so empties are drawn as a dash for
  # display only - the file itself keeps them empty.
  {
    head -1 "$LEDGER"
    tail -n +2 "$LEDGER" | tail -n "$last"
  } | awk -F'\t' -v OFS='\t' '{ for (i = 1; i <= NF; i++) if ($i == "") $i = "-"; print }' \
    | column -t -s "$tab"

  # Each summary is written to its own file and aligned on its own. One
  # `column -t` over the whole report would size every column to the widest
  # cell in ANY of the three tables, and to the prose headings between them,
  # which makes all three unreadable.
  LC_ALL=C awk -v last="$last" -v out="$work" -F'\t' '
    function med(vals, count,   i, j, t) {
      if (count == 0) return ""
      for (i = 2; i <= count; i++)
        for (j = i; j > 1 && vals[j-1] + 0 > vals[j] + 0; j--) { t = vals[j-1]; vals[j-1] = vals[j]; vals[j] = t }
      if (count % 2) return vals[(count+1)/2] + 0
      return (vals[count/2] + vals[count/2+1]) / 2
    }
    function secs(m) { return (m == "") ? "-" : sprintf("%.2f", m / 1000) }
    function num(v) { return (v ~ /^[0-9]+$/) ? v + 0 : "" }
    # One window of a series held in src[1..n], from index lo to hi.
    function window(src, lo, hi,   i, v, k) {
      k = 0
      for (i = lo; i <= hi; i++) if (i in src) v[++k] = src[i]
      return med(v, k)
    }
    function count_in(src, lo, hi,   i, k) {
      k = 0
      for (i = lo; i <= hi; i++) if (i in src) k++
      return k
    }
    # Two equal windows, so one can be read against the other: a single median
    # says how slow firstmate is, never whether that is getting better.
    function band(n,   lo) { lo = n - last + 1; return (lo < 1) ? 1 : lo }
    function chain_row(label, lo, hi, alo, ahi) {
      printf "%s\t%d\t%s\t%s\t%s\n", label, count_in(w_all, lo, hi), \
        secs(window(w_report, lo, hi)), secs(window(w_queue, lo, hi)), \
        secs(window(w_act, alo, ahi)) > (out "/chain")
    }
    function model_row(label, lo, hi, rlo, rhi,   tp) {
      tp = window(turn_tools, rlo, rhi)
      printf "%s\t%d\t%s\t%d\t%s\t%s\t%s\n", label, count_in(t_think, lo, hi), \
        secs(window(t_think, lo, hi)), count_in(turn_wall, rlo, rhi), \
        secs(window(turn_wall, rlo, rhi)), secs(window(turn_think, rlo, rhi)), \
        (tp == "" ? "-" : sprintf("%.1f", tp)) > (out "/model")
    }

    NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }

    {
      e     = num($(col["epoch_ms"]))
      kind  = $(col["kind"])
      act   = $(col["action"])
      task  = $(col["task"])
      dur   = num($(col["duration_ms"]))
      think = num($(col["think_ms"]))
      rep   = num($(col["reported_epoch_ms"]))
      enq   = num($(col["enqueued_epoch_ms"]))
      code  = $(col["exit_code"])
      tools = num($(col["tools"]))
    }

    kind == "wake" {
      nwake++
      w_all[nwake] = 1
      if (e != "" && rep != "" && e >= rep) w_report[nwake] = e - rep
      if (e != "" && enq != "" && e >= enq) w_queue[nwake] = e - enq
      # The first firstmate command naming this task AFTER this wake is when
      # triage turned into action. Held open until such a command appears; a
      # wake never answered contributes nothing rather than a zero.
      if (task != "" && e != "") pending[task] = e
      next
    }

    kind == "cmd" {
      ncmd++
      if (dur != "") { cmd_n[act]++; cmd_dur[act, cmd_n[act]] = dur }
      if (code != "" && code != "0") cmd_fail[act]++
      if (task != "" && task in pending && e != "" && e >= pending[task]) {
        w_act[++nact] = e - pending[task]
        delete pending[task]
      }
      next
    }

    kind == "tool" { ntool++; if (think != "") t_think[ntool] = think; next }

    kind == "turn" {
      nturn++
      if (dur != "") turn_wall[nturn] = dur
      if (think != "") turn_think[nturn] = think
      if (tools != "") turn_tools[nturn] = tools
      next
    }

    END {
      printf "window\twakes\tcrew_report_to_seen_s\tqueued_to_seen_s\tseen_to_first_action_s\n" > (out "/chain")
      lo = band(nwake); alo = band(nact)
      chain_row("recent", lo, nwake, alo, nact)
      if (lo > 1) {
        plo = lo - last; if (plo < 1) plo = 1
        palo = alo - last; if (palo < 1) palo = 1
        chain_row("before", plo, lo - 1, palo, alo - 1)
      }

      printf "window\ttool_calls\tthink_per_tool_s\tturns\tturn_wall_s\ttrailing_think_s\ttools_per_turn\n" > (out "/model")
      tlo = band(ntool); rlo = band(nturn)
      model_row("recent", tlo, ntool, rlo, nturn)
      if (tlo > 1 || rlo > 1) {
        ptlo = tlo - last; if (ptlo < 1) ptlo = 1
        prlo = rlo - last; if (prlo < 1) prlo = 1
        model_row("before", ptlo, tlo - 1, prlo, rlo - 1)
      }

      printf "command\truns\tduration_ms\tfailures\n" > (out "/cmds")
      for (a in cmd_n) {
        k = 0
        for (i = 1; i <= cmd_n[a]; i++) v2[++k] = cmd_dur[a, i]
        m = med(v2, k)
        delete v2
        printf "%s\t%d\t%s\t%d\n", a, cmd_n[a], (m == "" ? "-" : sprintf("%d", m)), cmd_fail[a] + 0 > (out "/cmds")
      }
      if (ncmd == 0) printf "(none yet)\t0\t-\t0\n" > (out "/cmds")
    }
  ' "$LEDGER"

  echo
  printf 'response chain, median SECONDS over the last %s wakes, against the %s before them. A wake whose source time is unknown - an untimestamped crew report - is counted under wakes but left out of that median.\n' "$last" "$last"
  column -t -s "$tab" < "$work/chain"
  echo
  printf 'model time, median SECONDS. think is the gap between two harness events, which holds no command execution.\n'
  column -t -s "$tab" < "$work/model"
  echo
  printf 'measured commands, median MILLISECONDS, whole ledger. failures counts a non-zero exit.\n'
  column -t -s "$tab" < "$work/cmds"
}

[ "$#" -ge 1 ] || usage
case "$1" in
  report) shift; cmd_report "$@" ;;
  -h|--help) usage ;;
  *) usage ;;
esac
