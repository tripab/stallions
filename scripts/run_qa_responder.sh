#!/bin/bash
# run_qa_responder.sh — Answers design questions without keeping an architect session alive.
#
# Why this exists:
#   The original architect.md had a Phase E that polled for questions every 2 minutes
#   inside an interactive session. This accumulated context indefinitely. Instead, this
#   script runs one-shot invocations: find question → answer → exit. Zero accumulation.
#
# Usage: Run alongside implementer/reviewer, or on-demand.
#   ./scripts/run_qa_responder.sh                              # loop mode (default)
#   ./scripts/run_qa_responder.sh --once                       # single pass then exit
#   ./scripts/run_qa_responder.sh --provider providers/codex.sh

source "$(dirname "$0")/common.sh"

LOOP_MODE=true
for arg in "$@"; do
  [[ "$arg" == "--once" ]] && LOOP_MODE=false
done
parse_provider_arg "$@"

# QA needs minimal tools
export AGENT_ALLOWED_TOOLS="${AGENT_ALLOWED_TOOLS:-Read,Write,Edit}"
export AGENT_MAX_TURNS="${AGENT_MAX_TURNS:-10}"

POLL_INTERVAL="${QA_POLL_INTERVAL:-120}"

log_info "QA Responder starting (poll interval: ${POLL_INTERVAL}s)..."

answer_question() {
  local task_file="$1"
  local task_id
  task_id=$(basename "$task_file" .md)

  log_info "Answering design question in $task_id..."

  # Extract only the Design Q&A section to minimize tokens
  local qa_section
  qa_section=$(awk '/^## Design Q&A/,/^## [^D]/' "$task_file" | head -50)

  # Also grab description + acceptance criteria for context
  local task_context
  task_context=$(awk '/^# TASK-/,/^## (Implementer|Test Results)/' "$task_file" | head -40)

  {
    echo "You are the Architect for <project-name>."
    echo "A design question needs answering. Read IMPLEMENTATION_PLAN.md for architectural context if needed."
    echo ""
    echo "Task context:"
    echo "$task_context"
    echo ""
    echo "Question to answer:"
    echo "$qa_section"
    echo ""
    echo "Instructions:"
    echo "1. Answer the pending question concisely in the task file ($task_file)."
    echo "2. Change its Status from 'Pending' to 'Answered'."
    echo "3. Append one line to AGENT_LOG.md Activity Log."
    echo "4. Stop."
  } | invoke_coding_agent

  log_ok "Answered question in $task_id"
  notify "Architect" "Design question answered in $task_id" "info"
}

while true; do
  # Find task files with pending questions
  PENDING_FILES=$(grep -rl "Status: Pending" "$TASKS_DIR"/ 2>/dev/null || true)

  if [ -z "$PENDING_FILES" ]; then
    if [ "$LOOP_MODE" = false ]; then
      log_info "No pending questions. Exiting."
      exit 0
    fi
    log_wait "No pending questions. Checking in ${POLL_INTERVAL}s."
    sleep "$POLL_INTERVAL"
    continue
  fi

  # Answer each pending question as a separate one-shot invocation
  for task_file in $PENDING_FILES; do
    answer_question "$task_file"
    sleep 3
  done

  if [ "$LOOP_MODE" = false ]; then
    exit 0
  fi

  sleep "$POLL_INTERVAL"
done
