# Stallions v3 — Implementation Tasks

## Phase 1: Tag-Based Routing

### P1-T1: Update AGENT_LOG_SCHEMA.md — add Tags column
Add a `Tags` column after `Depends On` in the Task Index table. Update the example rows to include sample tag values. No other changes.

### P1-T2: Update TASK_SCHEMA.md — add Tags field
Add a `Tags` field to the Phase & Worktree section of the task file template (e.g. `Tags: backend.api`). No other changes.

### P1-T3: Implement `find_tagged_task()` in common.sh
Add a new function `find_tagged_task(status_pattern, tags_csv)` that:
- Reads the Task Index in AGENT_LOG.md
- Matches rows by status pattern (same as `find_task`)
- Additionally filters by tags: a task matches if any of its tags has the given role tag as a prefix (e.g. `backend` matches `backend.api.auth`)
- Wildcards: if `tags_csv` is `"*"`, matches any task regardless of tags
- Returns first matching task ID with dependencies met (calls `deps_met`)
- Falls back gracefully when there is no Tags column (v2 logs)

### P1-T4: Dynamic column detection for v2 backwards compatibility
Detect whether the Task Index has 5 columns (v2: no Tags) or 6+ columns (v3: with Tags). Wrap the column index for `Depends On` and `Tags` in a helper so `deps_met()` and the new `find_tagged_task()` work correctly against both schemas without breaking any existing functions.

### P1-T5: Update architect.md — tag assignment instructions
In Phase D, add instructions for the Architect to:
- Read `orchestration.toml` (if present) to discover defined roles and their tag lists
- Assign one or more tags to every task in the AGENT_LOG.md Task Index (Tags column)
- Record the same tags in each task file (Tags field)
- Use dot-separated hierarchy that matches the role tag prefixes

---

## Phase 2: Generic Agent Runner + Logging

### P2-T1: TOML config parsing in common.sh
Add a `load_config()` function that:
- Reads `orchestration.toml` via `tomlq` when available
- Falls back to an `.env`-style config file when `tomlq` is absent
- Exposes parsed values as shell variables: `AGENT_LOG`, `TASKS_DIR`, `DEFAULT_PROVIDER`, `DEFAULT_MODEL`, `DEFAULT_MAX_TURNS`, `LOG_LEVEL`, `CAPTURE_RESPONSES`
- Per-role overrides are stored in associative array `ROLE_*` variables
- `[defaults]` values serve as fallback for any role that doesn't override them

### P2-T2: Create orchestration.toml template
Add `orchestration.toml` to the repo root with the full schema from section 5.1 of the proposal. Use commented-out placeholder values so it works as a copy-paste starting point. All sections present: `[project]`, `[defaults]`, `[supervisor]`, `[logging]`, `[notifications]`, and role entries for `architect`, `backend`, `frontend`, `reviewer`, `tester`, `devops`, `qa`.

### P2-T3: Extract lifecycle functions into common.sh
Add three lifecycle functions to `common.sh` that contain the loop body of the existing runner scripts:
- `lifecycle_implementer()` — logic from `run_implementer.sh` (task pick, agent invoke, post-run handling)
- `lifecycle_reviewer()` — logic from `run_reviewer.sh` (find In-Review task, build diff prompt, invoke, handle outcome)
- `lifecycle_qa_responder()` — logic from `run_qa_responder.sh` (find pending questions, one-shot answer)

Each function accepts the role config as environment variables set by `run_agent.sh` before calling it.

### P2-T4: Create run_agent.sh — generic role-based runner
Create `scripts/run_agent.sh` that:
- Accepts `--role <name>` argument (required)
- Loads `orchestration.toml` config via `load_config()`
- Resolves role config: type, prompt file, tags, provider, model, max_turns, hooks_dir, task_filter
- Sets environment variables for the lifecycle function
- Dispatches to the correct `lifecycle_*` function based on role type (`implementer`, `reviewer`, `qa_responder`)
- Passes through any extra arguments to `parse_provider_arg`

