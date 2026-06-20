#!/bin/bash
# supervisor.sh — Spawn and monitor all agent roles defined in orchestration.toml
#
# Usage:
#   ./scripts/supervisor.sh
#   ./scripts/supervisor.sh --once   (spawn and exit without monitoring loop)

set -euo pipefail

# Enable job control so every backgrounded agent becomes the leader of its own
# process group. This gives the supervisor two things on shutdown:
#   1. Ctrl-C (SIGINT to the foreground group) reaches ONLY the supervisor, not
#      the agents — so the supervisor is the sole, orderly signal handler.
#   2. `kill -<sig> -<pid>` signals the agent AND its descendants (e.g. an
#      in-flight coding-agent invocation) as one group, so nothing is orphaned.
# Job-control notifications ("[1] Done") are not printed for non-interactive
# scripts, so this adds no output noise.
set -m

source "$(dirname "$0")/common.sh"

# ── Parse arguments ──────────────────────────────────────────────────────────

ONCE_MODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --once) ONCE_MODE=true ;;
    *) ;;
  esac
  shift
done

# ── Load config ──────────────────────────────────────────────────────────────

load_config

HEARTBEAT_INTERVAL=$(tomlq -r '.supervisor.heartbeat_interval // 30' "$ORCHESTRATION_TOML" 2>/dev/null || echo 30)
MAX_RESTART_COUNT=$(tomlq -r  '.supervisor.max_restart_count  // 3'  "$ORCHESTRATION_TOML" 2>/dev/null || echo 3)
RESTART_BACKOFF=$(tomlq -r    '.supervisor.restart_backoff    // 60' "$ORCHESTRATION_TOML" 2>/dev/null || echo 60)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_AGENT="$SCRIPT_DIR/run_agent.sh"

# ── Process tracking ─────────────────────────────────────────────────────────

# macOS ships bash 3.2, which has no associative arrays. We track agents with
# parallel indexed arrays instead. Each agent occupies one index across all
# arrays; an escalated agent is "tombstoned" (its key blanked) and ACTIVE_AGENTS
# decremented, so we never shrink the arrays mid-iteration.
AGENT_KEYS=()        # "<role>_<instance>" (blanked when tombstoned)
AGENT_PIDS=()        # PID of each running agent process
AGENT_RESTART=()     # consecutive restart count per agent
AGENT_ROLES=()       # role name (for re-spawn)
AGENT_INSTANCES=()   # instance number (for re-spawn)
ACTIVE_AGENTS=0      # count of non-tombstoned agents

# Find the array index for a given agent key. Prints the index, or -1 if absent.
# Usage: _agent_index <key>
_agent_index() {
  local key="$1" i
  for i in "${!AGENT_KEYS[@]}"; do
    [ "${AGENT_KEYS[$i]}" = "$key" ] && { echo "$i"; return; }
  done
  echo -1
}

# ── Spawn helpers ────────────────────────────────────────────────────────────

