# Stallions - A Lightweight Multi-Agent Orchestration Setup

A lightweight orchestration setup for running multiple specialised coding agents on any project. Provider-agnostic — works with Claude Code, Codex CLI, OpenCode, Aider, or any agent with a CLI. Everything is bash + markdown: no daemon, no database, no compiled binary.

> **Design philosophy**: bash does the filtering and coordination, the coding agent only ever sees the single task it needs to work on. Token savings are paramount.

## Quick Start

```bash
# 1. Copy this pack into your project root
cp -r scripts/ prompts/ schemas/ providers/ orchestration.toml /path/to/your/project/

# 2. Initialize
cd /path/to/your/project
./scripts/setup.sh

# 3. Edit orchestration.toml to match your stack (roles, tags, model)
#    Skip this step for single-implementer projects — defaults work as-is.

# 4. Run the Architect interactively
#    Start from a problem statement (Architect drafts the plan), or pass an
#    existing implementation plan as an argument to skip straight to file creation:
claude --system-prompt-file prompts/architect.md
#    or, with a plan already written:
#    claude --system-prompt-file prompts/architect.md "Use the plan in IMPLEMENTATION_PLAN.md"

# 5. After the Architect creates AGENT_LOG.md and tasks/, launch workers
#    Option A — supervisor (spawns all roles from orchestration.toml)
./scripts/supervisor.sh

#    Option B — manual (launch each role in its own terminal)
./scripts/run_agent.sh --role implementer   # terminal 1
./scripts/run_agent.sh --role reviewer      # terminal 2
./scripts/run_agent.sh --role qa            # terminal 3 (optional)

# 6. Check progress anytime
./scripts/status.sh
```

### Role-specific agents

```bash
# Launch a backend-specialised agent (reads prompts/backend.md, handles backend.* tags)
./scripts/run_agent.sh --role backend

# Launch a frontend agent with a different provider
./scripts/run_agent.sh --role frontend --provider providers/codex.sh

# Run qa_responder once and exit
./scripts/run_agent.sh --role qa --once

# v2 shims still work unchanged
./scripts/run_implementer.sh --provider providers/opencode.sh
```

## Architecture

```mermaid
flowchart TD
    config["orchestration.toml\nroles · tags · logging"]
    supervisor["supervisor.sh\nspawns & monitors"]
    backend["run_agent.sh\n--role backend"]
    frontend["run_agent.sh\n--role frontend"]
    reviewer["run_agent.sh\n--role reviewer"]
    agent_impl["coding agent\n(any provider)"]
    agent_rev["coding agent\n(any provider)"]
    files["AGENT_LOG.md\ntasks/TASK-*.md\nlogs/*.jsonl"]
    signals["$SIGNAL_DIR\nmailboxes/ · locks/\nheartbeats/"]

    config -->|reads| supervisor
    supervisor --> backend
    supervisor --> frontend
    supervisor --> reviewer
    backend -->|bash pre-filters\ninjects single task| agent_impl
    frontend -->|bash pre-filters\ninjects single task| agent_impl
    reviewer -->|bash pre-filters\ninjects diff + task| agent_rev
    agent_impl -->|writes status| files
    agent_rev -->|writes status| files
    agent_impl -->|send_mail on In Review| signals
    reviewer -->|check_mail · claim_task| signals
```

`run_implementer.sh`, `run_reviewer.sh`, and `run_qa_responder.sh` are one-line shims that delegate to the generic **`run_agent.sh`**, which reads its behaviour (prompt, tags, model, hooks) from `orchestration.toml`.

## Configuration: orchestration.toml

```toml
[project]
name      = "my-saas-app"
log_file  = "AGENT_LOG.md"
tasks_dir = "tasks"

[defaults]
provider  = "providers/claude.sh"
model     = "sonnet"
max_turns = 25

[logging]
level             = "standard"   # minimal | standard | verbose
capture_responses = true

[roles.backend]
type        = "implementer"
prompt      = "prompts/backend.md"
tags        = ["backend", "backend.api", "backend.db"]
instances   = 1

[roles.frontend]
type        = "implementer"
prompt      = "prompts/frontend.md"
tags        = ["frontend", "frontend.ui"]
provider    = "providers/codex.sh"   # per-role provider override

[roles.reviewer]
type    = "reviewer"
tags    = ["*"]     # reviews all task types
effort  = "high"

[roles.qa]
type          = "qa_responder"
poll_interval = 120
```

