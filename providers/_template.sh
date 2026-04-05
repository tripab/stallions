#!/bin/bash
# providers/_template.sh — Copy this file and adapt for your coding agent
#
# The runner scripts pipe the full prompt (static instructions + task content)
# into stdin. Your invoke_coding_agent function must:
#   1. Read the prompt from stdin
#   2. Pass it to your coding agent CLI
#   3. Let the agent run to completion (non-interactive)
#   4. Return the agent's exit code
#
# Available environment variables (set by runner scripts):
#   AGENT_MODEL         — model name/identifier
#   AGENT_MAX_TURNS     — max tool-use iterations
#   AGENT_EFFORT        — quality/effort level (e.g. "high" for reviewer)
#   AGENT_ALLOWED_TOOLS — comma-separated tool list
#   MAX_TURNS           — global default for max turns (from common.sh)
#
# Usage:
#   ./scripts/run_implementer.sh --provider providers/my-agent.sh

invoke_coding_agent() {
  local model="${AGENT_MODEL:-your-default-model}"

  # Most CLIs accept stdin directly:
  #   your-agent --non-interactive --model "$model"
  #
  # If your CLI needs the prompt as an argument instead of stdin:
  #   local tmpfile=$(mktemp)
  #   cat > "$tmpfile"
  #   your-agent --prompt "$(cat "$tmpfile")"
  #   local rc=$?; rm -f "$tmpfile"; return $rc

  echo "ERROR: _template.sh is not a real provider. Copy and customize it." >&2
  return 1
}