# Spawn a single agent instance in the background.
# On first spawn the agent is appended; on re-spawn its existing slot's PID is
# updated in place (keyed by "<role>_<instance>").
# Usage: spawn_agent <role> <instance>
spawn_agent() {
  local role="$1"
  local instance="$2"
  local key="${role}_${instance}"

  log_info "Spawning agent: role=$role instance=$instance"
  bash "$RUN_AGENT" --role "$role" --instance "$instance" &
  local pid=$!

  local idx
  idx=$(_agent_index "$key")
  if [ "$idx" -ge 0 ]; then
    AGENT_PIDS[$idx]=$pid           # re-spawn: reuse the slot
  else
    idx=${#AGENT_KEYS[@]}           # new agent: append a slot
    AGENT_KEYS[$idx]="$key"
    AGENT_PIDS[$idx]=$pid
    AGENT_ROLES[$idx]="$role"
    AGENT_INSTANCES[$idx]="$instance"
    AGENT_RESTART[$idx]=0
    ACTIVE_AGENTS=$(( ACTIVE_AGENTS + 1 ))
  fi
  log_ok "  $key → PID $pid"
}

# ── Read roles from orchestration.toml ───────────────────────────────────────

# Returns a list of role names defined under [roles.*] in orchestration.toml
list_roles() {
  if [ -f "$ORCHESTRATION_TOML" ] && command -v tomlq &>/dev/null; then
    tomlq -r '.roles | keys[]' "$ORCHESTRATION_TOML" 2>/dev/null || true
  fi
}

# ── Spawn all roles ──────────────────────────────────────────────────────────

spawn_all() {
  local role_type instances

  log_info "Supervisor starting — reading role definitions from orchestration.toml..."
  echo ""

  local spawned=0

  for role in $(list_roles); do
    role_type=$(role_config_get "$role" "type")
    instances=$(role_config_get "$role" "instances")

    # Skip interactive roles and roles with 0 instances
    [ "$role_type" = "interactive" ] && continue
    [ -z "$instances" ] && instances=0
    [ "$instances" -le 0 ] && continue

    for (( i=0; i<instances; i++ )); do
      spawn_agent "$role" "$i"
      (( spawned++ )) || true
    done
  done

  echo ""
  if [ "$spawned" -eq 0 ]; then
    log_err "No agents spawned. Check orchestration.toml — ensure roles have instances > 0."
    exit 1
  fi

  log_ok "Startup complete: $spawned agent process(es) launched."
  echo ""
}

# ── Graceful shutdown ─────────────────────────────────────────────────────────

# Send a signal to an agent's whole process group, falling back to the bare PID
# if the group send fails. Usage: _signal_group <signal> <pid>
_signal_group() {
  local sig="$1" pid="$2"
  kill "-${sig}" "-${pid}" 2>/dev/null || kill "-${sig}" "$pid" 2>/dev/null || true
}

_shutdown() {
  echo ""
  log_info "Supervisor caught SIGINT/SIGTERM — initiating graceful shutdown..."

  # SIGTERM each live agent's process group (agent + any coding-agent child).
  local pids_to_kill=()
  local i
  for i in "${!AGENT_KEYS[@]}"; do
    local key="${AGENT_KEYS[$i]}"
    [ -z "$key" ] && continue          # skip tombstoned slots
    local pid="${AGENT_PIDS[$i]}"
    if kill -0 "$pid" 2>/dev/null; then
      pids_to_kill+=("$pid")
      log_info "Sending SIGTERM to $key (PID $pid) and its children..."
      _signal_group TERM "$pid"
    fi
  done

  if [ "${#pids_to_kill[@]}" -eq 0 ]; then
    log_ok "Supervisor shutdown complete. No agents were running."
    exit 0
  fi

  # Wait up to 10s for graceful exit, checking every second.
  log_info "Waiting up to 10s for ${#pids_to_kill[@]} agent(s) to exit..."
  local deadline=$(( $(date +%s) + 10 ))
  local pid
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local still_alive=false
    for pid in "${pids_to_kill[@]}"; do
      kill -0 "$pid" 2>/dev/null && still_alive=true
    done
    [ "$still_alive" = false ] && break
    sleep 1
  done

  # SIGKILL any process group that ignored SIGTERM.
  for pid in "${pids_to_kill[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      log_err "PID $pid did not exit — sending SIGKILL to its process group."
      _signal_group KILL "$pid"
    fi
  done

  # Reap the children so none linger as zombies and the wait actually blocks
  # until each has truly terminated.
  for pid in "${pids_to_kill[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  log_ok "Supervisor shutdown complete. All agents stopped."
  exit 0
}

trap _shutdown SIGINT SIGTERM

# ── Heartbeat monitoring + re-spawn loop ─────────────────────────────────────

_heartbeat_age() {
  local hb_file="$1"
  # No heartbeat yet → treat as very stale. Must return, or the function would
  # also print the line below and the caller's numeric test would break.
  [ -f "$hb_file" ] || { echo 999999; return; }
  local now last_beat
  now=$(date +%s)
  last_beat=$(cat "$hb_file" 2>/dev/null || echo 0)
  echo $(( now - last_beat ))
}

monitor_loop() {
  local stale_threshold=$(( HEARTBEAT_INTERVAL * 3 ))

  while true; do
    sleep "$HEARTBEAT_INTERVAL"

    local i
    for i in "${!AGENT_KEYS[@]}"; do
      local key="${AGENT_KEYS[$i]}"
      [ -z "$key" ] && continue          # skip tombstoned slots
      local pid="${AGENT_PIDS[$i]}"
      local role="${AGENT_ROLES[$i]}"
      local instance="${AGENT_INSTANCES[$i]}"
      local hb_file="$SIGNAL_DIR/heartbeats/${key}.heartbeat"
      local restart_count="${AGENT_RESTART[$i]:-0}"

      local alive=true
      kill -0 "$pid" 2>/dev/null || alive=false

      local hb_age
      hb_age=$(_heartbeat_age "$hb_file")
      local stuck=false
      [ "$hb_age" -gt "$stale_threshold" ] && stuck=true

      if [ "$alive" = true ] && [ "$stuck" = false ]; then
        continue
      fi

      # Agent is dead or stuck
      local reason
      if [ "$alive" = false ]; then
        reason="process exited (PID $pid no longer alive)"
      else
        reason="heartbeat stale (${hb_age}s ago, threshold ${stale_threshold}s)"
      fi

      if [ "$restart_count" -ge "$MAX_RESTART_COUNT" ]; then
        log_err "$key has exceeded max restarts ($MAX_RESTART_COUNT). Escalating."
        _record_escalation "$key" "$reason"
        notify_external "agent_failed" "$key failed permanently after $MAX_RESTART_COUNT restarts" "danger"
        # Tombstone the slot so we don't keep re-escalating it
        AGENT_KEYS[$i]=""
        AGENT_PIDS[$i]=""
        ACTIVE_AGENTS=$(( ACTIVE_AGENTS - 1 ))
        continue
      fi

      log_err "$key failed: $reason (restart $((restart_count+1))/$MAX_RESTART_COUNT)"

      # If the old process is still alive (stuck, not exited), terminate its
      # whole group first so it and any child coding-agent don't linger as
      # orphans alongside the replacement we're about to spawn.
      if kill -0 "$pid" 2>/dev/null; then
        _signal_group TERM "$pid"
        sleep 2
        kill -0 "$pid" 2>/dev/null && _signal_group KILL "$pid"
      fi

      log_info "Waiting ${RESTART_BACKOFF}s before re-spawning $key..."
      sleep "$RESTART_BACKOFF"

      AGENT_RESTART[$i]=$(( restart_count + 1 ))
      spawn_agent "$role" "$instance"
    done

    # Check if all agents have finished (none left to track)
    if [ "$ACTIVE_AGENTS" -le 0 ]; then
      log_ok "All agents have completed. Supervisor exiting."
      notify_external "all_tasks_done" "All agents finished — project complete" "good"
      exit 0
    fi
  done
}

_record_escalation() {
  local key="$1" reason="$2"
  local supervisor_log="$PROJECT_ROOT/supervisor_log.md"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  if [ ! -f "$supervisor_log" ]; then
    echo "# Supervisor Escalation Log" > "$supervisor_log"
    echo "" >> "$supervisor_log"
    echo "| Timestamp | Agent | Reason |" >> "$supervisor_log"
    echo "|-----------|-------|--------|" >> "$supervisor_log"
  fi

  echo "| $timestamp | $key | $reason |" >> "$supervisor_log"
  log_err "Escalation recorded in supervisor_log.md"
}

# ── Main ──────────────────────────────────────────────────────────────────────

spawn_all

if [ "$ONCE_MODE" = true ]; then
  log_info "--once mode: supervisor exiting after spawn (agents run independently)."
  exit 0
fi

monitor_loop
