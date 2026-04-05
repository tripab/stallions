#!/bin/bash
# run_agent.sh — Generic role-based agent runner (Stallions v3).
#
# Reads role config from orchestration.toml, resolves prompt/model/tags/hooks,
# then dispatches to the appropriate lifecycle function in common.sh.
#
# Usage:
#   ./scripts/run_agent.sh --role <name>
#   ./scripts/run_agent.sh --role backend --instance 1
#   ./scripts/run_agent.sh --role qa --once
#   ./scripts/run_agent.sh --role backend --provider providers/codex.sh

set -euo pipefail

source "$(dirname "$0")/common.sh"

# ── Parse arguments ──────────────────────────────────────────────────────────

ROLE=""
INSTANCE=0
LOOP_MODE=true
EXPLICIT_PROVIDER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)     shift; ROLE="$1"     ;;
    --instance) shift; INSTANCE="$1" ;;
    --once)     LOOP_MODE=false      ;;
    --provider) shift; EXPLICIT_PROVIDER="$1"; load_provider "$1" ;;
    *)  ;;   # ignore unknown flags
  esac
  shift
done

if [ -z "$ROLE" ]; then
  log_err "--role <name> is required"
  echo "Usage: ./scripts/run_agent.sh --role <name> [--instance N] [--once] [--provider file]" >&2
  exit 1
fi

# ── Load config and resolve role settings ────────────────────────────────────

load_config

# Resolve each field: role-specific value first, then [defaults] fallback
ROLE_TYPE=$(role_config_get "$ROLE" "type")
ROLE_PROMPT=$(role_config_get "$ROLE" "prompt")
ROLE_TAGS=$(role_config_get "$ROLE" "tags")
ROLE_MODEL=$(role_config_get "$ROLE" "model")
ROLE_MAX_TURNS=$(role_config_get "$ROLE" "max_turns")
ROLE_HOOKS_DIR=$(role_config_get "$ROLE" "hooks_dir")
ROLE_TASK_FILTER=$(role_config_get "$ROLE" "task_filter")
ROLE_POLL_INTERVAL=$(role_config_get "$ROLE" "poll_interval")
ROLE_EFFORT=$(role_config_get "$ROLE" "effort")
ROLE_PROVIDER=$(role_config_get "$ROLE" "provider")

# Defaults for required fields
ROLE_TYPE="${ROLE_TYPE:-implementer}"

# Resolve prompt file path
if [ -z "$ROLE_PROMPT" ]; then
  # Try role-named prompt, then generic implementer
  if [ -f "$PROMPTS_DIR/${ROLE}.md" ]; then
    ROLE_PROMPT="$PROMPTS_DIR/${ROLE}.md"
  else
    ROLE_PROMPT="$PROMPTS_DIR/implementer.md"
  fi
else
  # Make relative paths absolute
  [[ "$ROLE_PROMPT" != /* ]] && ROLE_PROMPT="$PROJECT_ROOT/$ROLE_PROMPT"
fi

# Load role-specific provider override (unless already loaded via --provider flag)
if [ -z "$EXPLICIT_PROVIDER" ] && [ -n "$ROLE_PROVIDER" ]; then
  local_provider="$PROJECT_ROOT/$ROLE_PROVIDER"
  [ -f "$local_provider" ] && load_provider "$local_provider"
fi

# Resolve hooks dir (relative to project root)
local HOOKS_DIR_ABS=""
if [ -n "$ROLE_HOOKS_DIR" ]; then
  HOOKS_DIR_ABS="$PROJECT_ROOT/$ROLE_HOOKS_DIR"
fi

# ── Export env vars for lifecycle functions ──────────────────────────────────

export AGENT_ROLE="$ROLE"
export AGENT_INSTANCE="$INSTANCE"
export AGENT_ROLE_TYPE="$ROLE_TYPE"
export AGENT_PROMPT_FILE="$ROLE_PROMPT"
export AGENT_ROLE_TAGS="${ROLE_TAGS:-}"
export AGENT_TASK_FILTER="${ROLE_TASK_FILTER:-Pending|Reviewed}"
export AGENT_HOOKS_DIR="$HOOKS_DIR_ABS"
export AGENT_LOOP_MODE="$LOOP_MODE"
export POLL_INTERVAL="${ROLE_POLL_INTERVAL:-120}"

# Model and turns: role override takes precedence over already-set defaults
[ -n "$ROLE_MODEL" ]     && export AGENT_MODEL="$ROLE_MODEL"
[ -n "$ROLE_MAX_TURNS" ] && export AGENT_MAX_TURNS="$ROLE_MAX_TURNS"
[ -n "$ROLE_EFFORT" ]    && export AGENT_EFFORT="$ROLE_EFFORT"

# Track provider path for JSONL logging
export AGENT_PROVIDER="${AGENT_PROVIDER:-${ROLE_PROVIDER:-providers/claude.sh}}"

# ── Dispatch ─────────────────────────────────────────────────────────────────

case "$ROLE_TYPE" in
  implementer)
    lifecycle_implementer
    ;;
  reviewer)
    lifecycle_reviewer
    ;;
  qa_responder|qa)
    lifecycle_qa_responder
    ;;
  interactive)
    log_info "Role '$ROLE' is type=interactive — launch it manually or via the dashboard."
    log_info "  claude --prompt-file $ROLE_PROMPT"
    exit 0
    ;;
  *)
    log_err "Unknown role type: '$ROLE_TYPE' for role '$ROLE'"
    log_err "Valid types: implementer, reviewer, qa_responder, interactive"
    exit 1
    ;;
esac
