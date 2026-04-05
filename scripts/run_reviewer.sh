#!/bin/bash
# run_reviewer.sh — Finds tasks to review in bash, feeds agent only the diff + task file.
#
# Usage:
#   ./scripts/run_reviewer.sh                          # default (Claude Code)
#   ./scripts/run_reviewer.sh --provider providers/opencode.sh

source "$(dirname "$0")/common.sh"
parse_provider_arg "$@"

AGENT="reviewer"
PROMPT_FILE="$PROMPTS_DIR/reviewer.md"
require_file "$PROMPT_FILE"
require_file "$AGENT_LOG"

# Reviewer benefits from higher effort
export AGENT_EFFORT="${AGENT_EFFORT:-high}"

log_info "Reviewer agent starting..."

while true; do
  TOTAL=$(total_tasks)
  DONE=$(count_tasks "Done")

  # All done?
  if [[ "$DONE" -eq "$TOTAL" && "$TOTAL" -gt 0 ]]; then
    log_ok "All $TOTAL tasks reviewed and approved. Shutting down."
    notify "Reviewer" "All $TOTAL tasks reviewed and approved." "success"
    exit 0
  fi

  # Find a task "In Review"
  TASK_ID=$(find_task "In Review")

  if [ -z "$TASK_ID" ]; then
    log_wait "Nothing to review ($DONE/$TOTAL done). Polling in 60s."
    sleep 60
    continue
  fi

  TASK_CONTENT=$(read_task "$TASK_ID")
  if [ -z "$TASK_CONTENT" ]; then
    log_err "Task file not found: tasks/$TASK_ID.md"
    sleep 10
    continue
  fi

  # Extract worktree path from task file
  WORKTREE=$(task_worktree_path "$TASK_ID")

  # Get the diff to inject (so the agent doesn't need to run git)
  DIFF=""
  if [ -n "$WORKTREE" ] && [ -d "$PROJECT_ROOT/$WORKTREE" ]; then
    DIFF=$(git -C "$PROJECT_ROOT/$WORKTREE" diff HEAD~1..HEAD 2>/dev/null \
           || git -C "$PROJECT_ROOT/$WORKTREE" diff HEAD 2>/dev/null \
           || echo "(no diff available)")
    # Truncate very large diffs to avoid context blowup
    if [ ${#DIFF} -gt 30000 ]; then
      DIFF="${DIFF:0:30000}
... (diff truncated at 30KB — review key files manually if needed)"
    fi
  fi

  log_info "Reviewing $TASK_ID..."

  {
    cat "$PROMPT_FILE"
    echo ""
    echo "---"
    echo "## Task Under Review: $TASK_ID"
    echo ""
    echo "$TASK_CONTENT"
    echo ""
    echo "## Git Diff"
    echo '```diff'
    echo "$DIFF"
    echo '```'
  } | invoke_coding_agent

  # Check outcome from AGENT_LOG.md
  NEW_STATUS=$(task_status "$TASK_ID")

  case "$NEW_STATUS" in
    "Approved")
      log_ok "$TASK_ID approved."
      notify "Reviewer" "$TASK_ID approved" "success"
      ;;
    "Reviewed")
      log_info "$TASK_ID has review comments for Implementer to address."
      notify "Reviewer" "$TASK_ID reviewed — changes requested" "info"
      ;;
    *)
      log_info "$TASK_ID status after review: $NEW_STATUS"
      ;;
  esac

  sleep 5
done
