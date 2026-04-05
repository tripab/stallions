#!/bin/bash
# providers/opencode.sh — OpenCode provider (open-source, multi-model)
#
# Requires: npm i -g opencode-ai@latest (or brew install opencode)
# Auth:     opencode auth login
#
# OpenCode's non-interactive mode takes the prompt as a -p argument,
# not stdin. This adapter captures stdin to a temp file and passes it.
#
# Environment variables you can override:
#   AGENT_MODEL   (default: anthropic:claude-sonnet-4-20250514)
#                 OpenCode uses provider:model format. Examples:
#                   anthropic:claude-sonnet-4-20250514
#                   openai:gpt-4o
#                   google:gemini-2.5-pro
#                   ollama:deepseek-coder-v2

invoke_coding_agent() {
  local model="${AGENT_MODEL:-anthropic:claude-sonnet-4-20250514}"

  # Capture stdin to temp file (prompts can be large with injected task content)
  local tmpfile
  tmpfile=$(mktemp "${TMPDIR:-/tmp}/opencode-prompt.XXXXXX")
  cat > "$tmpfile"

  # -p: non-interactive prompt, -q: suppress spinner (clean for scripts)
  opencode -p "$(cat "$tmpfile")" -q --model "$model"
  local exit_code=$?

  rm -f "$tmpfile"
  return $exit_code
}
