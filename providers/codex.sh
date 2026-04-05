#!/bin/bash
# providers/codex.sh — OpenAI Codex CLI provider
#
# Requires: npm i -g @openai/codex (and authenticated via `codex login`)
#
# Codex CLI's non-interactive mode is `codex exec`. It reads stdin with `-`.
# Full-auto mode (`--full-auto`) grants workspace-write sandbox + auto-approvals.
#
# Environment variables you can override:
#   AGENT_MODEL   (default: gpt-5.2-codex)

invoke_coding_agent() {
  local model="${AGENT_MODEL:-gpt-5.2-codex}"

  codex exec \
    --model "$model" \
    --full-auto \
    -
}
