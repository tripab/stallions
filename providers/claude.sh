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

invoke_coding_agent() {
  local max_turns="${AGENT_MAX_TURNS:-$MAX_TURNS}"
  local allowed_tools="${AGENT_ALLOWED_TOOLS:-Bash,Read,Write,Edit,Glob,Grep,MultiEdit}"
  local model="${AGENT_MODEL:-sonnet}"
  local effort="${AGENT_EFFORT:-}"

  local cmd=(claude --model "$model" --print --max-turns "$max_turns"
             --allowedTools "$allowed_tools")
  [[ -n "$effort" ]] && cmd+=(--effort "$effort")

  "${cmd[@]}"
}
