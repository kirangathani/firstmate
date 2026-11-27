# Claude Code Monitor hook capture

Captured 2026-11-18 from Claude Code 2.1.327 in a scratch project whose `.claude/settings.json` registered a payload logger and `bin/fm-arm-pretool-check.sh --claude` under the `Bash` matcher.
The driving prompt issued one Monitor running `bin/fm-send.sh probe-id "hello" 2>&1` and one Bash call running `bin/fm-send.sh probe-id bash-hello`.

- `payload-monitor-send.json` is the exact stdin the Bash-matcher hook received for the Monitor call, as `tool_name` `Bash`.
- `payload-bash-send.json` is the exact stdin it received for the real Bash call.
- In both, only the `transcript_path` and `cwd` values were replaced with `@TRANSCRIPT@` and `@CWD@`, which the test substitutes.
- `transcript.jsonl` holds the two assistant transcript lines for those `tool_use_id`s, cut down with `jq` to `type`, `version`, `isSidechain`, and the one matching `tool_use` content block; the block itself is byte-for-byte as recorded.

`docs/arm-pretool-check.md` records the capture method and what it shows.
