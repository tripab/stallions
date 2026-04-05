#!/bin/bash
# providers/aider.sh — Aider provider (open-source, git-aware)
#
# Requires: pip install aider-chat
# Auth:     Set ANTHROPIC_API_KEY or OPENAI_API_KEY in env
#
# Aider's non-interactive mode uses --message for one-shot prompts.
# It's git-aware by default, which pairs well with the worktree setup.
#
# Environment variables you can override:
#   AGENT_MODEL   (default: sonnet)
#                 Aider model names: sonnet, opus, gpt-4o, deepseek, etc.

invoke_coding_agent() {
  local model="${AGENT_MODEL:-sonnet}"

  # Capture stdin prompt
  local tmpfile
  tmpfile=$(mktemp "${TMPDIR:-/tmp}/aider-prompt.XXXXXX")
  cat > "$tmpfile"

  # --yes-always: auto-accept file edits (non-interactive)
  # --no-auto-commits: we handle commits ourselves in the runner scripts
  aider --model "$model" \
    --message "$(cat "$tmpfile")" \
    --yes-always \
    --no-auto-commits
  local exit_code=$?

  rm -f "$tmpfile"
  return $exit_code
}
