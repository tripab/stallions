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

# ── Config loading (orchestration.toml or .env fallback) ────────────────────

ORCHESTRATION_TOML="${PROJECT_ROOT}/orchestration.toml"
LOG_LEVEL="${LOG_LEVEL:-standard}"          # minimal | standard | verbose
CAPTURE_RESPONSES="${CAPTURE_RESPONSES:-true}"

# Load project config from orchestration.toml (via tomlq) or .env fallback.
# Safe to call when no config file exists — just keeps the built-in defaults.
load_config() {
  if [ -f "$ORCHESTRATION_TOML" ] && command -v tomlq &>/dev/null; then
    _load_toml_config
  elif [ -f "$PROJECT_ROOT/.env.orchestration" ]; then
    # shellcheck disable=SC1090
    source "$PROJECT_ROOT/.env.orchestration"
  fi
}

_load_toml_config() {
  local t="$ORCHESTRATION_TOML" v

  v=$(tomlq -r '.project.log_file // empty' "$t" 2>/dev/null)
  [ -n "$v" ] && AGENT_LOG="$PROJECT_ROOT/$v"

  v=$(tomlq -r '.project.tasks_dir // empty' "$t" 2>/dev/null)
  [ -n "$v" ] && TASKS_DIR="$PROJECT_ROOT/$v"

  v=$(tomlq -r '.defaults.model // empty' "$t" 2>/dev/null)
  [ -n "$v" ] && AGENT_MODEL="$v"

  v=$(tomlq -r '.defaults.max_turns // empty' "$t" 2>/dev/null)
  [ -n "$v" ] && MAX_TURNS="$v"

  v=$(tomlq -r '.logging.level // empty' "$t" 2>/dev/null)
  [ -n "$v" ] && LOG_LEVEL="$v"

  v=$(tomlq -r '.logging.capture_responses // empty' "$t" 2>/dev/null)
  [ -n "$v" ] && CAPTURE_RESPONSES="$v"
}

# Get a config value for a role, falling back to [defaults].
# For array fields (tags), returns a comma-separated string.
# Usage: role_config_get <role_name> <field>
role_config_get() {
  local role_lc="$1"
  local field="$2"

  if [ -f "$ORCHESTRATION_TOML" ] && command -v tomlq &>/dev/null; then
    local v
    if [ "$field" = "tags" ]; then
      v=$(tomlq -r ".roles.${role_lc}.tags // [] | join(\",\")" "$ORCHESTRATION_TOML" 2>/dev/null)
    else
      v=$(tomlq -r ".roles.${role_lc}.${field} // empty" "$ORCHESTRATION_TOML" 2>/dev/null)
      # Fall back to [defaults] for scalar fields
      if [ -z "$v" ]; then
        v=$(tomlq -r ".defaults.${field} // empty" "$ORCHESTRATION_TOML" 2>/dev/null)
      fi
    fi
    [ -n "$v" ] && echo "$v" && return
  fi

  # Env var fallback: ROLE_BACKEND_PROMPT, ROLE_REVIEWER_MODEL, etc.
  local role_uc field_uc env_var default_var
  role_uc=$(echo "$role_lc" | tr '[:lower:]' '[:upper:]')
  field_uc=$(echo "$field"   | tr '[:lower:]' '[:upper:]')
  env_var="ROLE_${role_uc}_${field_uc}"
  eval "local v=\${${env_var}:-}"
  [ -n "$v" ] && echo "$v" && return

  default_var="DEFAULT_${field_uc}"
  eval "echo \"\${${default_var}:-}\""
}

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
        notify_external "phase_merged" "Phase $phase ($branch) merged into main" "good"
        merged_any=true
      else
        log_err "Merge conflict merging $branch into main! Resolve manually."
        notify_external "phase_merge_needed" "Merge conflict: $branch → main (phase $phase)" "danger"
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

# ── Task locking ─────────────────────────────────────────────────────────────

# Atomically claim a task by creating a lock directory via mkdir.
# mkdir is atomic on POSIX filesystems — only one caller wins the race.
# Usage: claim_task <task_id> <role>
# Returns: 0 on success, 1 if already claimed by another agent.
claim_task() {
  local task_id="$1"
  local role="$2"
  local lock_dir="$SIGNAL_DIR/locks/${task_id}.lock"
  mkdir -p "$SIGNAL_DIR/locks"
  if mkdir "$lock_dir" 2>/dev/null; then
    echo "$role" > "${lock_dir}/owner"
    return 0
  fi
  return 1
}