Parsing requires `tomlq` (`pip install yq`). Without it, settings fall back to `.env.orchestration`.

## Tag-Based Task Routing

Tasks in `AGENT_LOG.md` carry a Tags column:

```markdown
| ID       | Title                   | Phase | Status  | Depends On | Tags          |
|----------|-------------------------|-------|---------|------------|---------------|
| TASK-001 | Project scaffold        | 1     | Pending | —          | backend, infra |
| TASK-002 | React component library | 1     | Pending | TASK-001   | frontend.ui   |
| TASK-003 | REST API endpoints      | 2     | Pending | TASK-001   | backend.api   |
```

Routing uses **prefix matching**: a role with `tags = ["backend"]` claims tasks tagged `backend`, `backend.api`, `backend.api.auth`, etc. The wildcard `"*"` matches everything (used by reviewer). Tasks with no tags can be claimed by any implementer (v2 backwards compatibility).

## Key Features

### Generic Agent Runner

`run_agent.sh --role <name>` loads the role definition from `orchestration.toml`, resolves the prompt file, model, tags, and hooks, then dispatches to one of three lifecycle functions:

- `lifecycle_implementer()` — picks tasks, invokes agent, commits approved work
- `lifecycle_reviewer()` — finds "In Review" tasks, injects the git diff, invokes agent
- `lifecycle_qa_responder()` — answers design questions as one-shot invocations

All three are defined in `common.sh` and can be used independently of `run_agent.sh`.

### Task Locking

When multiple implementer instances run in parallel, `claim_task()` / `release_task()` prevent races. The lock is an atomic `mkdir` on `$SIGNAL_DIR/locks/<task_id>.lock/` — only one process wins.

```mermaid
sequenceDiagram
    participant A as implementer_0
    participant B as implementer_1
    participant L as locks/TASK-003.lock

    A->>L: mkdir (claim_task)
    Note over L: created — A wins
    B->>L: mkdir (claim_task)
    Note over B: returns 1 — skip to next candidate
    A->>L: rm -rf (release_task after In Review)
```

`find_actionable_task()` and `find_tagged_task()` skip locked tasks automatically, so agents route around each other without polling.

### Mailbox Messaging

Implementers notify the reviewer the moment a task transitions to "In Review" — no polling delay:

```mermaid
sequenceDiagram
    participant I as lifecycle_implementer
    participant M as mailboxes/reviewer_0/inbox
    participant R as lifecycle_reviewer

    I->>M: send_mail "task_ready" TASK-003
    Note over R: next loop iteration
    R->>M: check_mail → ack_mail
    Note over R: skips 60s sleep, reviews immediately
```

Mail files live in `$SIGNAL_DIR/mailboxes/<role>/inbox/` and are moved to `processed/` after acknowledgement.

### Lifecycle Hooks

Optional shell scripts run before and after each agent invocation. Zero tokens spent — pure bash.

```
hooks/
├── backend/
│   ├── pre_invoke.sh    # e.g. run DB migrations
│   └── post_invoke.sh   # e.g. run linter, type-checker
└── frontend/
    └── post_invoke.sh   # e.g. run Storybook snapshots
```

Scripts receive `$1=TASK_ID` and `$2=WORKTREE_PATH`. Non-zero exit aborts the invocation.

### Structured JSONL Logging

Every agent invocation writes a versioned log entry:

```jsonl
{"v":1,"id":"inv_20260405_142247_backend_0","timestamp":"2026-04-05T14:22:47Z",
 "role":"backend","instance":0,"task_id":"TASK-003","mode":"fresh",
 "provider":"providers/claude.sh","model":"sonnet","phase":"2",
 "duration_seconds":187,"exit_code":0,"outcome":"In Review",
 "tokens":{"input":42300,"output":12800,"cache_read":8200,"cache_write":3100},
 "response_summary":"Implemented REST API endpoints...","errors":[]}
```

Log files: `logs/orchestrator.jsonl` (all agents combined), `logs/agents/<role>_<N>.jsonl` (per instance), `logs/responses/` (optional full response capture, controlled by `logging.capture_responses`).

