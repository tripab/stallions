#!/bin/bash
# providers/claude.sh — Claude Code provider config
#
# This is the default provider. You don't need to pass --provider for Claude Code,
# but this file documents the interface if you want to customize it.
#
# Environment variables you can override:
#   AGENT_MODEL        (default: sonnet)
#   AGENT_MAX_TURNS    (default: 25, from MAX_TURNS)
#   AGENT_EFFORT       (default: unset; reviewer sets "high")
#   AGENT_ALLOWED_TOOLS (default: Bash,Read,Write,Edit,Glob,Grep,MultiEdit)
#
# Token reporting: we run with `--output-format json` so Claude returns exact
# token usage. The readable assistant text (`.result`) is emitted to stdout for
# logging and usage-limit detection, while the precise token counts are written
# to $AGENT_TOKENS_FILE (set by the runner) so they land in the JSONL log —
# which is what Racetrack reads for per-agent token usage.

invoke_coding_agent() {
  local max_turns="${AGENT_MAX_TURNS:-$MAX_TURNS}"
  local allowed_tools="${AGENT_ALLOWED_TOOLS:-Bash,Read,Write,Edit,Glob,Grep,MultiEdit}"
  local model="${AGENT_MODEL:-sonnet}"
  local effort="${AGENT_EFFORT:-}"

  local cmd=(claude --model "$model" --print --output-format json
             --max-turns "$max_turns" --allowedTools "$allowed_tools")
  [[ -n "$effort" ]] && cmd+=(--effort "$effort")

  local out_tmp err_tmp rc
  out_tmp=$(mktemp); err_tmp=$(mktemp)
  "${cmd[@]}" >"$out_tmp" 2>"$err_tmp"; rc=$?

  if command -v jq >/dev/null 2>&1 && jq -e 'type=="object" and has("type")' "$out_tmp" >/dev/null 2>&1; then
    # Readable text for the terminal, response capture, and summary. Prefer the
    # assistant result; on an error envelope (e.g. max_turns, no `.result`) fall
    # back to the error list / subtype so it's logged legibly, not as raw JSON.
    jq -r '.result // (if (.errors|type)=="array" then (.errors|join("; ")) else (.subtype // "agent run did not return a result") end)' "$out_tmp"
    # Exact token usage for the runner's JSONL log (consumed by Racetrack) —
    # recorded even on error envelopes, which still carry `.usage`.
    if [ -n "${AGENT_TOKENS_FILE:-}" ]; then
      jq -c '{input:(.usage.input_tokens // 0),
              output:(.usage.output_tokens // 0),
              cache_read:(.usage.cache_read_input_tokens // 0),
              cache_write:(.usage.cache_creation_input_tokens // 0)}' \
        "$out_tmp" > "$AGENT_TOKENS_FILE" 2>/dev/null || true
    fi
  else
    # Not the JSON envelope — e.g. a usage-limit / auth notice, or jq missing.
    # Pass it through verbatim so usage-limit detection and logging still work.
    cat "$out_tmp"
  fi

  # Always surface stderr (warnings, usage-limit notices) for detection/logging.
  [ -s "$err_tmp" ] && cat "$err_tmp"
  rm -f "$out_tmp" "$err_tmp"
  return $rc
}