# Release a task lock created by claim_task.
# Usage: release_task <task_id>
release_task() {
  local task_id="$1"
  local lock_dir="$SIGNAL_DIR/locks/${task_id}.lock"
  rm -rf "$lock_dir"
}

# ── Mailbox functions ────────────────────────────────────────────────────────

# Send a message to another role's inbox.
# Usage: send_mail <recipient_role> <subject> <body>
send_mail() {
  local recipient_role="$1"
  local subject="$2"
  local body="$3"
  local inbox="$SIGNAL_DIR/mailboxes/${recipient_role}/inbox"
  mkdir -p "$inbox"
  local ts
  ts=$(date -u '+%Y%m%d_%H%M%S')
  local msg_file="${inbox}/${ts}_${subject}.mail"
  printf 'Subject: %s\nTimestamp: %s\n\n%s\n' "$subject" "$ts" "$body" > "$msg_file"
  log_info "Mail sent to ${recipient_role}: $subject"
}

# List unread messages in a role's inbox.
# Prints one absolute filename per line, sorted by time (oldest first).
# Usage: check_mail <role>
check_mail() {
  local role="$1"
  local inbox="$SIGNAL_DIR/mailboxes/${role}/inbox"
  [ -d "$inbox" ] || return 0
  find "$inbox" -maxdepth 1 -name '*.mail' -type f 2>/dev/null | sort
}