### Token Savings

The core insight: **bash can parse a markdown table for free; the coding agent cannot.**

| Hotspot | Behaviour | Saving |
|---------|-----------|--------|
| Task selection | `awk` parses AGENT_LOG.md, passes only the target task | ~500–1000 tokens/invocation |
| Tag-based routing | Tags filter tasks in bash before any agent is invoked | 0 tokens on non-matching tasks |
| Reviewer diff | Shell pre-computes `git diff` and injects it inline | ~200 tokens + 1 tool turn |
| QA responder | One-shot invocations instead of polling inside a session | Prevents context blowup |
| Idle detection | Shell detects no-work states without invoking agent | 100% saving on idle cycles |
| Crash recovery | Approved→Done commit runs in pure bash | 100% saving per recovered task |
| Mailbox wake-up | Reviewer skips 60s poll sleep when mail arrives | Faster review cycle |
| Task locking | Agents skip locked tasks without invoking | 0 tokens on race-lost candidates |

**Estimated overall saving: 60–90% token reduction vs. naive agent-driven coordination.**

### Automatic Phase Merging

When the Architect creates one git worktree per phase, phase N's worktree branches off `main` at creation time — it doesn't have phase N-1's code. Before invoking the agent for any phase-N task, the shell:

1. Checks if all tasks in phases 1..(N-1) are Done
2. Merges each completed prior phase branch into `main`
3. Merges `main` into the phase-N worktree

All in bash. Merge conflicts pause the script with an error; resolve manually and retry.

### Crash Recovery

Restart any runner script after a crash — it picks up exactly where it left off. Approved-but-not-committed tasks are committed in pure bash (zero tokens) on the next loop iteration.

### Supervisor

`supervisor.sh` reads `orchestration.toml` and manages the full agent fleet:

- Spawns one `run_agent.sh` process per role instance (`instances > 0`, `type != interactive`)
- Every agent writes a heartbeat file at `$SIGNAL_DIR/heartbeats/<role>_<instance>.heartbeat`
- The supervisor checks PID liveness and heartbeat age every `heartbeat_interval` seconds
- On failure: increments a per-agent restart counter; waits `restart_backoff` seconds then re-spawns
- After `max_restart_count` consecutive failures: records an escalation row in `supervisor_log.md` and fires a notification
- Shuts down all agents gracefully on `Ctrl-C` (SIGTERM → 10 s wait → SIGKILL)

```bash
./scripts/supervisor.sh          # spawn all roles + monitor loop
./scripts/supervisor.sh --once   # spawn only, exit immediately (agents run independently)
```

Supervisor config lives in `orchestration.toml`:

```toml
[supervisor]
heartbeat_interval = 30   # seconds between health checks
max_restart_count  = 3    # consecutive failures before giving up
restart_backoff    = 60   # seconds to wait between restarts
notify             = true
```

### Notifications

Every meaningful agent event fires through `notify_external()` — a single call-point that delivers both desktop notifications and Slack messages.

**Event types and where they fire:**

| Event | Fired in | Meaning |
|-------|----------|---------|
| `task_in_review` | `lifecycle_implementer` | Task submitted for review |
| `task_committed` | `lifecycle_implementer` | Task committed and Done |
| `review_submitted` | `lifecycle_reviewer` | Reviewer requested changes |
| `review_approved` | `lifecycle_reviewer` | Reviewer approved |
| `phase_merged` | `ensure_phases_merged` | Prior phase merged into main |
| `phase_merge_needed` | `ensure_phases_merged` | Merge conflict — manual resolution needed |
| `agent_failed` | `supervisor.sh` | Agent exceeded max restarts |
| `all_tasks_done` | `supervisor.sh` | All agents completed |