### P2-T5: Hook execution support in run_agent.sh
Before calling `invoke_coding_agent`, call `pre_invoke.sh` if it exists in `hooks/<role>/`. After the call, call `post_invoke.sh` if it exists. Pass `TASK_ID` and `WORKTREE` as `$1` and `$2`. A non-zero exit from either hook aborts the invocation and logs an error.

### P2-T6: Convert existing runner scripts to v2 compatibility shims
Replace the bodies of `run_implementer.sh`, `run_reviewer.sh`, and `run_qa_responder.sh` with a one-line `exec` to `run_agent.sh`:
- `run_implementer.sh` → `exec "$(dirname "$0")/run_agent.sh" --role implementer "$@"`
- `run_reviewer.sh` → `exec "$(dirname "$0")/run_agent.sh" --role reviewer "$@"`
- `run_qa_responder.sh` → `exec "$(dirname "$0")/run_agent.sh" --role qa "$@"`

### P2-T7: JSONL log writing in run_agent.sh
After each `invoke_coding_agent` call in the lifecycle functions, write a JSONL log entry to `logs/orchestrator.jsonl` and `logs/agents/<role>_<instance>.jsonl`. Schema: versioned (`"v":1`) with fields: `id`, `timestamp`, `role`, `instance`, `task_id`, `mode`, `provider`, `model`, `phase`, `worktree`, `duration_seconds`, `exit_code`, `outcome`, `tokens`, `turns`, `prompt_hash`, `prompt_bytes`, `response_summary`, `response_file`, `errors`.

### P2-T8: Implement `parse_tokens()` in common.sh
Add a `parse_tokens(output_file)` function that reads agent output and extracts token counts using `grep`/`sed`. Support at minimum the Claude Code output format (`TokensIn`, `TokensOut`, `CacheRead`, `CacheWrite`). Return a JSON fragment `{"input":N,"output":N,"cache_read":N,"cache_write":N}`. Return `null` when parsing fails.

### P2-T9: Response capture via tee
In the lifecycle functions, pipe `invoke_coding_agent` output through `tee` to a temp file when `LOG_LEVEL` is `standard` or `verbose`. After the call, read the first 200 chars as `response_summary` and store the full output as `logs/responses/<invocation-id>.txt` (only when `CAPTURE_RESPONSES=true`). In `minimal` mode, skip capture entirely.

### P2-T10: Log directory setup in setup.sh
Add log directory creation to `scripts/setup.sh`: `logs/`, `logs/agents/`, `logs/responses/`. These are created at setup time so agents don't need to `mkdir -p` on every run.

---

## Phase 3: Supervisor + Notifications

### P3-T1: Create supervisor.sh — spawn logic
Create `scripts/supervisor.sh` that:
- Reads `orchestration.toml` via `load_config()`
- For each role with `instances > 0` and `type != interactive`, spawns `run_agent.sh --role <name>` as a background process (`&`)
- Stores each PID in an associative array keyed by `<role>_<instance>`
- Prints a startup summary listing each spawned agent

### P3-T2: Add heartbeat monitoring and re-spawn to supervisor.sh
Add a supervisor loop that every `heartbeat_interval` seconds:
- Checks each agent's heartbeat file at `$SIGNAL_DIR/heartbeats/<role>_<instance>.heartbeat` (age > 3× interval = stuck)
- Checks if the PID is still alive (`kill -0 $PID`)
- On failure: increments a per-agent restart counter; if under `max_restart_count`, waits `restart_backoff` seconds then re-spawns
- On exceeding `max_restart_count`: writes an escalation record to `supervisor_log.md` and fires a notification

### P3-T3: Graceful shutdown in supervisor.sh
Install a `SIGINT`/`SIGTERM` trap in `supervisor.sh` that:
- Sends `SIGTERM` to all tracked child PIDs
- Waits up to 10 seconds for each to exit
- Sends `SIGKILL` to any that haven't exited
- Prints a final summary and exits

