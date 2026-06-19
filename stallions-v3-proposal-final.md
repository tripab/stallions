# Stallions: Next-Gen Multi-Agent Orchestration (v3)

**Author:** Claude
**Date:** April 5, 2026
**Status:** Final
**Revision:** 3 (all decisions locked in)

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Analysis of Current Setup](#2-analysis-of-current-setup)
3. [Design Goals](#3-design-goals)
4. [Architecture Overview](#4-architecture-overview)
5. [Detailed Design: Orchestration Core](#5-detailed-design-orchestration-core)
6. [Detailed Design: Logging](#6-detailed-design-logging)
7. [Detailed Design: Notifications (Slack)](#7-detailed-design-notifications-slack)
8. [Detailed Design: Dashboard](#8-detailed-design-dashboard)
9. [Updated File Structure](#9-updated-file-structure)
10. [Implementation Plan](#10-implementation-plan)
11. [Comparison with GasTown](#11-comparison-with-gastown)
12. [Risks and Mitigations](#12-risks-and-mitigations)
13. [Scope Exclusions](#13-scope-exclusions)
14. [Example Deployment](#14-example-deployment)
15. [Decisions Log](#15-decisions-log)

---

## 1. Executive Summary

The current multi-agent orchestration setup (v2) works well for small projects with a fixed four-agent topology: Architect, Implementer, Reviewer, and QA Responder. Each is a separate bash script polling a shared `AGENT_LOG.md`. This proposal describes **v3** — an evolution that makes the agent topology pluggable, adds structured logging, Slack notifications with per-task threading, and a cross-platform dashboard for real-time monitoring and interactive Architect sessions.

The core insight from v2 is preserved: **bash does the coordination, the coding agent only sees its single task**. v3 extends this by making the *types* of agents configurable so medium-sized projects (~100K LOC) can deploy specialized implementer variants (frontend, backend, test-suite, DevOps, etc.) without forking the codebase.

We borrow concepts selectively from GasTown — agent templates with lifecycles, a supervisor loop, mailbox signaling, crash recovery — but implement them in shell + flat files, consistent with v2's design philosophy. The dashboard is the one component that steps outside bash, using Tauri + React as a lightweight desktop app (with a browser fallback), distributed as its own npm package (`racetrack`).

### What changes

| Dimension | v2 (current) | v3 (proposed) |
|-----------|-------------|---------------|
| Agent types | 4 hardcoded scripts | Template-based; new agent types via config |
| Implementer variants | One `run_implementer.sh` | Multiple: `frontend`, `backend`, `test`, `devops`, etc. |
| Orchestration | Each script self-loops independently | Supervisor coordinates lifecycle |
| Failure handling | Crash recovery for "Approved" tasks only | Per-agent health checks, re-spawn, escalation |
| Task routing | First-match by status column | Tag-based: tasks tagged with agent domain |
| Agent scaling | Run N terminals manually | `supervisor.sh` spawns/kills agents by config |
| Inter-agent comms | Filesystem signals (`/tmp/agents`) | Mailbox files per agent with structured messages |
| Config format | Environment variables only | TOML manifest + env var overrides |
| Monitoring | CLI-only (`status.sh`) | Dashboard app (Tauri + React) + CLI |
| Logging | Append-only activity log in AGENT_LOG.md | Structured JSONL per invocation + response capture |
| Notifications | Desktop-only (terminal bell + OS native) | Slack integration with threading + channel routing |

### What stays the same

The design principles of v2 are preserved: bash does the filtering and coordination, the coding agent only sees the single task it needs to work on, token savings are paramount, everything is provider-agnostic, and the coordination layer is markdown + flat files — no daemon, no database.

---

## 2. Analysis of Current Setup

### Strengths to preserve

1. **Token efficiency**: Bash pre-filters tasks, injects only the relevant content. The agent never reads `AGENT_LOG.md`. This is the single most valuable property of v2 and must be preserved in v3.

2. **Provider agnosticism**: The `invoke_coding_agent()` abstraction makes it trivial to swap Claude Code for Codex, Aider, OpenCode, or anything with a CLI. v3 must not break this.

3. **Crash recovery**: The Approved→Done path executes in pure bash (zero tokens). Phase merges happen in bash too. Both are idempotent.

4. **Simplicity**: The entire system is ~700 lines of bash spread across 6 scripts. A new developer can understand the full system in under an hour.

### Limitations for medium-sized projects

1. **Single Implementer bottleneck**: A 100K LOC project likely has frontend (React/Vue/Swift), backend (Go/Python/Rust), infrastructure (Terraform/Docker), and testing concerns. One implementer with one prompt handles all of them, which means the prompt is either too generic or requires manual customization per-project.

2. **No task routing**: All "Pending" tasks are treated identically. The implementer picks the first one with met dependencies. There's no way to say "TASK-012 is a frontend task and should be handled by the frontend agent."

3. **No supervisor**: If the implementer crashes and stays down, nobody restarts it. The user has to notice manually. At scale (4–6 agents across 3 terminals), this becomes a real problem.

4. **Rigid prompt structure**: Adding a new agent type means writing a new `run_<type>.sh` script from scratch, duplicating the loop logic, task parsing, and status-update code from the implementer.

5. **No parallel implementers**: You can only run one implementer at a time because they'd race on the same "Pending" pool. Running a frontend and backend implementer concurrently requires manual task partitioning.

6. **No structured logging**: Agent invocations leave no machine-readable trace beyond the activity log in `AGENT_LOG.md`. There's no way to track token consumption, invocation duration, or failure patterns.

7. **No remote notifications**: The desktop notifications (`osascript`/`notify-send`) only work if you're sitting at the machine. For longer-running orchestration sessions, the user has no way to get notified on their phone or team channel.

---

## 3. Design Goals

1. **Template-driven agents**: Define agent types (roles) in a config file. Each role specifies a prompt file, what task tags it handles, its lifecycle hooks, and provider overrides.

2. **Supervisor process**: A single `supervisor.sh` that reads the config, spawns agent processes, monitors their health, and re-spawns on failure. It also launches the Architect as an interactive session inside the Dashboard.

3. **Tag-based task routing**: Tasks in `AGENT_LOG.md` gain a "Tags" column. Each agent role declares which tags it handles. Tags support dot-separated hierarchy (e.g., `backend.api.auth`); routing matches on prefix.

4. **Agent lifecycle with hooks**: Every agent goes through: `init → pick_task → pre_invoke → invoke → post_invoke → idle`. Each phase can be customized per-role via hook scripts.

5. **Structured logging**: Every agent invocation produces a JSONL log entry with tokens, timing, exit code, and optionally the full response.

6. **Slack notifications**: Event-driven updates to configurable Slack channels with per-task threading, using a bot token and `chat.postMessage`.

7. **Dashboard**: A lightweight cross-platform desktop app (Tauri + React) with a browser fallback, providing an interactive Architect terminal, live agent status, task progress, and token consumption views. Distributed as a separate npm package.

8. **Minimal blast radius**: v3 is a superset of v2. Running `run_implementer.sh` directly still works. The supervisor, dashboard, and notifications are all additive.

9. **Stable dependencies**: All packages must be at least one month old. No freshly published or recently overhauled libraries.

10. **Stay small**: Target is ~1,500 lines of bash (up from ~700) for the orchestration core. The dashboard is ~2,100 lines of TypeScript/React in a separate repo.

---

## 4. Architecture Overview

```
                                    ┌─────────────────────────────┐
                                    │     orchestration.toml      │
                                    │  (roles, tags, scaling,     │
                                    │   logging, notifications)   │
                                    └──────────────┬──────────────┘
                                                   │ reads
┌──────────────────────┐            ┌──────────────▼──────────────┐
│  Dashboard App       │◄──watches──│        supervisor.sh        │
│  (separate repo,     │  heartbeat │  - Spawns/monitors agents   │
│   Tauri + React)     │  + logs    │  - Health checks            │
│                      │            │  - Re-spawn on failure      │
│ ┌──────────────────┐ │            └──┬──────┬──────┬──────┬─────┘
│ │ Architect        │ │   spawns      │      │      │      │
│ │ Terminal (PTY)   │ │          ┌────┘      │      │      └────────┐
│ ├──────────────────┤ │          ▼           ▼      ▼              ▼
│ │ Agent Status     │ │   ┌──────────┐ ┌─────────┐ ┌──────────┐ ┌────────┐
│ │ Grid             │ │   │run_agent │ │run_agent│ │run_agent │ │run_agnt│
│ ├──────────────────┤ │   │role=back │ │role=frt │ │role=rev  │ │role=tst│
│ │ Task Board +     │ │   └────┬─────┘ └────┬────┘ └────┬─────┘ └───┬────┘
│ │ Phase Progress   │ │        │            │           │            │
│ ├──────────────────┤ │        │ invoke     │ invoke    │ invoke     │
│ │ Token            │ │        ▼            ▼           ▼            ▼
│ │ Consumption      │ │   coding agent  coding agent coding agent  coding
│ └──────────────────┘ │   (any provdr)  (any provdr) (any provdr) agent
│          │           │
│    reads │           │         writes to           writes to
│          ▼           │              │                    │
│  ┌───────────────┐   │    ┌─────────▼──────────┐  ┌─────▼─────────┐
│  │logs/*.jsonl   │◄──│────│ AGENT_LOG.md        │  │ Slack API     │
│  │AGENT_LOG.md   │   │    │ logs/orchestr.jsonl │  │ (threaded     │
│  │heartbeats/    │   │    └────────────────────┘  │  notifications)│
│  └───────────────┘   │                             └───────────────┘
└──────────────────────┘
```

The key structural change is collapsing `run_implementer.sh`, `run_reviewer.sh`, and `run_qa_responder.sh` into a single generic **`run_agent.sh`** that reads its behavior from a role definition. The supervisor spawns one `run_agent.sh` per role instance.

---

## 5. Detailed Design: Orchestration Core

### 5.1 Configuration: `orchestration.toml`

A single TOML file in the project root defines the entire topology. TOML is parsed via `tomlq` (from `pip install yq`). For environments where that's not feasible, the system falls back to a simpler `.env`-style config.

```toml
[project]
name = "my-saas-app"
log_file = "AGENT_LOG.md"
tasks_dir = "tasks"

[defaults]
provider = "providers/claude.sh"
model = "sonnet"
max_turns = 25

[supervisor]
heartbeat_interval = 30          # seconds between health checks
max_restart_count = 3            # per agent, before giving up
restart_backoff = 60             # seconds between restarts
notify = true

# ── Logging ─────────────────────────────────────────────────────

[logging]
level = "standard"               # "minimal" | "standard" | "verbose"
capture_responses = true
response_retention_days = 7
max_response_size_kb = 500

# ── Notifications ───────────────────────────────────────────────

[notifications]
enabled = true

[notifications.slack]
bot_token_env = "SLACK_BOT_TOKEN"      # read from env var (never commit)
default_channel = "C0GENERAL123"       # fallback channel ID
username = "Orchestrator"
icon_emoji = ":robot_face:"
thread_per_task = true                 # group per-task events in threads

[notifications.slack.channels]
task_in_review = "C0DEVPROG456"        # #dev-progress
review_submitted = "C0DEVPROG456"
review_approved = "C0DEVPROG456"
task_committed = "C0DEVPROG456"
phase_merge_needed = "C0OPSALRT789"    # #ops-alerts
phase_merged = "C0DEVPROG456"
agent_failed = "C0OPSALRT789"
all_tasks_done = "C0DEVPROG456"

# ── Agent Role Definitions ──────────────────────────────────────

[roles.architect]
type = "interactive"             # launched in Dashboard terminal, not by supervisor

[roles.backend]
type = "implementer"
prompt = "prompts/backend.md"
tags = ["backend", "backend.api", "backend.db"]
instances = 1
task_filter = "Pending|Reviewed"
hooks_dir = "hooks/backend"

[roles.frontend]
type = "implementer"
prompt = "prompts/frontend.md"
tags = ["frontend", "frontend.ui", "frontend.components"]
provider = "providers/codex.sh"  # override: use Codex for frontend
model = "gpt-5.2-codex"
max_turns = 30
instances = 1
task_filter = "Pending|Reviewed"

[roles.reviewer]
type = "reviewer"
prompt = "prompts/reviewer.md"
tags = ["*"]                     # reviews all task types
effort = "high"
instances = 1
task_filter = "In Review"

[roles.tester]
type = "implementer"
prompt = "prompts/tester.md"
tags = ["test", "test.e2e"]
instances = 1
task_filter = "Pending|Reviewed"

[roles.devops]
type = "implementer"
prompt = "prompts/devops.md"
tags = ["infra", "infra.ci", "infra.docker"]
instances = 1
task_filter = "Pending|Reviewed"

[roles.qa]
type = "qa_responder"
poll_interval = 120
instances = 1
```

Roles inherit `provider`, `model`, and `max_turns` from `[defaults]` unless explicitly overridden.

### 5.2 Hierarchical Tags and the Tags Column

The Task Index table in `AGENT_LOG.md` gains a "Tags" column:

```markdown
## Task Index
| ID       | Title                         | Phase | Status    | Depends On | Tags              |
|----------|-------------------------------|-------|-----------|------------|-------------------|
| TASK-001 | Project scaffold              | 1     | Pending   | —          | backend, infra    |
| TASK-002 | React component library       | 1     | Pending   | TASK-001   | frontend.ui       |
| TASK-003 | REST API endpoints            | 2     | Pending   | TASK-001   | backend.api       |
| TASK-004 | E2E test suite                | 2     | Pending   | TASK-002   | test.e2e          |
| TASK-005 | CI pipeline                   | 3     | Pending   | TASK-003   | infra.ci          |
```

Tags support dot-separated hierarchy from day one. Routing uses prefix matching: a role with `tags = ["backend"]` matches tasks tagged `backend`, `backend.api`, `backend.api.auth`, etc. The wildcard `"*"` matches any tag (used by the reviewer). If a task has no tags, it can be claimed by any implementer-type agent (backwards compatibility with v2 task files).

### 5.3 The Generic Agent Runner: `run_agent.sh`

Replaces the three separate runner scripts:

```bash
./scripts/run_agent.sh --role backend
./scripts/run_agent.sh --role frontend
./scripts/run_agent.sh --role reviewer
```

Internally, `run_agent.sh` reads the role config, determines the lifecycle template (`implementer`, `reviewer`, `qa_responder`), and runs the appropriate loop. The current loop logic from the three scripts is consolidated into lifecycle functions in `common.sh`:

```
lifecycle_implementer()    — the current run_implementer.sh loop
lifecycle_reviewer()       — the current run_reviewer.sh loop
lifecycle_qa_responder()   — the current run_qa_responder.sh loop
```

The existing scripts become one-line compatibility shims:

```bash
# run_implementer.sh (v3 compatibility shim)
exec ./scripts/run_agent.sh --role implementer "$@"
```

### 5.4 Agent Lifecycle and Hooks

Every agent execution cycle follows this lifecycle:

```
┌─────────┐     ┌───────────┐     ┌─────────────┐     ┌────────┐     ┌──────────────┐     ┌──────┐
│  init    │────▶│ pick_task  │────▶│ pre_invoke   │────▶│ invoke │────▶│ post_invoke   │────▶│ idle │
│(one-time)│     │(bash only) │     │(hook script) │     │(agent) │     │(hook script)  │     │(wait)│
└─────────┘     └───────────┘     └─────────────┘     └────────┘     └──────────────┘     └──────┘
                      ▲                                                                       │
                      └───────────────────────────────────────────────────────────────────────┘
```

**Hook scripts** are optional shell scripts in `hooks/<role>/`:

```
hooks/
├── backend/
│   ├── pre_invoke.sh    # e.g., run database migrations before implementation
│   └── post_invoke.sh   # e.g., run linter, type-checker after implementation
├── frontend/
│   ├── pre_invoke.sh    # e.g., ensure dev server is up
│   └── post_invoke.sh   # e.g., run Storybook snapshot tests
└── tester/
    └── post_invoke.sh   # e.g., aggregate coverage reports
```

Hook scripts receive the task ID and worktree path as arguments. They execute in bash (zero tokens). A non-zero exit code pauses the agent and notifies the supervisor.

### 5.5 The Supervisor: `supervisor.sh`

The supervisor is the only new long-running process. It replaces the "open N terminals manually" workflow.

**Core responsibilities:**

1. **Spawn agents**: Read config → for each role with `instances > 0` and `type != interactive`, spawn `run_agent.sh --role <n>` as a background process.

2. **Health monitoring**: Each agent writes a heartbeat file every loop iteration. The supervisor checks these every `heartbeat_interval` seconds. If a heartbeat is stale (age > 3× expected cycle time), the agent is considered stuck.

3. **Re-spawn on failure**: If an agent process exits or is stuck, the supervisor kills it (if still running), waits `restart_backoff` seconds, and re-launches. After `max_restart_count` consecutive failures, it stops trying and notifies the user.

4. **Graceful shutdown**: `Ctrl-C` sends `SIGTERM` to all child agents, waits up to 10 seconds, then `SIGKILL`.

5. **Progress reporting**: Periodically prints a compact status line showing per-agent activity and overall progress.

6. **Escalation**: When an agent hits `max_restart_count`, writes an escalation record to `supervisor_log.md` and fires a Slack notification.

**What the supervisor is NOT:** It is not an AI agent. It doesn't make decisions about task priority, code quality, or architecture. It's a process manager — ~200 lines of bash.

### 5.6 Inter-Agent Communication: Mailboxes

v3 extends the simple signal files into a lightweight mailbox system:

```
/tmp/agents/
├── mailboxes/
│   ├── backend_0/inbox/
│   ├── frontend_0/inbox/
│   ├── reviewer_0/inbox/
│   └── supervisor/inbox/
└── heartbeats/
    ├── backend_0.heartbeat
    └── ...
```

Messages are plain text files with timestamp-based filenames. The implementer drops a message in the reviewer's inbox when it submits work, eliminating the reviewer's need to poll AGENT_LOG.md every 60 seconds.

### 5.7 Task Claiming and Locking

With multiple concurrent implementer agents, races are prevented with atomic filesystem locking:

```bash
claim_task() {
  local task_id="$1" role="$2"
  local lock_file="$SIGNAL_DIR/locks/${task_id}.lock"
  if mkdir "$lock_file" 2>/dev/null; then
    echo "$role" > "$lock_file/owner"
    return 0  # claimed
  fi
  return 1    # already claimed by another agent
}
```

`mkdir` is atomic on all POSIX filesystems — exactly one process wins.

### 5.8 Updated Architect Prompt

The Architect prompt is updated for tag assignment in Phase D: one row per task now includes tags matching the roles defined in `orchestration.toml`. The Architect can also read the config to discover which roles exist and tailor its task decomposition accordingly.

### 5.9 Specialized Prompt Templates

v3 ships with prompt templates for common roles, each inheriting the structure of `implementer.md` but adding domain-specific guidance:

```
prompts/
├── architect.md        # updated for tags
├── implementer.md      # generic fallback
├── reviewer.md         # unchanged
├── backend.md          # backend-specific instructions
├── frontend.md         # frontend-specific (component conventions, a11y, etc.)
├── tester.md           # testing-focused (coverage thresholds, edge cases)
├── devops.md           # infrastructure-focused (Terraform, Docker, CI)
└── qa.md               # renamed from architect Phase E
```

Users customize these for their project. The templates are starting points.

### 5.10 Usage-Limit Resilience

Subscription-based coding agents (Claude, Codex, etc.) enforce rolling **5-hour** and **weekly** usage caps. When an agent hits one mid-run, the provider CLI exits with an error. In v2 this surfaced as a generic agent failure: the loop logged an error, slept 30s, and retried — burning restart counters and, after `max_restart_count`, escalating the agent as permanently failed. An overnight run could therefore die a few minutes after the cap was reached and never recover, even though the session would have renewed on its own.

v3 makes every invocation **usage-limit aware**. The single choke point through which all roles invoke their provider (`invoke_agent_logged` in `common.sh`) inspects the captured output for usage-limit signatures. When one is detected, instead of returning the error to the lifecycle, it:

1. Logs a `⏳` wait and fires a `usage_limit_paused` notification.
2. Sleeps for `check_interval` seconds (default **15 minutes**, configurable).
3. Re-invokes the same prompt — the re-invocation *is* the renewal check: if the cap is still active the provider fails fast and the agent waits another interval; once the session renews, the call proceeds normally and a `usage_limit_resumed` notification fires.

Because the wait can be far longer than the supervisor's stale-heartbeat threshold (3× `heartbeat_interval`, default 90s), the wait keeps the agent's heartbeat fresh in small increments so the supervisor does not mistake a throttled agent for a stuck one and re-spawn it.

```toml
[usage_limit]
enabled        = true   # set false to fail fast on limits (old v2 behaviour)
check_interval = 900     # seconds between renewal attempts (default 15 min)
max_wait       = 0       # cap on total wait per invocation; 0 = wait indefinitely
# patterns     = "..."   # optional override of the detection regex (ERE, case-insensitive)
```

Detection is regex-based and matches provider phrasings such as *"usage limit reached"*, *"limit will reset"*, *"5-hour limit"*, *"weekly limit reached"*, `rate_limit_error`, and `overloaded_error`. The pattern set is configurable so new providers or error wordings can be added without code changes. The feature is provider-agnostic — it works for any agent whose CLI prints a recognizable limit message before exiting.

---

## 6. Detailed Design: Logging

### 6.1 Log Entry Schema

Every agent invocation produces a structured JSONL log entry. The schema includes a version field for forward compatibility:

```jsonl
{
  "v": 1,
  "id": "inv_20260405_142247_backend_0",
  "timestamp": "2026-04-05T14:22:47Z",
  "role": "backend",
  "instance": 0,
  "task_id": "TASK-003",
  "mode": "fresh",
  "provider": "providers/claude.sh",
  "model": "sonnet",
  "phase": 2,
  "worktree": ".worktrees/phase-2-core",

  "duration_seconds": 187,
  "exit_code": 0,
  "outcome": "In Review",

  "tokens": {
    "input": 42300,
    "output": 12800,
    "cache_read": 8200,
    "cache_write": 3100
  },

  "turns": 14,
  "max_turns": 25,

  "prompt_hash": "sha256:a1b2c3...",
  "prompt_bytes": 4820,

  "response_summary": "Implemented REST API endpoints for /users and /auth...",
  "response_file": "logs/responses/inv_20260405_142247_backend_0.txt",

  "errors": []
}
```

The `v` field lets the dashboard and any future tooling handle schema changes gracefully.

### 6.2 Token Parsing

Token counts are extracted from the coding agent's stdout. Different providers report tokens differently — Claude Code prints a summary line, Codex has its own format, others may not report at all. A `parse_tokens()` function in `common.sh` uses `grep`/`sed` pipelines with fallback patterns. When parsing fails, `tokens` is set to `null`.

### 6.3 Response Capture

The full agent response (stdout) is optionally captured via `tee`. Controlled by `[logging]` config:

- **minimal**: Log entry only (no response capture, no stdout parsing for tokens)
- **standard** (default): Log entry + token parsing + response summary (first 200 chars) + response file
- **verbose**: Everything in standard, plus full stderr capture and prompt content saved

### 6.4 Log File Layout

```
logs/
├── orchestrator.jsonl         # combined log: all agents, append-only
├── supervisor.jsonl           # supervisor events (spawn, kill, restart)
├── agents/                    # per-instance convenience views
│   ├── backend_0.jsonl
│   ├── frontend_0.jsonl
│   └── ...
└── responses/                 # full agent stdout captures (optional)
    ├── inv_20260405_142247_backend_0.txt
    └── ...
```

### 6.5 Implementation

Logging integrates directly into `run_agent.sh`'s invoke step. The agent's stdout is piped through `tee` to capture the response, and a log entry is appended after completion. This adds ~40 lines to the agent runner.

---

## 7. Detailed Design: Notifications (Slack)

### 7.1 Why Bot Tokens Instead of Incoming Webhooks

Two of the requirements — per-task threading and per-event-type channel routing — together push us past what incoming webhooks can do cleanly. Incoming webhooks don't return the message `ts` needed for threading, and each webhook URL is locked to a single channel. To support both features, we use the Slack Web API with a **bot token** (`xoxb-...`) and the `chat.postMessage` method.

The setup cost is marginally higher (create a Slack app → add `chat:write` scope → install to workspace → copy bot token), but the result is cleaner: one token, any channel, full threading.

### 7.2 Configuration

```toml
[notifications]
enabled = true

[notifications.slack]
bot_token_env = "SLACK_BOT_TOKEN"      # env var name (never hardcode the token)
default_channel = "C0GENERAL123"       # fallback channel ID
username = "Orchestrator"
icon_emoji = ":robot_face:"
thread_per_task = true                 # group per-task events in Slack threads

[notifications.slack.channels]
# Map event types to channel IDs (use channel IDs, not names)
task_in_review = "C0DEVPROG456"        # #dev-progress
review_submitted = "C0DEVPROG456"
review_approved = "C0DEVPROG456"
task_committed = "C0DEVPROG456"
phase_merge_needed = "C0OPSALRT789"    # #ops-alerts
phase_merged = "C0DEVPROG456"
agent_failed = "C0OPSALRT789"
all_tasks_done = "C0DEVPROG456"
```

### 7.3 Per-Task Threading

When `thread_per_task = true`, the first notification about a task (usually `task_in_review`) posts as a top-level message. The `chat.postMessage` response includes a `ts` value, which we store in a local file:

```
/tmp/agents/slack_threads/
├── TASK-001.ts    # contains: "1712345678.001500"
├── TASK-003.ts    # contains: "1712346789.002300"
└── ...
```

Subsequent notifications about the same task include `thread_ts` to post as replies. The result in Slack looks like:

```
┌──────────────────────────────────────────────────────────┐
│ 🤖 Orchestrator                              3:02 PM     │
│ 📝 *backend_0* submitted *TASK-003* (REST API) for review│
│                                                          │
│   3 replies                                              │
│   ├─ 🤖 3:15 PM: *reviewer_0* reviewed — 2 changes req  │
│   ├─ 🤖 3:28 PM: *backend_0* re-submitted after fixup   │
│   └─ 🤖 3:35 PM: *reviewer_0* approved TASK-003 ✅       │
└──────────────────────────────────────────────────────────┘
```

### 7.4 Implementation: `notify_slack()` in `common.sh`

```bash
SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"
SLACK_DEFAULT_CHANNEL="${SLACK_DEFAULT_CHANNEL:-}"
SLACK_ENABLED="${SLACK_ENABLED:-false}"
SLACK_THREAD_DIR="$SIGNAL_DIR/slack_threads"

notify_slack() {
  [[ "$SLACK_ENABLED" != "true" || -z "$SLACK_BOT_TOKEN" ]] && return 0

  local event_type="$1" message="$2" color="${3:-#36a64f}" task_id="${4:-}"
  local channel

  # Route to the right channel
  channel=$(get_slack_channel "$event_type")  # reads from config
  [[ -z "$channel" ]] && channel="$SLACK_DEFAULT_CHANNEL"
  [[ -z "$channel" ]] && return 0

  # Threading: check for existing thread
  local thread_ts=""
  if [[ -n "$task_id" && -f "$SLACK_THREAD_DIR/${task_id}.ts" ]]; then
    thread_ts=$(cat "$SLACK_THREAD_DIR/${task_id}.ts")
  fi

  # Build JSON payload
  local payload
  payload=$(cat <<EOF
{
  "channel": "$channel",
  "username": "${SLACK_USERNAME:-Orchestrator}",
  "icon_emoji": "${SLACK_ICON:-:robot_face:}",
  $([ -n "$thread_ts" ] && echo "\"thread_ts\": \"$thread_ts\",")
  "attachments": [{
    "color": "$color",
    "blocks": [
      {"type":"section","text":{"type":"mrkdwn","text":"$message"}},
      {"type":"context","elements":[
        {"type":"mrkdwn","text":"📍 *$event_type* · $(date '+%H:%M %Z')"}
      ]}
    ]
  }]
}
EOF
)

  # Post via chat.postMessage (returns ts for threading)
  local response
  response=$(curl -s -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-type: application/json" \
    --data "$payload")

  # Store ts for threading (only for first message in a task thread)
  if [[ -n "$task_id" && -z "$thread_ts" ]]; then
    mkdir -p "$SLACK_THREAD_DIR"
    local ts
    ts=$(echo "$response" | grep -o '"ts":"[^"]*"' | head -1 | cut -d'"' -f4)
    [[ -n "$ts" ]] && echo "$ts" > "$SLACK_THREAD_DIR/${task_id}.ts"
  fi
}
```

### 7.5 Event Hook Points

| Event | Trigger location | Color |
|-------|-----------------|-------|
| `task_in_review` | `run_agent.sh`, post-invoke, status = "In Review" | blue `#1d9bd1` |
| `review_submitted` | `run_agent.sh` (reviewer), post-invoke, status = "Reviewed" | yellow `#daa520` |
| `review_approved` | `run_agent.sh` (reviewer), post-invoke, status = "Approved" | green `#36a64f` |
| `task_committed` | `run_agent.sh`, after bash commit of approved task | green `#36a64f` |
| `phase_merge_needed` | `common.sh`, `ensure_phases_merged()` on conflict | red `#dc3545` |
| `phase_merged` | `common.sh`, `ensure_phases_merged()` on success | green `#36a64f` |
| `agent_failed` | `supervisor.sh`, after max restart count hit | red `#dc3545` |
| `all_tasks_done` | `supervisor.sh`, when all tasks = Done | green `#36a64f` |

All hook points call `notify_external()`, which dispatches to `notify_slack()` and can be extended to support Discord, Teams, etc.

### 7.6 Extensibility

The notification layer uses a thin abstraction:

```bash
notify_external() {
  local event_type="$1" message="$2" color="$3" task_id="$4"
  notify_slack "$event_type" "$message" "$color" "$task_id"
  # notify_discord "$event_type" "$message" "$color" "$task_id"  # future
}
```

### 7.7 Setup Instructions

1. Go to `api.slack.com/apps` and create a new Slack App.
2. Under "OAuth & Permissions", add the `chat:write` bot token scope.
3. Install the app to your workspace.
4. Copy the Bot User OAuth Token (`xoxb-...`).
5. Add the bot to the channels you want it to post in (right-click channel → "View channel details" → "Integrations" → "Add apps").
6. Set the token as an environment variable:
   ```bash
   export SLACK_BOT_TOKEN="xoxb-your-token-here"
   ```
7. Configure channels in `orchestration.toml` (use channel IDs, not names).
8. Restart the supervisor.

---

## 8. Detailed Design: Dashboard

### 8.1 Design Philosophy

The dashboard answers one question at a glance: *"What are my agents doing right now?"* It is a monitoring and interaction surface, not a project management tool. It reads state from the same flat files the bash scripts use and writes nothing to them (except through the Architect terminal). Removing the dashboard doesn't break anything.

The dashboard lives in its **own repository** (`racetrack`), installable via `npm install -g racetrack` or downloadable as a platform-specific binary. This keeps the Stallions starter pack lean (pure bash + markdown) and avoids adding Node.js/Rust dependencies to every project.

### 8.2 Tech Stack

```
┌─────────────────────────────────────────────────────────┐
│                    Desktop App (Tauri v2)                │
│                                                         │
│  ┌───────────────────────────────────────────────────┐  │
│  │              Frontend (React + Vite)              │  │
│  │                                                   │  │
│  │  ┌─────────────┐ ┌──────────┐ ┌───────────────┐  │  │
│  │  │ Architect   │ │ Agent    │ │ Progress &    │  │  │
│  │  │ Terminal    │ │ Status   │ │ Token Views   │  │  │
│  │  │ (xterm.js)  │ │ Grid     │ │ (recharts)    │  │  │
│  │  └─────────────┘ └──────────┘ └───────────────┘  │  │
│  └───────────────────────────────────────────────────┘  │
│                          │                              │
│                    WebSocket + IPC                       │
│                          │                              │
│  ┌───────────────────────────────────────────────────┐  │
│  │         Backend Sidecar (Node.js)                 │  │
│  │                                                   │  │
│  │  File Watchers   │  PTY Manager   │  Log Parser   │  │
│  │  (chokidar)      │  (node-pty)    │  (JSONL)      │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
│              Tauri Shell (Rust, ~minimal)                │
└─────────────────────────────────────────────────────────┘
```

**Tauri v2** over Electron: stable since October 2024 (~18 months old), ships ~15 MB binaries vs. ~150 MB for Electron, uses system WebView, smaller attack surface. The Rust layer is thin — it just bootstraps the Node.js sidecar and handles window management.

**Node.js sidecar**: Handles PTY spawning (for the Architect terminal), filesystem watching, and JSONL parsing. Exposes a WebSocket server on localhost. This same interface enables the browser fallback — run `racetrack --browser` and open `http://localhost:9400`. This is the same endpoint you'd expose via Tailscale Serve for phone access.

**Package maturity** (all well past the one-month threshold):

| Package | Role | Stable since |
|---------|------|-------------|
| Tauri v2 | Desktop shell | Oct 2024 |
| React 19 | UI framework | Dec 2024 |
| Vite 6 | Build tool | Nov 2024 |
| xterm.js 5.x | Terminal emulator | 2023+ |
| node-pty | PTY bindings | 2017+ |
| chokidar 4.x | File watcher | 2024 |
| recharts 2.x | Charts | 2018+ |
| ws | WebSocket server | 2013+ |

### 8.3 Dashboard Components

#### 8.3.1 Architect Terminal (Tab 1)

A full terminal emulator running the Architect agent's interactive session. An xterm.js instance connected via WebSocket to a `node-pty` process on the sidecar. The sidecar spawns `claude --prompt-file prompts/architect.md` (or whatever provider is configured) and pipes stdin/stdout through the PTY.

**Why a terminal and not a chat UI:** A terminal works with *any* CLI agent — Claude Code, Codex, Aider, OpenCode — because it's just a PTY. Building a chat UI would lock us into one provider's API. The agent's native markdown rendering, thinking indicators, and tool-use output all appear exactly as intended.

Features: full ANSI color support, configurable scrollback (default 5000 lines), search within output, session persistence across dashboard restarts (the sidecar keeps the PTY alive), and a "Restart Architect" button.

#### 8.3.2 Agent Status Grid (Tab 2)

A real-time card grid where each running agent instance gets a card showing: role and instance ID, status indicator (green/gray/yellow/red dot), current task ID and mode, time on current task, turn count (if available), and error info for failed agents. Data comes from heartbeat files watched by the sidecar with `chokidar`.

Clicking a card expands it to show the agent's recent JSONL log entries.

#### 8.3.3 Task Board (Tab 3)

A Kanban-style view of all tasks organized by status columns: Pending → In Review → Reviewed → Approved → Done. Filterable by phase and by tag/role. Clicking a task card shows its full task file content. Shows which agent instance is currently working on each task. A phase progress bar sits at the top.

#### 8.3.4 Phase Progress View (Sidebar widget)

Compact per-phase completion percentages, per-role breakdown within each phase, merge status, and an overall progress bar.

#### 8.3.5 Token Consumption View (Tab 4)

Token usage per agent role over time, sourced from the JSONL logs. Shows input/output token counts, invocation counts, average tokens per task, and estimated cost. Renders time-series line charts (via `recharts`) and aggregate tables. When token data isn't available (provider doesn't report), shows invocation counts and wall-clock time instead.

#### 8.3.6 Activity Feed (Sidebar)

A scrollable live stream of recent activity log entries from `AGENT_LOG.md`, plus supervisor events. Essentially a pretty, real-time `status.sh`.

### 8.4 Browser Fallback

The browser fallback is not a separate codebase — it's the same React frontend served by the Node.js sidecar over HTTP instead of being embedded in Tauri:

```bash
# Desktop app
racetrack --project /path/to/my-project

# Browser fallback (local)
racetrack --browser --project /path/to/my-project
# Opens http://localhost:9400

# Remote access via Tailscale Serve (from phone, tablet, etc.)
# On the workstation:
tailscale serve 9400
# Then open https://<machine-name>.<tailnet>.ts.net/ on your phone
```

No dashboard-level auth is needed. When accessed locally, it's localhost. When accessed remotely via Tailscale Serve, the tailnet itself provides authentication — only devices on your Tailscale network can reach the endpoint, and Tailscale handles HTTPS certificates automatically.

### 8.5 Data Flow

The sidecar pushes updates to the frontend via typed WebSocket messages (`agent_status`, `task_update`, `log_entry`, `progress`, `activity`, `token_stats`, `pty_output`). The frontend sends commands back (`pty_input`, `pty_resize`, `restart_agent`, `restart_architect`). The sidecar never writes to orchestration files — it is read-only except for PTY I/O.

### 8.6 Distribution

The Racetrack repo builds to:
- **npm package**: `npm install -g racetrack` (requires Node.js runtime, no native build)
- **Platform binaries**: macOS `.dmg`, Windows `.msi`, Linux `.AppImage` (via Tauri's official GitHub Actions workflow, ~15 MB each)

### 8.7 Dashboard Sizing

| Component | Estimated lines |
|-----------|----------------|
| Sidecar (file watchers, AGENT_LOG parser, PTY, WebSocket, log parser, config) | ~800 |
| Frontend (all six views + layout/routing/theme) | ~1,100 |
| Tauri shell (window + sidecar bootstrap) | ~80 |
| Shared types | ~120 |
| **Total** | **~2,100** |

---

## 9. Updated File Structure

### Stallions starter pack (copied into each project)

```
your-project/
├── orchestration.toml
├── prompts/
│   ├── architect.md
│   ├── implementer.md
│   ├── reviewer.md
│   ├── backend.md
│   ├── frontend.md
│   ├── tester.md
│   ├── devops.md
│   └── qa.md
├── schemas/
│   ├── AGENT_LOG_SCHEMA.md       # updated: Tags column
│   └── TASK_SCHEMA.md            # updated: Tags field
├── hooks/                        # lifecycle hooks (user-provided)
│   └── ...
├── providers/
│   ├── claude.sh
│   ├── codex.sh
│   ├── opencode.sh
│   ├── aider.sh
│   └── _template.sh
├── scripts/
│   ├── common.sh                 # +tags, +mailbox, +locking, +logging, +slack
│   ├── supervisor.sh
│   ├── run_agent.sh
│   ├── run_implementer.sh        # v2 compat shim
│   ├── run_reviewer.sh           # v2 compat shim
│   ├── run_qa_responder.sh       # v2 compat shim
│   ├── setup.sh
│   └── status.sh
├── logs/                         # created at runtime
│   ├── orchestrator.jsonl
│   ├── supervisor.jsonl
│   ├── agents/
│   └── responses/
├── AGENT_LOG.md
├── IMPLEMENTATION_PLAN.md
└── tasks/
```

### Racetrack dashboard (separate repo: `racetrack`)

```
racetrack/
├── package.json
├── package-lock.json
├── vite.config.ts
├── tsconfig.json
├── server.js                     # Node.js sidecar
├── src/
│   ├── App.tsx
│   ├── main.tsx
│   ├── components/
│   │   ├── ArchitectTerminal.tsx
│   │   ├── AgentStatusGrid.tsx
│   │   ├── TaskBoard.tsx
│   │   ├── PhaseProgress.tsx
│   │   ├── TokenConsumption.tsx
│   │   └── ActivityFeed.tsx
│   ├── hooks/
│   │   ├── useWebSocket.ts
│   │   └── useAgentData.ts
│   └── types/
│       └── index.ts
└── src-tauri/
    ├── Cargo.toml
    ├── tauri.conf.json
    └── src/
        └── main.rs
```

---

## 10. Implementation Plan

Five phases. Each is independently shippable — the system remains fully functional after each one. Phases 1–4 are bash-only. Phase 5 (dashboard) can be developed in parallel.

### Phase 1: Tag-based routing (~115 lines of bash)

- Tags column in `AGENT_LOG_SCHEMA.md` and `TASK_SCHEMA.md` (with Tags field in task files)
- `find_tagged_task(status_pattern, tags)` in `common.sh` with hierarchical prefix matching
- Updated `architect.md` with tag assignment instructions
- Dynamic column-count detection for backwards compatibility with v2 logs

### Phase 2: Generic agent runner + Logging (~460 lines of bash)

- `run_agent.sh` with role-based parameterization
- Lifecycle functions extracted into `common.sh`: `lifecycle_implementer()`, `lifecycle_reviewer()`, `lifecycle_qa_responder()`
- TOML config parsing (via `tomlq`) with `.env` fallback, including `[defaults]` inheritance
- Hook execution support (`pre_invoke`, `post_invoke`)
- Compatibility shims for `run_implementer.sh`, `run_reviewer.sh`, `run_qa_responder.sh`
- JSONL log writing with versioned schema (`"v": 1`)
- Token parsing functions (provider-specific patterns)
- Response capture via `tee` (configurable verbosity)
- Log directory setup in `setup.sh`

### Phase 3: Supervisor + Notifications (~340 lines of bash)

- `supervisor.sh` with spawn, heartbeat monitoring, re-spawn, and graceful shutdown
- Heartbeat writing in `run_agent.sh` (one-liner per loop iteration)
- `supervisor_log.md` for failure/escalation tracking
- `notify_slack()` using bot token + `chat.postMessage`
- Per-task thread tracking (`$SIGNAL_DIR/slack_threads/`)
- Per-event-type channel routing (from TOML config)
- `notify_external()` abstraction layer
- Event hook points in `run_agent.sh` and `supervisor.sh`
- Updated `setup.sh` (generates `orchestration.toml` template)
- Updated `status.sh` (per-role progress)

### Phase 4: Mailboxes, locking, and prompt templates (~510 lines)

- Mailbox functions in `common.sh` (`send_mail`, `check_mail`, `ack_mail`)
- `claim_task()` / `release_task()` filesystem locking
- Prompt templates for `backend.md`, `frontend.md`, `tester.md`, `devops.md`, `qa.md`
- Mailbox-driven reviewer notification (eliminates polling)

### Phase 5: Racetrack Dashboard (~2,100 lines of TypeScript/React/Rust)

*Developed in parallel with phases 1–4, in the `racetrack` repo.*

- Node.js sidecar: file watchers (`chokidar`), AGENT_LOG parser, JSONL log parser + token aggregator, PTY manager (`node-pty`), WebSocket server (`ws`), TOML config loader
- React frontend: Architect terminal (xterm.js), Agent status grid, Task board, Phase progress view, Token consumption view (recharts), Activity feed, Layout/routing/theme
- Tauri shell: window management, sidecar bootstrap
- Browser fallback mode
- npm packaging + Tauri binary builds for macOS/Windows/Linux

### Deliverables Summary

| Deliverable | Lines (est.) | Phase | Stack |
|-------------|-------------|-------|-------|
| Tags + hierarchical routing | ~80 | 1 | bash |
| Updated schemas + architect prompt | ~35 | 1 | markdown |
| `run_agent.sh` + lifecycle functions | ~200 | 2 | bash |
| TOML config parser + defaults inheritance | ~100 | 2 | bash |
| Hook execution support | ~40 | 2 | bash |
| JSONL logging + token parsing + response capture | ~120 | 2 | bash |
| `supervisor.sh` + health checks | ~200 | 3 | bash |
| Slack notification (threading + channel routing) | ~90 | 3 | bash |
| Updated `setup.sh` and `status.sh` | ~50 | 3 | bash |
| Mailbox functions | ~80 | 4 | bash |
| Task locking | ~30 | 4 | bash |
| Prompt templates (5 files) | ~400 | 4 | markdown |
| Dashboard sidecar | ~800 | 5 | Node.js/TS |
| Dashboard frontend | ~1,100 | 5 | React/TS |
| Tauri shell + types | ~200 | 5 | Rust/TS |
| **Total** | **~3,525** | | |

Bash portion: ~700 (v2) → ~1,500 (v3). Dashboard: ~2,100 lines in a separate repo.

---

## 11. Comparison with GasTown

| Feature | GasTown | v3 (this proposal) |
|---------|---------|---------------------|
| Language | Go binary (~6800 commits) | Bash (~1,500 lines) + optional TS dashboard |
| Agent identity | Persistent named "Polecats" with sessions | Ephemeral role-based instances |
| Work tracking | Beads ledger (git-backed issue DB) | AGENT_LOG.md markdown table |
| Workflow templates | Molecules (TOML formulas, lifecycle states) | Hook scripts (pre/post invoke) |
| Supervision | Witness + Deacon + Dogs (3-tier) | Single `supervisor.sh` |
| Merge queue | Refinery (Bors-style bisecting queue) | Phase merges in bash (sequential) |
| Escalation | Severity-routed (P0–P2) via Deacon/Mayor | Slack notification + `supervisor_log.md` |
| Inter-agent comms | Mailboxes + session handoff + seance | Mailbox files (simple) |
| Monitoring | Web dashboard (Go server) | Tauri/React dashboard (separate repo) |
| Logging | `.events.jsonl` per session | `orchestrator.jsonl` per project |
| Notifications | N/A (local only) | Slack with threading + channel routing |
| Dependencies | Go 1.25, Dolt, beads CLI, tmux, sqlite3 | bash, awk, git, curl (+ Node.js for dashboard) |
| Scale target | 20–30 agents | 4–8 agents |
| Config | TOML formulas + CLI (`gt`) commands | Single `orchestration.toml` |
| Distribution | `brew install gastown` / `npm install -g @gastown/gt` | Copy Stallions into project + `npm install -g racetrack` |

The key difference in philosophy: GasTown is a **product** — a full workspace manager with federation, a CLI command surface, database-backed state, and a Go runtime. Stallions is a **starter pack** — scripts you copy into a project and customize, with Racetrack as an optional dashboard app.

---

## 12. Risks and Mitigations

**Risk: TOML parsing dependency.** `tomlq` requires `pip install yq`.
→ **Mitigation:** The `.env` fallback requires only `grep`/`awk`. TOML is recommended but not required.

**Risk: Complexity creep.** Adding a supervisor, mailboxes, hooks, locking, logging, and Slack pushes the system past the "starter pack" threshold.
→ **Mitigation:** Every feature is independently optional. The minimal Stallions deployment is Phase 1 only (tag routing), which adds ~50 lines to `common.sh`. Users adopt further phases as needed.

**Risk: Tag assignment quality.** Bad tags from the Architect cause task routing misses.
→ **Mitigation:** Untagged tasks match any implementer (graceful fallback). The supervisor logs routing misses. A `retag.sh` utility script allows bulk re-tagging without re-running the Architect.

**Risk: Concurrent merge conflicts.** Multiple implementers committing to the same worktree.
→ **Mitigation:** The phase/worktree model isolates work by phase. Within a phase, locking ensures one agent per task. Same risk profile as v2.

**Risk: Slack bot token exposure.** If the token leaks, anyone can post to your channels.
→ **Mitigation:** Token is read from an environment variable, never stored in config files that might be committed. Setup instructions explicitly warn about this. Token can be rotated in the Slack app settings.

**Risk: Racetrack as a separate repo creates version drift.** The dashboard might not keep up with log format changes.
→ **Mitigation:** The JSONL schema has a `v` field. Racetrack handles unknown fields gracefully (ignores them). Breaking changes to the log format bump the version and are documented in a shared changelog.

**Risk: PTY management edge cases.** The Architect terminal session might get into a bad state (zombie process, encoding issues).
→ **Mitigation:** The dashboard provides a "Restart Architect" button. The sidecar has a watchdog that detects unresponsive PTYs and offers to restart them.

---

## 13. Scope Exclusions

To keep scope manageable, the following are explicitly out of scope for v3:

1. **Compiled orchestration binary.** The system stays as bash scripts. If performance becomes an issue at >10 agents, a future v4 could introduce a lightweight Go or Rust supervisor.

2. **Database-backed state.** AGENT_LOG.md remains the single source of truth.

3. **Agent-to-agent communication during invocation.** Agents don't talk to each other mid-task. Coordination happens between invocations.

4. **Distributed execution.** All agents run on the same machine.

5. **Discord/Teams notifications.** The `notify_external()` abstraction makes this easy to add, but only Slack ships in v3.

6. **GitHub links in Slack messages.** Notifications will include task IDs and titles but not hyperlinks to source files. Deferred to a future iteration.

7. **Dashboard command-and-control.** Racetrack reads orchestration state via files. It does not send commands to the supervisor (beyond the Architect PTY). If a kill command is needed, `Ctrl-C` on the supervisor terminal or `kill` on the process suffices. A WebSocket control channel may be added in a future iteration if demand emerges.

---

## 14. Example Deployment

Here's what deploying Stallions + Racetrack looks like on a full-stack SaaS project with a React frontend, Python/FastAPI backend, and Terraform infrastructure.

```bash
# 1. Copy Stallions into your project
cp -r stallions/* /path/to/my-saas/

# 2. Edit orchestration.toml to define your topology

# 3. Customize prompts
#    - prompts/backend.md → add FastAPI conventions, SQLAlchemy patterns
#    - prompts/frontend.md → add React/TypeScript standards
#    - prompts/devops.md → add Terraform workspace, AWS region specifics

# 4. Add lifecycle hooks
#    - hooks/backend/post_invoke.sh → `cd $WORKTREE && python -m pytest`
#    - hooks/frontend/post_invoke.sh → `cd $WORKTREE && npm run lint && npm test`

# 5. Set up Slack (optional)
export SLACK_BOT_TOKEN="xoxb-your-token-here"

# 6. Install Racetrack (optional, one-time)
npm install -g racetrack

# 7. Launch Racetrack (spawns Architect terminal inside it)
racetrack --project /path/to/my-saas/
# The Architect tab opens. Interact with it to create the plan and tasks.

# 8. After the Architect creates AGENT_LOG.md and tasks/, launch workers
./scripts/supervisor.sh
# Spawns: backend, frontend, reviewer, tester, devops agents
# Monitors health, re-spawns on failure, fires Slack notifications

# 9. Expose Racetrack to your phone via Tailscale Serve (optional)
tailscale serve 9400
# Now open https://<machine-name>.<tailnet>.ts.net/ on your phone
# Full dashboard UI — agent status, task board, progress — on your phone
# Tailscale handles HTTPS and auth (only your tailnet devices can access)

# 10. Monitor via CLI if you prefer
./scripts/status.sh

# 11. Slack notifications appear in your configured channels,
#     threaded per task for easy tracking
```

**The typical workflow loop:** Interact with the Architect in Racetrack to define the plan → supervisor launches your stallions → walk away → check Racetrack on your phone or get Slack pings → intervene only on merge conflicts or agent failures → come back to a completed project on `main`.

---

## 15. Decisions Log

All design decisions have been finalized. This section records the rationale for reference.

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| 1 | Config format | TOML (`orchestration.toml`) | Human-readable, used by GasTown for formulas, parsed via `tomlq`. `.env` fallback for minimal setups. |
| 2 | Tag granularity | Hierarchical from day one (`backend.api.auth`) | Prefix matching (`backend` matches `backend.api.*`) gives flexibility without complexity. |
| 3 | Provider config | Default in `[defaults]`, per-role overrides | Most projects use one provider; overrides are there for mixed setups (e.g., Codex for frontend, Claude for backend). |
| 4 | Parallel instances | Supported via `instances = N` in config | Task locking (§5.7) prevents races. Useful for large-phase parallelism. |
| 5 | Terminology | "Role" for type definition, "instance" for running agent | Clear, unambiguous, no quirky jargon. |
| 6 | Architect in dashboard | Interactive PTY in Racetrack's Architect tab | Supervisor launches it; provider-agnostic (any CLI agent works). |
| 7 | Supervisor ↔ dashboard | File-based (heartbeats, logs) | Supervisor doesn't need commands from the dashboard. Kill command is `Ctrl-C` or OS-level `kill`. WebSocket control channel deferred. |
| 8 | Dashboard distribution | Separate repo (`racetrack`), `npm install -g racetrack` or binary download | Keeps Stallions lean (pure bash + markdown). |
| 9 | Log format versioning | `"v": 1` in every JSONL entry | Racetrack handles unknown fields gracefully; breaking changes bump version. |
| 10 | Slack integration | Bot token + `chat.postMessage` (not incoming webhooks) | Required for both per-task threading (`thread_ts`) and per-event-type channel routing. Marginally more setup, significantly more capability. |
| 11 | Slack threading | Per-task threads, `ts` stored in `slack_threads/<TASK-ID>.ts` | All notifications about the same task appear as a thread in Slack. |
| 12 | Channel routing | Per-event-type channel IDs in `[notifications.slack.channels]` | Failures go to `#ops-alerts`, progress to `#dev-progress`, etc. |
| 13 | Dashboard auth | None (network-level via Tailscale Serve) | Racetrack serves on localhost. Remote access via `tailscale serve 9400` — tailnet provides authentication and HTTPS for free. |
| 14 | Naming | `stallions` (orchestration pack), `racetrack` (dashboard) | Coding agents are stallions; the dashboard is the racetrack where you watch them run. |
| 15 | GitHub links in Slack | Deferred to future iteration | Nice-to-have but adds config complexity (repo URL, branch mapping). |
| 16 | Remote phone access | Tailscale Serve exposing Racetrack's browser fallback | Clean, zero-config auth. Full dashboard UI on mobile over HTTPS. |