Desktop notifications use `osascript` (macOS) or `notify-send` (Linux). Slack is optional — see [Slack Setup](#slack-setup) below.

### Slack Setup

Slack notifications are **opt-in** and never block or fail a running agent.

#### 1. Create a Slack app

1. Go to [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From scratch**
2. Name it (e.g. `Stallions Orchestrator`) and pick your workspace

#### 2. Grant bot token scopes

Under **OAuth & Permissions → Scopes → Bot Token Scopes**, add:

| Scope | Why |
|-------|-----|
| `chat:write` | Post messages to channels the bot is a member of |
| `chat:write.public` | Post to any public channel without joining |

#### 3. Install to workspace

Click **Install to Workspace** → copy the **Bot User OAuth Token** (starts with `xoxb-`).

> **Never commit this token.** Export it as an environment variable only.

#### 4. Get channel IDs

For each channel you want notifications sent to, right-click the channel name in Slack → **Copy link** → the ID is the last path segment (e.g. `C0XXXXXXX`).

Alternatively: open the channel in a browser — the URL ends in `/CXXXXXXXX`.

#### 5. Configure orchestration.toml

```toml
[notifications]
enabled = true   # flip this to activate

[notifications.slack]
bot_token_env   = "SLACK_BOT_TOKEN"   # env var name — never put the token here
default_channel = "C0GENERAL123"      # fallback for unrouted events
username        = "Orchestrator"
icon_emoji      = ":robot_face:"
thread_per_task = true                # group all events for a task into one thread

[notifications.slack.channels]
task_in_review    = "C0DEV000001"   # #dev-progress
task_committed    = "C0DEV000001"
review_submitted  = "C0DEV000001"
review_approved   = "C0DEV000001"
phase_merged      = "C0OPS000001"   # #ops-alerts
phase_merge_needed = "C0OPS000001"
agent_failed      = "C0OPS000001"
all_tasks_done    = "C0DEV000001"
```

Leave any channel empty (`""`) to use `default_channel` for that event type.

#### 6. Export the token and enable

```bash
export SLACK_BOT_TOKEN="xoxb-your-token-here"
export SLACK_ENABLED="true"

# Then launch agents as normal
./scripts/supervisor.sh
```

`SLACK_ENABLED` is checked at notification time. If it is unset or `false`, all Slack calls are skipped silently — no impact on agent behaviour.

#### 7. Thread grouping

When `thread_per_task = true`, the first Slack message for a task creates a thread. All subsequent events for the same task reply in that thread. Thread timestamps are stored in `$SIGNAL_DIR/slack_threads/<task_id>.ts` (default: `/tmp/claude-agents/slack_threads/`).

To use a persistent signal dir across runs:

```bash
export SIGNAL_DIR="$HOME/.stallions/signals"
```

#### Troubleshooting

| Symptom | Likely cause |
|---------|-------------|
| No messages appearing | `SLACK_ENABLED` not set to `"true"` |
| `not_in_channel` error in logs | Bot not invited to the channel — `/invite @YourBotName` in Slack |
| `invalid_auth` | Token expired or wrong scope — regenerate in the Slack app dashboard |
| Messages going to wrong channel | Check `[notifications.slack.channels]` key names match exactly |
| No threading | `thread_per_task = false` or `SIGNAL_DIR` changed between runs (old `.ts` files lost) |

### Provider-Agnostic Design

All runners call `invoke_coding_agent()` which reads the prompt from stdin. Default is Claude Code. Pass `--provider path/to/provider.sh` to use any CLI agent.

```bash
invoke_coding_agent() {
  # Read prompt from stdin, pass to your agent, run to completion
  my-agent --non-interactive --model "$AGENT_MODEL"
}
```

Included providers: `claude.sh` (default), `codex.sh` (OpenAI), `opencode.sh` (multi-model), `aider.sh`, `_template.sh`.

## File Structure

```
your-project/
├── orchestration.toml          # Agent topology, roles, tags, logging, notifications
├── prompts/
│   ├── architect.md            # Interactive planning prompt
│   ├── implementer.md          # Generic implementer (fallback)
│   ├── reviewer.md             # Reviewer instructions
│   ├── backend.md              # Backend-specialised implementer
│   ├── frontend.md             # Frontend-specialised implementer
│   ├── tester.md               # Test-suite-focused implementer
│   ├── devops.md               # Infrastructure-focused implementer
│   └── qa.md                   # Design Q&A responder
├── schemas/
│   ├── AGENT_LOG_SCHEMA.md     # Task Index schema (ID, Title, Phase, Status, Deps, Tags)
│   └── TASK_SCHEMA.md          # Per-task file template
├── providers/
│   ├── claude.sh               # Claude Code (default)
│   ├── codex.sh                # OpenAI Codex CLI
│   ├── opencode.sh             # OpenCode (multi-model)
│   ├── aider.sh                # Aider
│   └── _template.sh            # Copy this for your own agent
├── scripts/
│   ├── common.sh               # Shared utilities: task parsing, lifecycle functions,
│   │                           #   config loading, logging, token parsing, hooks,
│   │                           #   task locking (claim/release), mailbox functions
│   ├── run_agent.sh            # Generic runner — dispatches by role type
│   ├── run_implementer.sh      # v2 shim → run_agent.sh --role implementer
│   ├── run_reviewer.sh         # v2 shim → run_agent.sh --role reviewer
│   ├── run_qa_responder.sh     # v2 shim → run_agent.sh --role qa
│   ├── supervisor.sh           # Spawns & monitors all agents from orchestration.toml
│   ├── setup.sh                # One-time project initialization
│   └── status.sh               # Progress dashboard: overall + per-role breakdown (zero tokens)
├── hooks/                      # Optional lifecycle hooks (user-provided)
│   ├── backend/
│   │   ├── pre_invoke.sh
│   │   └── post_invoke.sh
│   └── frontend/
│       └── post_invoke.sh
├── logs/                       # Created at runtime
│   ├── orchestrator.jsonl      # All-agent combined invocation log
│   ├── agents/                 # Per-instance logs
│   └── responses/              # Full agent output (when capture_responses = true)
├── supervisor_log.md           # Escalation records (created when an agent exceeds max restarts)
├── AGENT_LOG.md                # Created by Architect
├── IMPLEMENTATION_PLAN.md      # Created by Architect
└── tasks/                      # Created by Architect
    ├── TASK-001.md
    └── ...
```

## Environment Variables

All settings have `orchestration.toml` equivalents. Env vars are useful for one-off overrides:

| Variable | Default | Description |
|----------|---------|-------------|
| `AGENT_MODEL` | sonnet | Model name (provider-specific format) |
| `AGENT_MAX_TURNS` | 25 | Max tool-use turns per invocation |
| `AGENT_EFFORT` | (unset) | Effort level (reviewer defaults to "high") |
| `PROMPTS_DIR` | ./prompts | Path to agent prompt files |
| `SIGNAL_DIR` | /tmp/claude-agents | Directory for heartbeats, Slack threads, locks, mailboxes |
| `LOG_LEVEL` | standard | `minimal` \| `standard` \| `verbose` |
| `CAPTURE_RESPONSES` | true | Save full agent output to `logs/responses/` |
| `NOTIFY` | 1 | Set to `0` to disable desktop/terminal notifications |
| `SLACK_ENABLED` | false | Set to `"true"` to activate Slack notifications |
| `SLACK_BOT_TOKEN` | (unset) | Slack bot OAuth token (`xoxb-…`) — never commit this |

## Migration Guide

Stallions is designed to be adopted incrementally. Each layer adds capability without breaking what came before.

```mermaid
flowchart LR
    v1["v1\nManual terminals\nrun_implementer.sh"] -->|add orchestration.toml\nrun_agent.sh| v2
    v2["v2\nRole-based runner\ntag routing\nJSONL logging"] -->|add supervisor.sh\nSlack notifications| v3
    v3["v3\nSupervised fleet\nheartbeat monitoring\nSlack threads"] -->|add mailboxes\ntask locking\nprompt templates| v4
    v4["v4\nMulti-agent safe\nfast reviewer wake-up\nspecialised prompts"]
```

| What changed | Before | After |
|---|---|---|
| Runner scripts | `run_implementer.sh` etc. | One-line shims → `run_agent.sh` |
| New agent types | Write a new `run_<type>.sh` | Add a `[roles.<name>]` block to `orchestration.toml` |
| Task routing | First Pending task with deps met | Tag-based prefix matching |
| Config | Environment variables only | `orchestration.toml` + env overrides |
| Logging | Activity log in AGENT_LOG.md | Structured JSONL per invocation |
| Supervision | Open N terminals manually | `supervisor.sh` spawns and monitors all agents |
| Multi-agent safety | Race conditions possible | `claim_task()` / `release_task()` atomic locking |
| Reviewer latency | 60s poll interval | Instant wake-up via mailbox on task submission |
| Prompt coverage | Generic implementer only | Role-specific prompts for backend, frontend, tester, devops, qa |
