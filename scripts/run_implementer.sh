#!/bin/bash
# run_implementer.sh — Pre-filters tasks in bash, invokes coding agent with minimal context.
#
# Usage:
#   ./scripts/run_implementer.sh                          # default (Claude Code)
#   ./scripts/run_implementer.sh --provider providers/opencode.sh
#
# Token savings vs v1:
#   - Agent never reads AGENT_LOG.md (bash parses it)
#   - Agent never scans for actionable tasks (bash finds them)
#   - Static instructions are ~60% shorter
#   - Only the single relevant task file is injected

source "$(dirname "$0")/common.sh"
parse_provider_arg "$@"

AGENT="implementer"
PROMPT_FILE="$PROMPTS_DIR/implementer.md"
require_file "$PROMPT_FILE"
require_file "$AGENT_LOG"

log_info "Implementer agent starting..."

while true; do
  TOTAL=$(total_tasks)
  DONE=$(count_tasks "Done")
  log_info "Progress: $DONE/$TOTAL tasks done"

  # ── Phase 1: Shell-side task selection (zero agent tokens) ─────────────

  # Check if everything is done
  if [[ "$DONE" -eq "$TOTAL" && "$TOTAL" -gt 0 ]]; then
    log_ok "All $TOTAL tasks complete."

    # Merge all phases into main before exiting
    log_info "Merging all phase branches into main..."
    if merge_all_phases; then
      notify "Implementer" "All $TOTAL tasks done. All phases merged into main." "success"
    else
      notify "Implementer" "All tasks done but final merge needs manual resolution." "error"
    fi

    log_ok "Implementer shutting down."
    exit 0
  fi

  # Highest priority: recover crashed "Approved" tasks (commit only, zero tokens)
  TASK_ID=$(find_task "Approved")
  if [ -n "$TASK_ID" ]; then
    TITLE=$(task_title "$TASK_ID")
    WORKTREE=$(task_worktree_path "$TASK_ID")

    if [ -z "$WORKTREE" ] || [ ! -d "$PROJECT_ROOT/$WORKTREE" ]; then
      log_err "$TASK_ID approved but worktree not found at $WORKTREE. Skipping."
      sleep 10
      continue
    fi

    log_info "$TASK_ID is Approved — committing in bash (zero tokens)..."

    # Phase merge check (in case this is a new phase)
    TASK_PHASE=$(task_phase "$TASK_ID")
    if [ -n "$TASK_PHASE" ] && [ "$TASK_PHASE" -gt 1 ]; then
      if ! ensure_phases_merged "$TASK_PHASE"; then
        log_err "Phase merge failed for phase $TASK_PHASE. Resolve conflicts and retry."
        notify "Implementer" "Phase merge conflict on phase $TASK_PHASE" "error"
        sleep 30
        continue
      fi
    fi

    # Commit
    cd "$PROJECT_ROOT/$WORKTREE"
    git add -A
    if git diff --cached --quiet 2>/dev/null; then
      log_info "$TASK_ID has no uncommitted changes (may have been committed already)."
    else
      git commit -m "feat($TASK_ID): $TITLE"
      log_ok "$TASK_ID committed."
    fi
    cd "$PROJECT_ROOT"

    # Update AGENT_LOG.md
    update_task_status "$TASK_ID" "Done"
    append_activity_log "Implementer" "$TASK_ID committed and Done (crash recovery)"

    log_ok "$TASK_ID → Done (zero tokens spent)"
    notify "Implementer" "$TASK_ID committed (crash recovery)" "success"
    sleep 2
    continue
  fi

  # Second priority: address reviewer feedback on "Reviewed" tasks
  TASK_ID=$(find_actionable_task "Reviewed")
  MODE="review_fixup"

  # Third priority: start a new "Pending" task with met dependencies
  if [ -z "$TASK_ID" ]; then
    TASK_ID=$(find_actionable_task "Pending")
    MODE="fresh"
  fi

  # No actionable task — determine why without invoking the agent
  if [ -z "$TASK_ID" ]; then
    IN_REVIEW=$(count_tasks "In Review")
    if [ "$IN_REVIEW" -gt 0 ]; then
      log_wait "Tasks blocked on review ($IN_REVIEW in review). Retrying in 90s."
      sleep 90
      continue
    fi

    PENDING_Q=$(find_pending_question)
    if [ -n "$PENDING_Q" ]; then
      log_wait "Design question pending on $PENDING_Q. Waiting 60s for Architect."
      sleep 60
      continue
    fi

    log_wait "No actionable tasks. Retrying in 30s."
    sleep 30
    continue
  fi

  # ── Phase 1.5: Ensure prior phases are merged into this worktree ───────

  TASK_PHASE=$(task_phase "$TASK_ID")
  if [ -n "$TASK_PHASE" ] && [ "$TASK_PHASE" -gt 1 ]; then
    if ! ensure_phases_merged "$TASK_PHASE"; then
      log_err "Phase merge failed for phase $TASK_PHASE. Resolve conflicts and retry."
      notify "Implementer" "Phase merge conflict on phase $TASK_PHASE" "error"
      sleep 30
      continue
    fi
  fi

  # ── Phase 2: Build minimal prompt and invoke coding agent ──────────────

  TASK_CONTENT=$(read_task "$TASK_ID")
  if [ -z "$TASK_CONTENT" ]; then
    log_err "Task file not found: tasks/$TASK_ID.md"
    sleep 10
    continue
  fi

  log_info "Picked $TASK_ID (mode: $MODE)"

  # Construct the dynamic prompt: static instructions + task content only
  {
    cat "$PROMPT_FILE"
    echo ""
    echo "---"
    echo "## Active Task: $TASK_ID"
    echo "**Mode**: $MODE"
    echo ""
    echo "$TASK_CONTENT"
  } | invoke_coding_agent

  EXIT_CODE=$?

  # ── Phase 3: Post-run — determine outcome from AGENT_LOG.md ────────────

  CURRENT_STATUS=$(task_status "$TASK_ID")

  case "$CURRENT_STATUS" in
    "Done")
      log_ok "$TASK_ID committed. Moving to next task."
      notify "Implementer" "$TASK_ID done and committed" "success"
      sleep 2
      ;;
    "In Review")
      log_info "$TASK_ID submitted for review."
      notify "Implementer" "$TASK_ID ready for review" "info"
      sleep 5
      ;;
    "Approved")
      # Agent finished but didn't commit (may happen with some providers)
      log_info "$TASK_ID approved but not yet committed. Will commit next loop."
      sleep 2
      ;;
    *)
      if [ $EXIT_CODE -ne 0 ]; then
        log_err "Agent exited with code $EXIT_CODE on $TASK_ID. Retrying in 30s."
        notify "Implementer" "$TASK_ID agent error (exit $EXIT_CODE)" "error"
        sleep 30
      else
        log_info "$TASK_ID status: $CURRENT_STATUS. Continuing in 10s."
        sleep 10
      fi
      ;;
  esac
done