# Acknowledge (move) a processed message out of the inbox.
# Derives the role from the mailbox path: .../mailboxes/<role>/inbox/<file>
# Usage: ack_mail <message_file>
ack_mail() {
  local msg_file="$1"
  [ -f "$msg_file" ] || return 0
  local role
  role=$(echo "$msg_file" | sed 's|.*/mailboxes/\([^/]*\)/inbox/.*|\1|')
  local processed="$SIGNAL_DIR/mailboxes/${role}/processed"
  mkdir -p "$processed"
  mv "$msg_file" "$processed/"
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

# ── Slack notifications ──────────────────────────────────────────────────────

# Resolve the Slack channel ID for a given event type.
# Falls back to the default_channel if no specific channel is configured.
# Usage: get_slack_channel "task_in_review" → "C0GENERAL123"
get_slack_channel() {
  local event_type="$1"
  local channel=""

  if [ -f "$ORCHESTRATION_TOML" ] && command -v tomlq &>/dev/null; then
    channel=$(tomlq -r ".notifications.slack.channels.${event_type} // empty" \
      "$ORCHESTRATION_TOML" 2>/dev/null || true)
    if [ -z "$channel" ]; then
      channel=$(tomlq -r '.notifications.slack.default_channel // empty' \
        "$ORCHESTRATION_TOML" 2>/dev/null || true)
    fi
  fi

  echo "${channel:-}"
}

# Post a message to Slack, threading per-task when thread_per_task=true.
#
# Usage: notify_slack <event_type> <message> <color> [task_id]
#   event_type — matches [notifications.slack.channels] key (e.g. "task_in_review")
#   message    — plain text or mrkdwn string
#   color      — hex color or "good"/"warning"/"danger"
#   task_id    — optional; used for thread grouping
#
# Required env vars:
#   SLACK_BOT_TOKEN — OAuth bot token (xoxb-...)
#   SLACK_ENABLED   — set to "true" to actually send (default: false)
notify_slack() {
  local event_type="$1"
  local message="$2"
  local color="${3:-good}"
  local task_id="${4:-}"

  # Guard: only send when explicitly enabled
  local slack_enabled="${SLACK_ENABLED:-false}"
  [ "$slack_enabled" = "true" ] || return 0

  local token="${SLACK_BOT_TOKEN:-}"
  if [ -z "$token" ]; then
    log_err "notify_slack: SLACK_BOT_TOKEN is not set. Skipping notification."
    return 0
  fi

  local channel
  channel=$(get_slack_channel "$event_type")
  if [ -z "$channel" ]; then
    log_info "notify_slack: no channel configured for event '$event_type'. Skipping."
    return 0
  fi

  # Read Slack config for username/icon
  local username icon_emoji thread_per_task
  username=$(tomlq -r '.notifications.slack.username // "Orchestrator"' \
    "$ORCHESTRATION_TOML" 2>/dev/null || echo "Orchestrator")
  icon_emoji=$(tomlq -r '.notifications.slack.icon_emoji // ":robot_face:"' \
    "$ORCHESTRATION_TOML" 2>/dev/null || echo ":robot_face:")
  thread_per_task=$(tomlq -r '.notifications.slack.thread_per_task // true' \
    "$ORCHESTRATION_TOML" 2>/dev/null || echo "true")

  # Check for an existing thread timestamp for this task
  local thread_ts="" thread_file=""
  if [ -n "$task_id" ] && [ "$thread_per_task" = "true" ]; then
    mkdir -p "$SIGNAL_DIR/slack_threads"
    thread_file="$SIGNAL_DIR/slack_threads/${task_id}.ts"
    [ -f "$thread_file" ] && thread_ts=$(cat "$thread_file" 2>/dev/null || true)
  fi

  # Build JSON payload
  local project_name
  project_name=$(tomlq -r '.project.name // "Stallions"' \
    "$ORCHESTRATION_TOML" 2>/dev/null || echo "Stallions")

  local context_text="$project_name"
  [ -n "$task_id" ] && context_text="$project_name · $task_id"

  local payload
  payload=$(printf '{
  "channel": "%s",
  "username": "%s",
  "icon_emoji": "%s",
  "attachments": [
    {
      "color": "%s",
      "mrkdwn_in": ["text"],
      "text": "%s",
      "footer": "%s"
    }
  ]
}' \
    "$channel" \
    "$username" \
    "$icon_emoji" \
    "$color" \
    "$(echo "$message" | sed 's/"/\\"/g')" \
    "$context_text")

  # Add thread_ts to payload when replying to an existing thread
  if [ -n "$thread_ts" ]; then
    payload=$(echo "$payload" | sed "s/\"channel\"/\"thread_ts\": \"${thread_ts}\", \"channel\"/")
  fi

  # Post to Slack
  local response
  response=$(curl -s -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json; charset=utf-8" \
    --data "$payload" 2>/dev/null || true)

  # On first message for a task, save the returned ts for future threading
  if [ -n "$thread_file" ] && [ -z "$thread_ts" ] && [ -n "$response" ]; then
    local returned_ts
    returned_ts=$(echo "$response" | grep -o '"ts":"[^"]*"' | head -1 | sed 's/"ts":"//;s/"//')
    [ -n "$returned_ts" ] && echo "$returned_ts" > "$thread_file"
  fi

  # Log errors but never fail the calling script
  local ok
  ok=$(echo "$response" | grep -o '"ok":[a-z]*' | sed 's/"ok"://')
  if [ "$ok" != "true" ]; then
    local err
    err=$(echo "$response" | grep -o '"error":"[^"]*"' | sed 's/"error":"//;s/"//')
    log_err "notify_slack: Slack API error for event '$event_type': ${err:-unknown}"
  fi

  return 0
}

# ── External notification abstraction ────────────────────────────────────────

# Single call-point for all outbound notifications.
# Calls both Slack and the desktop/terminal notify().
#
# Usage: notify_external <event_type> <message> <color> [task_id]
#   event_type — Slack channel routing key (e.g. "task_in_review")
#   message    — human-readable message
#   color      — "good" | "warning" | "danger" | hex
#   task_id    — optional task ID for Slack threading
notify_external() {
  local event_type="$1"
  local message="$2"
  local color="${3:-good}"
  local task_id="${4:-}"

  # Map color to desktop notification level
  local level="info"
  case "$color" in
    good)    level="success" ;;
    danger)  level="error"   ;;
    warning) level="info"    ;;
  esac

  notify "Orchestrator" "$message" "$level"
  notify_slack "$event_type" "$message" "$color" "$task_id"
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
  AGENT_PROVIDER="$provider_file"   # record for JSONL logging
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

# ── Heartbeat ───────────────────────────────────────────────────────────────

