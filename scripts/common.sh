#!/bin/bash
# common.sh — shared functions for multi-agent orchestration
# Source this from agent runner scripts: source "$(dirname "$0")/common.sh"

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AGENT_LOG="$PROJECT_ROOT/AGENT_LOG.md"
TASKS_DIR="$PROJECT_ROOT/tasks"
SIGNAL_DIR="${SIGNAL_DIR:-/tmp/claude-agents}"
PROMPTS_DIR="${PROMPTS_DIR:-$PROJECT_ROOT/prompts}"
MAX_TURNS="${MAX_TURNS:-25}"
PROVIDERS_DIR="$PROJECT_ROOT/providers"

mkdir -p "$SIGNAL_DIR"

# Parse --provider <file> from script arguments.
# Call this from runner scripts: parse_provider_arg "$@"
parse_provider_arg() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --provider)
        shift
        if [ -z "${1:-}" ]; then
          echo "Error: --provider requires a file path argument" >&2
          exit 1
        fi
        load_provider "$1"
        shift
        ;;
      *) shift ;;
    esac
  done
}

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; DIM='\033[2m'; RESET='\033[0m'

log() { echo -e "${DIM}$(date +%H:%M:%S)${RESET} $1"; }
log_ok()   { log "${GREEN}✅ $1${RESET}"; }
log_wait() { log "${YELLOW}⏳ $1${RESET}"; }
log_err()  { log "${RED}❌ $1${RESET}"; }
log_info() { log "${CYAN}ℹ  $1${RESET}"; }

# ── Task Parsing (the key token saver — bash does what Claude used to) ─────

# Find first task row matching a status pattern.
# Parses the markdown table in AGENT_LOG.md without invoking Claude.
# Usage: find_task "Pending|Reviewed"  →  prints "TASK-003" or ""
find_task() {
  local status_pattern="$1"
  [ -f "$AGENT_LOG" ] || return
  awk -F'|' -v pat="$status_pattern" '
    # Skip header rows
    /^\|[- ]+\|/ { next }
    # Match task rows with desired status
    {
      gsub(/^[ \t]+|[ \t]+$/, "", $5)  # $5 = Status column
      if ($5 ~ pat) {
        gsub(/^[ \t]+|[ \t]+$/, "", $2) # $2 = ID column
        print $2
        exit
      }
    }
  ' "$AGENT_LOG"
}

# Find all tasks matching a status.
# Usage: find_all_tasks "Done" → prints one task ID per line
find_all_tasks() {
  local status_pattern="$1"
  [ -f "$AGENT_LOG" ] || return
  awk -F'|' -v pat="$status_pattern" '
    /^\|[- ]+\|/ { next }
    {
      gsub(/^[ \t]+|[ \t]+$/, "", $5)
      if ($5 ~ pat) {
        gsub(/^[ \t]+|[ \t]+$/, "", $2)
        print $2
      }
    }
  ' "$AGENT_LOG"
}

# Count tasks by status. Usage: count_tasks "Done"
count_tasks() {
  find_all_tasks "$1" | wc -l | tr -d ' '
}

# Total task count
total_tasks() {
  [ -f "$AGENT_LOG" ] || echo 0
  awk -F'|' '/^[|] *TASK-/ { n++ } END { print n+0 }' "$AGENT_LOG"
}

