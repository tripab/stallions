#!/bin/bash
# status.sh — Show current task progress at a glance.
# Zero Claude tokens. Pure bash.

source "$(dirname "$0")/common.sh"

if [ ! -f "$AGENT_LOG" ]; then
  log_err "AGENT_LOG.md not found. Has the Architect run yet?"
  exit 1
fi

TOTAL=$(total_tasks)
DONE=$(count_tasks "Done")
IN_REVIEW=$(count_tasks "In Review")
REVIEWED=$(count_tasks "Reviewed")
PENDING=$(count_tasks "Pending")
APPROVED=$(count_tasks "Approved")

PROGRESS=0
[[ "$TOTAL" -gt 0 ]] && PROGRESS=$(( DONE * 100 / TOTAL ))

echo ""
echo -e "${CYAN}═══════════════════════════════════════${RESET}"
echo -e "${CYAN}  Multi-Agent Project Status${RESET}"
echo -e "${CYAN}═══════════════════════════════════════${RESET}"
echo ""
echo -e "  Progress: ${GREEN}$DONE${RESET}/$TOTAL tasks (${PROGRESS}%)"
echo ""
echo -e "  ${GREEN}Done:${RESET}        $DONE"
echo -e "  ${GREEN}Approved:${RESET}    $APPROVED"
echo -e "  ${YELLOW}In Review:${RESET}   $IN_REVIEW"
echo -e "  ${YELLOW}Reviewed:${RESET}    $REVIEWED"
echo -e "  ${DIM}Pending:${RESET}     $PENDING"
echo ""

# Show progress bar
BAR_WIDTH=35
FILLED=$(( PROGRESS * BAR_WIDTH / 100 ))
EMPTY=$(( BAR_WIDTH - FILLED ))
BAR=$(printf "%${FILLED}s" | tr ' ' '█')$(printf "%${EMPTY}s" | tr ' ' '░')
echo -e "  [${GREEN}${BAR}${RESET}] ${PROGRESS}%"
echo ""

# Pending design questions
PQ=$(find_pending_question)
if [ -n "$PQ" ]; then
  echo -e "  ${RED}⚠  Design question pending: $PQ${RESET}"
  echo ""
fi

# Last 5 activity log entries
echo -e "  ${DIM}Recent activity:${RESET}"
awk '/^- \[/' "$AGENT_LOG" | tail -5 | while read -r line; do
  echo -e "  ${DIM}  $line${RESET}"
done
echo ""