# Write a heartbeat file so the supervisor knows this agent is alive.
# Called once per main loop iteration.
_write_heartbeat() {
  local role="${AGENT_ROLE:-agent}"
  local instance="${AGENT_INSTANCE:-0}"
  mkdir -p "$SIGNAL_DIR/heartbeats"
  date -u +%s > "$SIGNAL_DIR/heartbeats/${role}_${instance}.heartbeat"
}

# ── Hook execution ───────────────────────────────────────────────────────────

# Run a lifecycle hook script if it exists.
# Usage: run_hooks <phase> <task_id> <worktree>
# Returns non-zero if the hook script fails.
run_hooks() {
  local hook_phase="$1"
  local task_id="${2:-}"
  local worktree="${3:-}"
  local hooks_dir="${AGENT_HOOKS_DIR:-}"
  [ -z "$hooks_dir" ] && return 0
  local hook_script="$hooks_dir/${hook_phase}.sh"
  [ -f "$hook_script" ] || return 0
  log_info "Running hook: $hook_script"
  bash "$hook_script" "$task_id" "$worktree"
}

# ── Token parsing ────────────────────────────────────────────────────────────

# Parse token counts from agent output. Returns a JSON object or "null".
# Usage: parse_tokens <output_file>
parse_tokens() {
  local output_file="$1"
  [ -f "$output_file" ] || { echo "null"; return; }

  # Claude Code format: "42,300 input · 12,800 output · 8,200 cache read · 3,100 cache write"
  # Also handles: "42300 input, 12800 output (8200 cache read, 3100 cache write)"
  local input=0 output=0 cache_read=0 cache_write=0 found=false

  # Try to find a token summary line near the end of output
  local token_line
  token_line=$(grep -iE '(input|output).*(token|tok)|(token|tok).*(input|output)|tokens:' \
    "$output_file" 2>/dev/null | tail -3)

  if [ -z "$token_line" ]; then
    # Also check last 20 lines (summary may be there without "token" keyword)
    token_line=$(tail -20 "$output_file" | grep -iE '[0-9,]+ input|input[: ]+[0-9,]+')
  fi

  if [ -n "$token_line" ]; then
    # Extract numbers associated with each field
    local raw
    raw=$(echo "$token_line" | tr ',' ' ' | tr -d "'")

    input=$(echo "$raw"      | grep -oE '[0-9]+ input'      | grep -oE '[0-9]+' | head -1)
    output=$(echo "$raw"     | grep -oE '[0-9]+ output'     | grep -oE '[0-9]+' | head -1)
    cache_read=$(echo "$raw" | grep -oiE '[0-9]+ cache.?read'  | grep -oE '^[0-9]+' | head -1)
    cache_write=$(echo "$raw"| grep -oiE '[0-9]+ cache.?write' | grep -oE '^[0-9]+' | head -1)

    [ -n "$input" ] && found=true
  fi

  if [ "$found" = true ]; then
    echo "{\"input\":${input:-0},\"output\":${output:-0},\"cache_read\":${cache_read:-0},\"cache_write\":${cache_write:-0}}"
  else
    echo "null"
  fi
}

# ── Logged agent invocation ──────────────────────────────────────────────────