# Check if a task's dependencies are all Done.
# Usage: deps_met "TASK-003" → exit code 0 if met, 1 if not
deps_met() {
  local task_id="$1"
  local deps
  deps=$(awk -F'|' -v id="$task_id" '
    { gsub(/^[ \t]+|[ \t]+$/, "", $2) }
    $2 == id {
      gsub(/^[ \t]+|[ \t]+$/, "", $6)
      print $6
    }
  ' "$AGENT_LOG")

  # No dependencies or just a dash
  [[ -z "$deps" || "$deps" == "-" || "$deps" == "—" ]] && return 0

  # Check each dependency
  local IFS=','
  for dep in $deps; do
    dep=$(echo "$dep" | tr -d ' ')
    local dep_status
    dep_status=$(awk -F'|' -v id="$dep" '
      { gsub(/^[ \t]+|[ \t]+$/, "", $2) }
      $2 == id { gsub(/^[ \t]+|[ \t]+$/, "", $5); print $5 }
    ' "$AGENT_LOG")
    [[ "$dep_status" == "Done" ]] || return 1
  done
  return 0
}

# Find first actionable task: status matches pattern AND deps are met.
find_actionable_task() {
  local status_pattern="$1"
  local candidates
  candidates=$(find_all_tasks "$status_pattern")
  for task_id in $candidates; do
    if deps_met "$task_id"; then
      echo "$task_id"
      return
    fi
  done
}

# Detect whether the Task Index has a Tags column (v3) or not (v2).
# Returns the column index for Tags (7 in v3), or 0 if absent.
_tags_column() {
  [ -f "$AGENT_LOG" ] || echo 0
  awk -F'|' '
    /^\| *ID *\|/ {
      # Count non-empty pipe-separated fields in the header row
      print NF - 1
      exit
    }
  ' "$AGENT_LOG"
}

# Find first task matching a status pattern AND matching the given role tags.
# Handles hierarchical prefix matching and the "*" wildcard.
# Also respects deps_met().
#
# Usage: find_tagged_task "Pending|Reviewed" "backend"
#        find_tagged_task "In Review" "*"
#
# Returns the first matching task ID, or empty string.
find_tagged_task() {
  local status_pattern="$1"
  local role_tags="$2"   # comma-separated role tags, or "*"

  [ -f "$AGENT_LOG" ] || return

  # Detect number of columns so we know where Tags lives
  local ncols
  ncols=$(_tags_column)

  # Tags column is only present when ncols >= 6 (v3 schema: ID Title Phase Status DepsOn Tags)
  local tags_col=0
  [ "$ncols" -ge 6 ] && tags_col=7

  local candidates
  candidates=$(find_all_tasks "$status_pattern")

  for task_id in $candidates; do
    # Dependency check first (cheap)
    deps_met "$task_id" || continue

    # If no Tags column or role_tags is wildcard, any task qualifies
    if [ "$tags_col" -eq 0 ] || [ "$role_tags" = "*" ]; then
      echo "$task_id"
      return
    fi

    # Read the task's Tags field from AGENT_LOG
    local task_tags
    task_tags=$(awk -F'|' -v id="$task_id" -v col="$tags_col" '
      /^\|[- ]+\|/ { next }
      {
        gsub(/^[ \t]+|[ \t]+$/, "", $2)
        if ($2 == id) {
          gsub(/^[ \t]+|[ \t]+$/, "", $col)
          print $col
          exit
        }
      }
    ' "$AGENT_LOG")

    # A task with no tags can be claimed by any agent (v2 compat)
    if [ -z "$task_tags" ] || [ "$task_tags" = "—" ] || [ "$task_tags" = "-" ]; then
      echo "$task_id"
      return
    fi

    # Check each role tag against each task tag using prefix matching
    local IFS_SAVE="$IFS"
    IFS=','
    local role_tag
    for role_tag in $role_tags; do
      role_tag="${role_tag// /}"   # strip spaces
      [ -z "$role_tag" ] && continue
      local task_tag
      for task_tag in $task_tags; do
        task_tag="${task_tag// /}"
        [ -z "$task_tag" ] && continue
        # Prefix match: task_tag starts with role_tag
        case "$task_tag" in
          "${role_tag}"*) IFS="$IFS_SAVE"; echo "$task_id"; return ;;
        esac
      done
    done
    IFS="$IFS_SAVE"
  done
}

# Check for pending design questions across all task files.
# Returns the task ID that has a pending question, or empty.
find_pending_question() {
  grep -rl "Status: Pending" "$TASKS_DIR"/ 2>/dev/null \
    | head -1 \
    | sed 's|.*/\(TASK-[0-9]*\)\.md|\1|'
}

# Read a task file's content. Usage: read_task "TASK-003"
read_task() {
  local task_file="$TASKS_DIR/$1.md"
  [ -f "$task_file" ] && cat "$task_file"
}

# Extract the title from a task file header (first H1 line).
# Usage: task_title "TASK-003" → "Network layer base client"
task_title() {
  local task_file="$TASKS_DIR/$1.md"
  [ -f "$task_file" ] || return
  sed -n 's/^# *TASK-[0-9]*: *//p' "$task_file" | head -1
}

# Extract the worktree path from a task file.
# Usage: task_worktree_path "TASK-003" → ".worktrees/phase-2-networking"
task_worktree_path() {
  local task_file="$TASKS_DIR/$1.md"
  [ -f "$task_file" ] || return
  awk '/Worktree:/ {gsub(/.*Worktree:[[:space:]]*/, "", $0); print $1; exit}' "$task_file" | head -1
}

# Get current status of a task from AGENT_LOG.md.
# Usage: task_status "TASK-003" → "Approved"
task_status() {
  local task_id="$1"
  awk -F'|' -v id="$task_id" '
    /^\|[- ]+\|/ { next }
    {
      gsub(/^[ \t]+|[ \t]+$/, "", $2)
      if ($2 == id) { gsub(/^[ \t]+|[ \t]+$/, "", $5); print $5; exit }
    }
  ' "$AGENT_LOG"
}

# Update a task's status in AGENT_LOG.md Task Index table.
# Usage: update_task_status "TASK-003" "Done"
update_task_status() {
  local task_id="$1" new_status="$2"
  [ -f "$AGENT_LOG" ] || return 1

  # Use awk to find the row and replace the status column in-place
  local tmp="$AGENT_LOG.tmp.$$"
  awk -F'|' -v OFS='|' -v id="$task_id" -v ns="$new_status" '
    {
      tid = $2; gsub(/^[ \t]+|[ \t]+$/, "", tid)
      if (tid == id) {
        # Preserve column widths by padding the new status
        old = $5
        gsub(/[^ \t]/, "", old)           # keep only whitespace
        pad = length(old) - length(ns)
        if (pad < 0) pad = 0
        $5 = " " ns sprintf("%" pad "s", "")
      }
      print
    }
  ' "$AGENT_LOG" > "$tmp" && mv "$tmp" "$AGENT_LOG"
}

# Append an entry to the Activity Log section in AGENT_LOG.md.
# Usage: append_activity_log "Implementer" "TASK-003 committed and Done"
append_activity_log() {
  local agent="$1" message="$2"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M')
  echo "- [$timestamp] $agent: $message" >> "$AGENT_LOG"
}

# ── Phase Transition (merge completed phases forward) ──────────────────────

# AGENT_LOG Task Index columns: | ID | Title | Phase | Status | Depends On |
#                           col:   2     3       4       5        6

# Get phase number for a task. Usage: task_phase "TASK-003" → "2"
task_phase() {
  local task_id="$1"
  awk -F'|' -v id="$task_id" '
    /^\|[- ]+\|/ { next }
    {
      gsub(/^[ \t]+|[ \t]+$/, "", $2)  # ID
      gsub(/^[ \t]+|[ \t]+$/, "", $4)  # Phase
      if ($2 == id) { print $4; exit }
    }
  ' "$AGENT_LOG"
}

# Check if all tasks in a given phase are Done.
# Usage: phase_complete 1 → exit code 0 if all phase-1 tasks are Done
phase_complete() {
  local phase="$1"
  local not_done
  not_done=$(awk -F'|' -v ph="$phase" '
    /^\|[- ]+\|/ { next }
    {
      gsub(/^[ \t]+|[ \t]+$/, "", $4)  # Phase
      gsub(/^[ \t]+|[ \t]+$/, "", $5)  # Status
      if ($4 == ph && $5 != "Done") { n++ }
    }
    END { print n+0 }
  ' "$AGENT_LOG")
  [[ "$not_done" -eq 0 ]]
}

# Get the branch name for a phase from the Phases & Worktrees table.
# Usage: phase_branch 1 → "phase/1-foundation"
phase_branch() {
  local phase="$1"
  awk -F'|' -v ph="$phase" '
    /^\|[- ]+\|/ { next }
    {
      gsub(/^[ \t]+|[ \t]+$/, "", $2)  # Phase number
      gsub(/^[ \t]+|[ \t]+$/, "", $5)  # Branch
      if ($2 == ph) { print $5; exit }
    }
  ' "$AGENT_LOG"
}

# Get the worktree path for a phase.
# Usage: phase_worktree 2 → ".worktrees/phase-2-networking"
phase_worktree() {
  local phase="$1"
  awk -F'|' -v ph="$phase" '
    /^\|[- ]+\|/ { next }
    {
      gsub(/^[ \t]+|[ \t]+$/, "", $2)  # Phase number
      gsub(/^[ \t]+|[ \t]+$/, "", $4)  # Worktree Path
      if ($2 == ph) { print $4; exit }
    }
  ' "$AGENT_LOG"
}

# Get all phase numbers (sorted, unique).
all_phases() {
  awk -F'|' '
    /^\|[- ]+\|/ { next }
    /^[|] *TASK-/ {
      gsub(/^[ \t]+|[ \t]+$/, "", $4)
      phases[$4] = 1
    }
    END { for (p in phases) print p }
  ' "$AGENT_LOG" | sort -n
}

# Ensure all completed phases before phase N are merged into main and
# main is merged into the phase N worktree.
#
# Flow:
#   for each phase P < target_phase:
#     if phase P is complete and not yet merged:
#       git checkout main && git merge phase/P-slug
#   git -C .worktrees/phase-N-slug merge main
#
# This is idempotent — re-merging an already-merged branch is a no-op.
#
# Usage: ensure_phases_merged 2
ensure_phases_merged() {
  local target_phase="$1"
  local current_branch
  current_branch=$(git -C "$PROJECT_ROOT" branch --show-current)

  local merged_any=false

  for phase in $(all_phases); do
    [[ "$phase" -ge "$target_phase" ]] && break

    if phase_complete "$phase"; then
      local branch
      branch=$(phase_branch "$phase")
      if [ -z "$branch" ]; then
        log_err "Could not find branch for phase $phase"
        continue
      fi

      # Check if already merged (git merge-base --is-ancestor)
      if git -C "$PROJECT_ROOT" merge-base --is-ancestor "$branch" main 2>/dev/null; then
        continue  # already merged
      fi

      log_info "Phase $phase complete — merging $branch into main..."
      git -C "$PROJECT_ROOT" checkout main
      if git -C "$PROJECT_ROOT" merge "$branch" -m "Merge phase $phase ($branch) into main"; then
        log_ok "Merged $branch into main"
        merged_any=true
      else
        log_err "Merge conflict merging $branch into main! Resolve manually."
        git -C "$PROJECT_ROOT" merge --abort 2>/dev/null
        git -C "$PROJECT_ROOT" checkout "$current_branch" 2>/dev/null
        return 1
      fi
    fi
  done

  # Restore original branch
  git -C "$PROJECT_ROOT" checkout "$current_branch" 2>/dev/null || true

  # If we merged anything, update the target phase's worktree with main
  if [ "$merged_any" = true ]; then
    local target_worktree
    target_worktree=$(phase_worktree "$target_phase")
    if [ -n "$target_worktree" ] && [ -d "$PROJECT_ROOT/$target_worktree" ]; then
      log_info "Updating phase $target_phase worktree with merged main..."
      if git -C "$PROJECT_ROOT/$target_worktree" merge main -m "Sync main (prior phases) into phase $target_phase"; then
        log_ok "Phase $target_phase worktree updated with all prior phase code"
      else
        log_err "Merge conflict updating phase $target_phase worktree! Resolve manually."
        git -C "$PROJECT_ROOT/$target_worktree" merge --abort 2>/dev/null
        return 1
      fi
    fi
  fi

  return 0
}

# ── Signal helpers ──────────────────────────────────────────────────────────

write_signal() {
  local agent="$1" signal="$2"
  echo "$signal" > "$SIGNAL_DIR/${agent}_signal.txt"
}

read_signal() {
  local agent="$1"
  cat "$SIGNAL_DIR/${agent}_signal.txt" 2>/dev/null || echo ""
}

# ── Final merge: all phases → main ────────────────────────────────────────

# Merge every completed phase into main. Called at project completion.
# Unlike ensure_phases_merged (which targets one phase), this merges all.
merge_all_phases() {
  local current_branch
  current_branch=$(git -C "$PROJECT_ROOT" branch --show-current)

  local any_failed=false

  for phase in $(all_phases); do
    if ! phase_complete "$phase"; then
      log_err "Phase $phase is not fully complete — skipping merge."
      any_failed=true
      continue
    fi

    local branch
    branch=$(phase_branch "$phase")
    [ -z "$branch" ] && continue

    if git -C "$PROJECT_ROOT" merge-base --is-ancestor "$branch" main 2>/dev/null; then
      log_info "Phase $phase ($branch) already merged into main."
      continue
    fi

    log_info "Merging phase $phase ($branch) into main..."
    git -C "$PROJECT_ROOT" checkout main
    if git -C "$PROJECT_ROOT" merge "$branch" -m "Merge phase $phase ($branch) into main"; then
      log_ok "Merged $branch into main"
    else
      log_err "Merge conflict on $branch! Resolve manually, then re-run."
      git -C "$PROJECT_ROOT" merge --abort 2>/dev/null
      git -C "$PROJECT_ROOT" checkout "$current_branch" 2>/dev/null
      return 1
    fi
  done

  git -C "$PROJECT_ROOT" checkout main 2>/dev/null || true

  if [ "$any_failed" = false ]; then
    log_ok "All phases merged into main."
  fi
  return 0
}

# ── Notifications ──────────────────────────────────────────────────────────

# Send a notification when an agent completes a meaningful action.
# Uses terminal bell + OS-native notification. Set NOTIFY=0 to disable.
#
# Usage: notify "Implementer" "TASK-003 committed" ["success"|"info"|"error"]
notify() {
  [[ "${NOTIFY:-1}" == "0" ]] && return

  local agent="$1" message="$2" level="${3:-success}"
  local title="[$agent] $level"

  # Terminal bell (works in all terminals, catches attention even if minimized)
  printf '\a'

  # OS-native notification (best-effort, never fails the script)
  if command -v osascript &>/dev/null; then
    # macOS
    osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
  elif command -v notify-send &>/dev/null; then
    # Linux (libnotify)
    local urgency="normal"
    [[ "$level" == "error" ]] && urgency="critical"
    notify-send -u "$urgency" "$title" "$message" 2>/dev/null || true
  fi

  # Also plays a short system sound on macOS for extra salience
  if [[ "$level" == "success" ]] && command -v afplay &>/dev/null; then
    afplay /System/Library/Sounds/Glass.aiff &>/dev/null &
  elif [[ "$level" == "error" ]] && command -v afplay &>/dev/null; then
    afplay /System/Library/Sounds/Basso.aiff &>/dev/null &
  fi
}

# ── Provider-agnostic agent invocation ─────────────────────────────────────

# Load a provider config file that defines how to invoke the coding agent.
# The config file is a shell script that MUST define a function:
#
#   invoke_coding_agent <prompt_file_or_-> [extra_args...]
#
# The function receives the prompt on stdin (piped) and should run the
# coding agent in non-interactive print mode.
#
# Usage: load_provider /path/to/provider.sh
#   Then call: invoke_coding_agent < prompt.md
#
# If no provider is loaded, defaults to Claude Code.

_PROVIDER_LOADED=false

load_provider() {
  local provider_file="$1"
  if [ ! -f "$provider_file" ]; then
    log_err "Provider config not found: $provider_file"
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$provider_file"
  if ! declare -f invoke_coding_agent &>/dev/null; then
    log_err "Provider config must define invoke_coding_agent(). See providers/claude.sh for example."
    exit 1
  fi
  _PROVIDER_LOADED=true
  log_info "Loaded provider: $provider_file"
}

# Default implementation (Claude Code) — used if no provider file is loaded.
if ! declare -f invoke_coding_agent &>/dev/null; then
  invoke_coding_agent() {
    local max_turns="${AGENT_MAX_TURNS:-$MAX_TURNS}"
    local allowed_tools="${AGENT_ALLOWED_TOOLS:-Bash,Read,Write,Edit,Glob,Grep,MultiEdit}"
    local model="${AGENT_MODEL:-sonnet}"
    local effort="${AGENT_EFFORT:-}"

    local cmd=(claude --model "$model" --print --max-turns "$max_turns"
               --allowedTools "$allowed_tools")
    [[ -n "$effort" ]] && cmd+=(--effort "$effort")

    "${cmd[@]}"
  }
fi

# ── Guard ───────────────────────────────────────────────────────────────────

require_file() {
  if [ ! -f "$1" ]; then
    log_err "Required file not found: $1"
    exit 1
  fi
}

# ── Graceful shutdown ───────────────────────────────────────────────────────

_cleanup() {
  log_info "Caught interrupt, shutting down..."
  exit 0
}
trap _cleanup SIGINT SIGTERM
