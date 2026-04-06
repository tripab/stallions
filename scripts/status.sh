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

# Per-role progress (requires orchestration.toml + tomlq)
if [ -f "$ORCHESTRATION_TOML" ] && command -v tomlq &>/dev/null; then
  local_roles=$(tomlq -r '.roles | to_entries[] | select(.value.type != "interactive") | .key' \
    "$ORCHESTRATION_TOML" 2>/dev/null || true)

  if [ -n "$local_roles" ]; then
    echo -e "  ${CYAN}Per-role progress:${RESET}"
    while IFS= read -r role; do
      local_tags=$(role_config_get "$role" "tags")

      # Count tasks for this role by looking at tags column
      local_pending=0 local_in_review=0 local_reviewed=0 local_approved=0 local_done=0

      if [ -n "$local_tags" ] && [ "$local_tags" != "*" ]; then
        # Use awk to count tagged tasks per status
        read -r local_pending local_in_review local_reviewed local_approved local_done < <(
          awk -F'|' -v tags="$local_tags" '
            /^\|[- ]+\|/ { next }
            /^[|] *TASK-/ {
              gsub(/^[ \t]+|[ \t]+$/, "", $5)  # Status
              gsub(/^[ \t]+|[ \t]+$/, "", $7)  # Tags (col 7)
              task_tag = $7
              matched = 0
              n = split(tags, role_tags, ",")
              for (i = 1; i <= n; i++) {
                rt = role_tags[i]
                gsub(/^[ \t]+|[ \t]+$/, "", rt)
                if (rt == "*" || index(task_tag, rt) == 1) { matched = 1; break }
              }
              if (!matched) next
              if ($5 == "Pending")   pending++
              if ($5 == "In Review") in_review++
              if ($5 == "Reviewed")  reviewed++
              if ($5 == "Approved")  approved++
              if ($5 == "Done")      done++
            }
            END { print pending+0, in_review+0, reviewed+0, approved+0, done+0 }
          ' "$AGENT_LOG"
        )
      else
        # Wildcard role (e.g. reviewer) — show overall counts
        local_pending=$PENDING
        local_in_review=$IN_REVIEW
        local_reviewed=$REVIEWED
        local_approved=$APPROVED
        local_done=$DONE
      fi

      local_total=$(( local_pending + local_in_review + local_reviewed + local_approved + local_done ))
      printf "    ${DIM}%-14s${RESET}  done=${GREEN}%s${RESET}  review=${YELLOW}%s${RESET}  pending=${DIM}%s${RESET}  total=%s\n" \
        "$role" "$local_done" "$(( local_in_review + local_reviewed ))" "$local_pending" "$local_total"
    done <<< "$local_roles"
    echo ""
  fi
fi

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