### P3-T4: Heartbeat writing in run_agent.sh
At the start of each loop iteration in every lifecycle function, write a heartbeat file: `echo "$(date -u +%s)" > "$SIGNAL_DIR/heartbeats/${ROLE}_${INSTANCE}.heartbeat"`. One line added to the top of each lifecycle loop.

### P3-T5: Implement `notify_slack()` in common.sh
Add `notify_slack(event_type, message, color, task_id)` to `common.sh` per the design in section 7.4:
- Reads `SLACK_BOT_TOKEN`, `SLACK_ENABLED` from environment
- Routes to the correct channel via `get_slack_channel(event_type)` (reads from config)
- Checks `$SIGNAL_DIR/slack_threads/<task_id>.ts` for an existing thread timestamp
- Builds JSON payload with attachments (mrkdwn blocks + context line)
- Posts via `curl` to `chat.postMessage`
- Saves returned `ts` to thread file on first message for a task

### P3-T6: Implement `notify_external()` abstraction in common.sh
Add `notify_external(event_type, message, color, task_id)` that calls `notify_slack` and the existing `notify` (desktop). This single call point allows adding Discord etc. later. Replace all direct `notify` calls inside lifecycle functions with `notify_external` calls where appropriate.

### P3-T7: Add Slack event hook points in run_agent.sh lifecycle functions
At the correct points in each lifecycle function, call `notify_external` with the right event type:
- `lifecycle_implementer`: `task_in_review` after status update to "In Review"; `task_committed` after commit
- `lifecycle_reviewer`: `review_submitted` after status → "Reviewed"; `review_approved` after status → "Approved"
- `ensure_phases_merged` in common.sh: `phase_merge_needed` on conflict; `phase_merged` on success
- `supervisor.sh`: `agent_failed` on max restart exceeded; `all_tasks_done` when all tasks = Done

### P3-T8: Update setup.sh — generate orchestration.toml template
Add a step in `setup.sh` that copies `orchestration.toml` (if not already present) from the template in the repo, prints instructions for customizing it, and warns that `SLACK_BOT_TOKEN` must be set as an environment variable.

### P3-T9: Update status.sh — per-role progress
Extend `scripts/status.sh` to show per-role progress: for each role defined in `orchestration.toml`, count tasks tagged for that role broken down by status (Pending / In Review / Reviewed / Approved / Done). Fall back to the existing overall counts if `orchestration.toml` is absent.

---

## Phase 4: Mailboxes, Locking, and Prompt Templates

### P4-T1: Mailbox functions in common.sh
Add three functions to `common.sh`:
- `send_mail(recipient_role, subject, body)` — writes a timestamped file to `$SIGNAL_DIR/mailboxes/<recipient>/inbox/`
- `check_mail(role)` — lists unread message files in `$SIGNAL_DIR/mailboxes/<role>/inbox/`; prints each filename
- `ack_mail(message_file)` — moves the file to `$SIGNAL_DIR/mailboxes/<role>/processed/`

### P4-T2: Task locking — `claim_task()` and `release_task()`
Add two functions to `common.sh`:
- `claim_task(task_id, role)` — atomically creates `$SIGNAL_DIR/locks/<task_id>.lock/` via `mkdir`; writes role to `owner` file inside; returns 0 on success, 1 if already claimed
- `release_task(task_id)` — removes the lock directory

### P4-T3: Integrate task locking into lifecycle_implementer()
In `lifecycle_implementer()`, attempt `claim_task` before processing a selected task. If the claim fails (another agent grabbed it), continue to the next candidate without logging an error. Release the lock after the task transitions to "In Review" or "Done".

### P4-T4: Mailbox-driven reviewer notification
In `lifecycle_implementer()`, after updating task status to "In Review", call `send_mail reviewer_0 "task_ready" "$TASK_ID"`. In `lifecycle_reviewer()`, call `check_mail reviewer_0` at the start of each loop; if mail is present, skip the `sleep 60` poll delay and process immediately. Ack each message after reading.