# Invoke the coding agent and write a versioned JSONL log entry.
#
# Usage:
#   invoke_agent_logged <prompt_file> [task_id] [mode]
#   EXIT_CODE=$?
#
# Reads:  AGENT_ROLE, AGENT_INSTANCE, AGENT_PROVIDER, AGENT_MODEL,
#         LOG_LEVEL, CAPTURE_RESPONSES
# Sets:   LAST_INVOCATION_ID, LAST_RESPONSE_FILE
invoke_agent_logged() {
  local prompt_file="$1"
  local task_id="${2:-}"
  local mode="${3:-fresh}"

  local role="${AGENT_ROLE:-implementer}"
  local instance="${AGENT_INSTANCE:-0}"
  local inv_id="inv_$(date -u '+%Y%m%d_%H%M%S')_${role}_${instance}"
  LAST_INVOCATION_ID="$inv_id"
  LAST_RESPONSE_FILE=""

  local start_ts
  start_ts=$(date -u +%s)

  # Prompt metadata
  local prompt_bytes prompt_hash
  prompt_bytes=$(wc -c < "$prompt_file" | tr -d ' ')
  prompt_hash="sha256:$(shasum -a 256 "$prompt_file" 2>/dev/null | awk '{print $1}' || echo "unknown")"

  # Response capture
  local response_tmp exit_code=0
  response_tmp=$(mktemp)

  if [ "$LOG_LEVEL" = "minimal" ]; then
    invoke_coding_agent < "$prompt_file" || exit_code=$?
  else
    # Temporarily disable pipefail so we can capture PIPESTATUS
    set +eo pipefail
    invoke_coding_agent < "$prompt_file" | tee "$response_tmp"
    exit_code=${PIPESTATUS[0]}
    set -eo pipefail
  fi

  local end_ts duration_seconds
  end_ts=$(date -u +%s)
  duration_seconds=$(( end_ts - start_ts ))

  # Parse tokens from response
  local tokens_json="null"
  [ "$LOG_LEVEL" != "minimal" ] && tokens_json=$(parse_tokens "$response_tmp")

  # Response summary + optional full capture
  local response_summary="" response_file=""
  if [ "$LOG_LEVEL" != "minimal" ] && [ -s "$response_tmp" ]; then
    response_summary=$(head -c 200 "$response_tmp" | tr '\n' ' ' | sed 's/"/'"'"'/g')
    if [ "$CAPTURE_RESPONSES" = "true" ]; then
      mkdir -p "$PROJECT_ROOT/logs/responses"
      response_file="logs/responses/${inv_id}.txt"
      cp "$response_tmp" "$PROJECT_ROOT/$response_file"
      LAST_RESPONSE_FILE="$response_file"
    fi
  fi
  rm -f "$response_tmp"

  # Context for log entry
  local phase="" worktree="" outcome=""
  if [ -n "$task_id" ]; then
    phase=$(task_phase "$task_id" 2>/dev/null || echo "")
    worktree=$(task_worktree_path "$task_id" 2>/dev/null || echo "")
    outcome=$(task_status "$task_id" 2>/dev/null || echo "")
  fi

  # Write JSONL entry (one line, double-quotes escaped)
  local entry
  entry="{\"v\":1,\"id\":\"${inv_id}\",\"timestamp\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\",\"role\":\"${role}\",\"instance\":${instance},\"task_id\":\"${task_id}\",\"mode\":\"${mode}\",\"provider\":\"${AGENT_PROVIDER:-providers/claude.sh}\",\"model\":\"${AGENT_MODEL:-sonnet}\",\"phase\":\"${phase}\",\"worktree\":\"${worktree}\",\"duration_seconds\":${duration_seconds},\"exit_code\":${exit_code},\"outcome\":\"${outcome}\",\"tokens\":${tokens_json},\"prompt_hash\":\"${prompt_hash}\",\"prompt_bytes\":${prompt_bytes},\"response_summary\":\"${response_summary}\",\"response_file\":\"${response_file}\",\"errors\":[]}"

  mkdir -p "$PROJECT_ROOT/logs/agents"
  echo "$entry" >> "$PROJECT_ROOT/logs/orchestrator.jsonl"
  echo "$entry" >> "$PROJECT_ROOT/logs/agents/${role}_${instance}.jsonl"

  return $exit_code
}

# ── Lifecycle functions ──────────────────────────────────────────────────────
# These contain the main loop bodies for each agent type. They are called by
# run_agent.sh after role config has been resolved and exported as env vars.
#
# Required env vars (set by run_agent.sh):
#   AGENT_ROLE, AGENT_INSTANCE, AGENT_PROMPT_FILE, AGENT_ROLE_TAGS,
#   AGENT_HOOKS_DIR, AGENT_LOOP_MODE, POLL_INTERVAL

