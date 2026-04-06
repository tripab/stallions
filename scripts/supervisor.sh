#!/bin/bash
# supervisor.sh — Spawn and monitor all agent roles defined in orchestration.toml
#
# Usage:
#   ./scripts/supervisor.sh
#   ./scripts/supervisor.sh --once   (spawn and exit without monitoring loop)

set -euo pipefail

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

# Associative arrays: key = "<role>_<instance>"
declare -A AGENT_PIDS=()       # PID of each running agent process
declare -A AGENT_RESTART=()    # consecutive restart count per agent
declare -A AGENT_ROLES=()      # role name for each key (for re-spawn)

# ── Spawn helpers ────────────────────────────────────────────────────────────

# Spawn a single agent instance in the background.
# Usage: spawn_agent <role> <instance>
spawn_agent() {
  local role="$1"
  local instance="$2"
  local key="${role}_${instance}"

  log_info "Spawning agent: role=$role instance=$instance"
  bash "$RUN_AGENT" --role "$role" --instance "$instance" &
  local pid=$!
  AGENT_PIDS["$key"]=$pid
  AGENT_ROLES["$key"]=$role
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

_shutdown() {
  echo ""
  log_info "Supervisor caught SIGINT/SIGTERM — initiating graceful shutdown..."

  local pids_to_kill=()
  for key in "${!AGENT_PIDS[@]}"; do
    local pid="${AGENT_PIDS[$key]}"
    if kill -0 "$pid" 2>/dev/null; then
      pids_to_kill+=("$pid")
      log_info "Sending SIGTERM to $key (PID $pid)..."
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done

  if [ "${#pids_to_kill[@]}" -gt 0 ]; then
    log_info "Waiting up to 10s for agents to exit..."
    local deadline=$(( $(date +%s) + 10 ))
    for pid in "${pids_to_kill[@]}"; do
      local remaining=$(( deadline - $(date +%s) ))
      if [ "$remaining" -le 0 ]; then
        break
      fi
      # Poll until the pid is gone or time runs out
      while kill -0 "$pid" 2>/dev/null && [ "$(date +%s)" -lt "$deadline" ]; do
        sleep 1
      done
    done

    # Force-kill anything still alive
    for pid in "${pids_to_kill[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        log_err "PID $pid did not exit — sending SIGKILL."
        kill -9 "$pid" 2>/dev/null || true
      fi
    done
  fi

  log_ok "Supervisor shutdown complete. All agents stopped."
  exit 0
}

trap _shutdown SIGINT SIGTERM

# ── Heartbeat monitoring + re-spawn loop ─────────────────────────────────────

_heartbeat_age() {
  local hb_file="$1"
  [ -f "$hb_file" ] || echo 999999
  local now last_beat
  now=$(date +%s)
  last_beat=$(cat "$hb_file" 2>/dev/null || echo 0)
  echo $(( now - last_beat ))
}

monitor_loop() {
  local stale_threshold=$(( HEARTBEAT_INTERVAL * 3 ))

  while true; do
    sleep "$HEARTBEAT_INTERVAL"

    local all_done=true

    for key in "${!AGENT_PIDS[@]}"; do
      local pid="${AGENT_PIDS[$key]}"
      local role="${AGENT_ROLES[$key]}"
      local instance="${key#${role}_}"
      local hb_file="$SIGNAL_DIR/heartbeats/${key}.heartbeat"
      local restart_count="${AGENT_RESTART[$key]:-0}"

      local alive=true
      kill -0 "$pid" 2>/dev/null || alive=false

      local hb_age
      hb_age=$(_heartbeat_age "$hb_file")
      local stuck=false
      [ "$hb_age" -gt "$stale_threshold" ] && stuck=true

      if [ "$alive" = true ] && [ "$stuck" = false ]; then
        all_done=false
        continue
      fi

      # Agent is dead or stuck
      all_done=false
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
        # Remove from tracked set so we don't keep re-escalating
        unset "AGENT_PIDS[$key]"
        unset "AGENT_ROLES[$key]"
        unset "AGENT_RESTART[$key]"
        continue
      fi

      log_err "$key failed: $reason (restart $((restart_count+1))/$MAX_RESTART_COUNT)"
      log_info "Waiting ${RESTART_BACKOFF}s before re-spawning $key..."
      sleep "$RESTART_BACKOFF"

      AGENT_RESTART["$key"]=$(( restart_count + 1 ))
      spawn_agent "$role" "$instance"
    done

    # Check if all tasks are done (no more agents to track)
    if [ "${#AGENT_PIDS[@]}" -eq 0 ]; then
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