### P4-T5: Create prompts/backend.md
Write a backend-focused implementer prompt template. Inherits the structure of `implementer.md` but adds: backend-specific guidance (API design, error handling, database access patterns, logging), instructions to run linters/tests in the worktree after implementation, and reminder to update `AGENT_LOG.md` status.

### P4-T6: Create prompts/frontend.md
Write a frontend-focused implementer prompt template. Covers: component structure, accessibility (a11y), prop validation, CSS conventions, snapshot/unit test expectations, and instructions for running `npm test` / linter post-implementation.

### P4-T7: Create prompts/tester.md
Write a test-suite-focused implementer prompt. Emphasizes: coverage thresholds, edge case enumeration, fixture/mock strategy, integration vs unit distinction, and instructions to report pass/fail counts in the task file's Test Results section.

### P4-T8: Create prompts/devops.md
Write an infrastructure-focused implementer prompt. Covers: Terraform/Docker conventions, idempotent resource definitions, secrets handling (no hardcoding), CI/CD pipeline structure, and rollback/validation steps.

### P4-T9: Create prompts/qa.md
Write the QA/design-question-answering prompt, consolidating the inline prompt from `run_qa_responder.sh` into a proper prompt file. Include: role description, how to read the task file for context, how to write answers, and how to update task status and activity log.

---

## Progress Tracker

| Task ID | Description | Phase | Status |
|---------|-------------|-------|--------|
| P1-T1 | Add Tags column to AGENT_LOG_SCHEMA.md | 1 | Done |
| P1-T2 | Add Tags field to TASK_SCHEMA.md | 1 | Done |
| P1-T3 | Implement `find_tagged_task()` in common.sh | 1 | Done |
| P1-T4 | Dynamic column detection for v2 backwards compatibility | 1 | Done |
| P1-T5 | Update architect.md with tag assignment instructions | 1 | Done |
| P2-T1 | TOML config parsing in common.sh | 2 | Done |
| P2-T2 | Create orchestration.toml template | 2 | Done |
| P2-T3 | Extract lifecycle functions into common.sh | 2 | Done |
| P2-T4 | Create run_agent.sh — generic role-based runner | 2 | Done |
| P2-T5 | Hook execution support in run_agent.sh | 2 | Done |
| P2-T6 | Convert existing runner scripts to v2 compatibility shims | 2 | Done |
| P2-T7 | JSONL log writing in run_agent.sh | 2 | Done |
| P2-T8 | Implement `parse_tokens()` in common.sh | 2 | Done |
| P2-T9 | Response capture via tee | 2 | Done |
| P2-T10 | Log directory setup in setup.sh | 2 | Done |
| P3-T1 | Create supervisor.sh — spawn logic | 3 | Done |
| P3-T2 | Heartbeat monitoring and re-spawn in supervisor.sh | 3 | Done |
| P3-T3 | Graceful shutdown in supervisor.sh | 3 | Done |
| P3-T4 | Heartbeat writing in run_agent.sh | 3 | Done |
| P3-T5 | Implement `notify_slack()` in common.sh | 3 | Done |
| P3-T6 | Implement `notify_external()` abstraction in common.sh | 3 | Done |
| P3-T7 | Add Slack event hook points in run_agent.sh and supervisor.sh | 3 | Done |
| P3-T8 | Update setup.sh — generate orchestration.toml template | 3 | Not Started |
| P3-T9 | Update status.sh — per-role progress | 3 | Not Started |
| P4-T1 | Mailbox functions in common.sh | 4 | Not Started |
| P4-T2 | Task locking — `claim_task()` and `release_task()` | 4 | Not Started |
| P4-T3 | Integrate task locking into lifecycle_implementer() | 4 | Not Started |
| P4-T4 | Mailbox-driven reviewer notification | 4 | Not Started |
| P4-T5 | Create prompts/backend.md | 4 | Not Started |
| P4-T6 | Create prompts/frontend.md | 4 | Not Started |
| P4-T7 | Create prompts/tester.md | 4 | Not Started |
| P4-T8 | Create prompts/devops.md | 4 | Not Started |
| P4-T9 | Create prompts/qa.md | 4 | Not Started |