# lifecycle_implementer — picks tasks, invokes agent, commits approved work
lifecycle_implementer() {
  local role="${AGENT_ROLE:-implementer}"
  local prompt_file="${AGENT_PROMPT_FILE:-$PROMPTS_DIR/implementer.md}"

  require_file "$prompt_file"
  require_file "$AGENT_LOG"

  log_info "${role} agent starting (instance ${AGENT_INSTANCE:-0})..."

  while true; do
    _write_heartbeat

    local TOTAL DONE
    TOTAL=$(total_tasks)
    DONE=$(count_tasks "Done")
    log_info "Progress: $DONE/$TOTAL tasks done"

    # All done — merge phases and exit
    if [[ "$DONE" -eq "$TOTAL" && "$TOTAL" -gt 0 ]]; then
      log_ok "All $TOTAL tasks complete."
      log_info "Merging all phase branches into main..."
      if merge_all_phases; then
        notify "${role}" "All $TOTAL tasks done. All phases merged into main." "success"
      else
        notify "${role}" "All tasks done but final merge needs manual resolution." "error"
      fi
      log_ok "${role} shutting down."
      exit 0
    fi

    # Priority 1: commit Approved tasks (zero tokens, crash recovery)
    local TASK_ID
    TASK_ID=$(find_task "Approved")
    if [ -n "$TASK_ID" ]; then
      local TITLE WORKTREE TASK_PHASE
      TITLE=$(task_title "$TASK_ID")
      WORKTREE=$(task_worktree_path "$TASK_ID")

      if [ -z "$WORKTREE" ] || [ ! -d "$PROJECT_ROOT/$WORKTREE" ]; then
        log_err "$TASK_ID approved but worktree not found at $WORKTREE. Skipping."
        sleep 10
        continue
      fi

      log_info "$TASK_ID is Approved — committing in bash (zero tokens)..."

      TASK_PHASE=$(task_phase "$TASK_ID")
      if [ -n "$TASK_PHASE" ] && [ "$TASK_PHASE" -gt 1 ]; then
        if ! ensure_phases_merged "$TASK_PHASE"; then
          log_err "Phase merge failed for phase $TASK_PHASE. Resolve conflicts and retry."
          notify "${role}" "Phase merge conflict on phase $TASK_PHASE" "error"
          sleep 30
          continue
        fi
      fi

      cd "$PROJECT_ROOT/$WORKTREE"
      git add -A
      if git diff --cached --quiet 2>/dev/null; then
        log_info "$TASK_ID has no uncommitted changes (may have been committed already)."
      else
        git commit -m "feat($TASK_ID): $TITLE"
        log_ok "$TASK_ID committed."
      fi
      cd "$PROJECT_ROOT"

      update_task_status "$TASK_ID" "Done"
      append_activity_log "${role}" "$TASK_ID committed and Done (crash recovery)"
      log_ok "$TASK_ID → Done (zero tokens)"
      notify "${role}" "$TASK_ID committed (crash recovery)" "success"
      sleep 2
      continue
    fi

    # Priority 2: address reviewer feedback (Reviewed tasks)
    local MODE
    if [ -n "${AGENT_ROLE_TAGS:-}" ]; then
      TASK_ID=$(find_tagged_task "Reviewed" "$AGENT_ROLE_TAGS")
    else
      TASK_ID=$(find_actionable_task "Reviewed")
    fi
    MODE="review_fixup"

    # Priority 3: start a new Pending task
    if [ -z "$TASK_ID" ]; then
      if [ -n "${AGENT_ROLE_TAGS:-}" ]; then
        TASK_ID=$(find_tagged_task "Pending" "$AGENT_ROLE_TAGS")
      else
        TASK_ID=$(find_actionable_task "Pending")
      fi
      MODE="fresh"
    fi

    if [ -z "$TASK_ID" ]; then
      local IN_REVIEW
      IN_REVIEW=$(count_tasks "In Review")
      if [ "$IN_REVIEW" -gt 0 ]; then
        log_wait "Tasks blocked on review ($IN_REVIEW in review). Retrying in 90s."
        sleep 90
        continue
      fi
      local PENDING_Q
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

    # Phase merge check
    local TASK_PHASE
    TASK_PHASE=$(task_phase "$TASK_ID")
    if [ -n "$TASK_PHASE" ] && [ "$TASK_PHASE" -gt 1 ]; then
      if ! ensure_phases_merged "$TASK_PHASE"; then
        log_err "Phase merge failed for phase $TASK_PHASE. Resolve conflicts and retry."
        notify "${role}" "Phase merge conflict on phase $TASK_PHASE" "error"
        sleep 30
        continue
      fi
    fi

    # Read task content
    local TASK_CONTENT
    TASK_CONTENT=$(read_task "$TASK_ID")
    if [ -z "$TASK_CONTENT" ]; then
      log_err "Task file not found: tasks/$TASK_ID.md"
      sleep 10
      continue
    fi

    log_info "Picked $TASK_ID (mode: $MODE)"
    local WORKTREE
    WORKTREE=$(task_worktree_path "$TASK_ID")

    # Pre-invoke hook
    if ! run_hooks "pre_invoke" "$TASK_ID" "$WORKTREE"; then
      log_err "pre_invoke hook failed for $TASK_ID. Skipping."
      sleep 10
      continue
    fi

    # Build prompt and invoke
    local prompt_tmp
    prompt_tmp=$(mktemp)
    {
      cat "$prompt_file"
      echo ""
      echo "---"
      echo "## Active Task: $TASK_ID"
      echo "**Mode**: $MODE"
      echo ""
      echo "$TASK_CONTENT"
    } > "$prompt_tmp"

    local EXIT_CODE=0
    invoke_agent_logged "$prompt_tmp" "$TASK_ID" "$MODE" || EXIT_CODE=$?
    rm -f "$prompt_tmp"

    # Post-invoke hook (non-fatal)
    run_hooks "post_invoke" "$TASK_ID" "$WORKTREE" || true

    local CURRENT_STATUS
    CURRENT_STATUS=$(task_status "$TASK_ID")

    case "$CURRENT_STATUS" in
      "Done")
        log_ok "$TASK_ID committed. Moving to next task."
        notify_external "task_committed" "$TASK_ID done and committed" "good" "$TASK_ID"
        sleep 2
        ;;
      "In Review")
        log_info "$TASK_ID submitted for review."
        notify_external "task_in_review" "$TASK_ID ready for review" "warning" "$TASK_ID"
        sleep 5
        ;;
      "Approved")
        log_info "$TASK_ID approved but not yet committed. Will commit next loop."
        sleep 2
        ;;
      *)
        if [ "$EXIT_CODE" -ne 0 ]; then
          log_err "Agent exited with code $EXIT_CODE on $TASK_ID. Retrying in 30s."
          notify "${role}" "$TASK_ID agent error (exit $EXIT_CODE)" "error"
          sleep 30
        else
          log_info "$TASK_ID status: $CURRENT_STATUS. Continuing in 10s."
          sleep 10
        fi
        ;;
    esac
  done
}

# lifecycle_reviewer — reviews tasks in "In Review" status
lifecycle_reviewer() {
  local role="${AGENT_ROLE:-reviewer}"
  local prompt_file="${AGENT_PROMPT_FILE:-$PROMPTS_DIR/reviewer.md}"

  require_file "$prompt_file"
  require_file "$AGENT_LOG"

  export AGENT_EFFORT="${AGENT_EFFORT:-high}"

  log_info "${role} agent starting (instance ${AGENT_INSTANCE:-0})..."

  while true; do
    _write_heartbeat

    local TOTAL DONE
    TOTAL=$(total_tasks)
    DONE=$(count_tasks "Done")

    if [[ "$DONE" -eq "$TOTAL" && "$TOTAL" -gt 0 ]]; then
      log_ok "All $TOTAL tasks reviewed and approved. Shutting down."
      notify "${role}" "All $TOTAL tasks reviewed and approved." "success"
      exit 0
    fi

    local TASK_ID
    TASK_ID=$(find_task "In Review")

    if [ -z "$TASK_ID" ]; then
      log_wait "Nothing to review ($DONE/$TOTAL done). Polling in 60s."
      sleep 60
      continue
    fi

    local TASK_CONTENT
    TASK_CONTENT=$(read_task "$TASK_ID")
    if [ -z "$TASK_CONTENT" ]; then
      log_err "Task file not found: tasks/$TASK_ID.md"
      sleep 10
      continue
    fi

    local WORKTREE
    WORKTREE=$(task_worktree_path "$TASK_ID")

    local DIFF=""
    if [ -n "$WORKTREE" ] && [ -d "$PROJECT_ROOT/$WORKTREE" ]; then
      DIFF=$(git -C "$PROJECT_ROOT/$WORKTREE" diff HEAD~1..HEAD 2>/dev/null \
             || git -C "$PROJECT_ROOT/$WORKTREE" diff HEAD 2>/dev/null \
             || echo "(no diff available)")
      if [ ${#DIFF} -gt 30000 ]; then
        DIFF="${DIFF:0:30000}
... (diff truncated at 30KB — review key files manually if needed)"
      fi
    fi

    log_info "Reviewing $TASK_ID..."

    run_hooks "pre_invoke" "$TASK_ID" "$WORKTREE" || true

    local prompt_tmp
    prompt_tmp=$(mktemp)
    {
      cat "$prompt_file"
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
    } > "$prompt_tmp"

    invoke_agent_logged "$prompt_tmp" "$TASK_ID" "review" || true
    rm -f "$prompt_tmp"

    run_hooks "post_invoke" "$TASK_ID" "$WORKTREE" || true

    local NEW_STATUS
    NEW_STATUS=$(task_status "$TASK_ID")

    case "$NEW_STATUS" in
      "Approved")
        log_ok "$TASK_ID approved."
        notify_external "review_approved" "$TASK_ID approved" "good" "$TASK_ID"
        ;;
      "Reviewed")
        log_info "$TASK_ID has review comments for Implementer to address."
        notify_external "review_submitted" "$TASK_ID reviewed — changes requested" "warning" "$TASK_ID"
        ;;
      *)
        log_info "$TASK_ID status after review: $NEW_STATUS"
        ;;
    esac

    sleep 5
  done
}

# _qa_answer_question — one-shot answer for a single design question
_qa_answer_question() {
  local task_file="$1"
  local task_id
  task_id=$(basename "$task_file" .md)

  log_info "Answering design question in $task_id..."

  local qa_section task_context
  qa_section=$(awk '/^## Design Q&A/,/^## [^D]/' "$task_file" | head -50)
  task_context=$(awk '/^# TASK-/,/^## (Implementer|Test Results)/' "$task_file" | head -40)

  local prompt_tmp
  prompt_tmp=$(mktemp)
  {
    if [ -f "${AGENT_PROMPT_FILE:-}" ]; then
      cat "$AGENT_PROMPT_FILE"
      echo ""
      echo "---"
      echo "## Task requiring an answer:"
      echo "File: $task_file"
    else
      echo "You are the Architect for this project."
      echo "A design question needs answering. Read IMPLEMENTATION_PLAN.md for architectural context if needed."
    fi
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
  } > "$prompt_tmp"

  invoke_agent_logged "$prompt_tmp" "$task_id" "qa" || true
  rm -f "$prompt_tmp"

  log_ok "Answered question in $task_id"
  notify "${AGENT_ROLE:-qa}" "Design question answered in $task_id" "info"
}

# lifecycle_qa_responder — answers design questions with one-shot invocations
lifecycle_qa_responder() {
  local poll_interval="${POLL_INTERVAL:-120}"
  local loop_mode="${AGENT_LOOP_MODE:-true}"

  export AGENT_ALLOWED_TOOLS="${AGENT_ALLOWED_TOOLS:-Read,Write,Edit}"
  export AGENT_MAX_TURNS="${AGENT_MAX_TURNS:-10}"

  log_info "QA Responder starting (poll interval: ${poll_interval}s)..."

  while true; do
    _write_heartbeat

    local pending_files
    pending_files=$(grep -rl "Status: Pending" "$TASKS_DIR"/ 2>/dev/null || true)

    if [ -z "$pending_files" ]; then
      if [ "$loop_mode" = "false" ]; then
        log_info "No pending questions. Exiting."
        exit 0
      fi
      log_wait "No pending questions. Checking in ${poll_interval}s."
      sleep "$poll_interval"
      continue
    fi

    for task_file in $pending_files; do
      _qa_answer_question "$task_file"
      sleep 3
    done

    if [ "$loop_mode" = "false" ]; then
      exit 0
    fi

    sleep "$poll_interval"
  done
}

# ── Graceful shutdown ───────────────────────────────────────────────────────

_cleanup() {
  log_info "Caught interrupt, shutting down..."
  exit 0
}
trap _cleanup SIGINT SIGTERM
