# Stallions v3 — Multi-Agent Orchestration Starter Pack

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
claude --prompt-file prompts/architect.md

# 5. After the Architect creates AGENT_LOG.md and tasks/, launch workers
#    Option A — supervisor (v3, spawns all roles from orchestration.toml)
./scripts/supervisor.sh

#    Option B — manual (v2-compatible, launch each role in its own terminal)
./scripts/run_agent.sh --role implementer   # terminal 1
./scripts/run_agent.sh --role reviewer      # terminal 2
./scripts/run_agent.sh --role qa            # terminal 3 (optional)

# 6. Check progress anytime
./scripts/status.sh
```

### Role-specific agents (v3)

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

```
                              ┌──────────────────────┐
                              │   orchestration.toml  │
                              │  roles, tags, logging │
                              └──────────┬───────────┘
                                         │ reads
                              ┌──────────▼───────────┐
                              │     supervisor.sh     │
                              │  spawns & monitors    │
                              └──┬──────┬──────┬──────┘
                                 │      │      │
                        ┌────────┘  ┌───┘  ┌──┘
                        ▼           ▼      ▼
                  run_agent.sh  run_agent.sh  run_agent.sh
                  --role backend  --role frt   --role reviewer
                        │           │              │
                        └─────┬─────┘              │
                              │ bash pre-filters    │ bash pre-filters
                              │ injects single task │ injects diff + task
                              ▼                     ▼
                        coding agent           coding agent
                        (any provider)         (any provider)
                              │                     │
                              └──────┬──────────────┘
                                     │ writes
                              ┌──────▼──────────────┐
                              │    AGENT_LOG.md      │
                              │  tasks/TASK-*.md     │
                              │  logs/*.jsonl        │
                              └─────────────────────┘
```

The key structural change from v2: `run_implementer.sh`, `run_reviewer.sh`, and `run_qa_responder.sh` are now one-line shims that delegate to the generic **`run_agent.sh`**, which reads its behaviour (prompt, tags, model, hooks) from `orchestration.toml`.

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

**Estimated overall saving: 60–90% token reduction vs. naive agent-driven coordination.**

### Automatic Phase Merging

When the Architect creates one git worktree per phase, phase N's worktree branches off `main` at creation time — it doesn't have phase N-1's code. Before invoking the agent for any phase-N task, the shell:

1. Checks if all tasks in phases 1..(N-1) are Done
2. Merges each completed prior phase branch into `main`
3. Merges `main` into the phase-N worktree

All in bash. Merge conflicts pause the script with an error; resolve manually and retry.

### Crash Recovery

Restart any runner script after a crash — it picks up exactly where it left off. Approved-but-not-committed tasks are committed in pure bash (zero tokens) on the next loop iteration.

### Supervisor (v3)

`supervisor.sh` reads `orchestration.toml` and manages the full agent fleet:

- Spawns one `run_agent.sh` process per role instance
- Monitors heartbeat files; restarts agents that crash or go silent
- Caps restarts at `max_restart_count` then escalates
- Shuts down all agents gracefully on `Ctrl-C`

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
│   │                           #   config loading, logging, token parsing, hooks
│   ├── run_agent.sh            # Generic runner — dispatches by role type
│   ├── run_implementer.sh      # v2 shim → run_agent.sh --role implementer
│   ├── run_reviewer.sh         # v2 shim → run_agent.sh --role reviewer
│   ├── run_qa_responder.sh     # v2 shim → run_agent.sh --role qa
│   ├── supervisor.sh           # Spawns & monitors all agents from orchestration.toml
│   ├── setup.sh                # One-time project initialization
│   └── status.sh               # Progress dashboard (zero tokens)
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
| `SIGNAL_DIR` | /tmp/claude-agents | Directory for heartbeats and mailboxes |
| `LOG_LEVEL` | standard | minimal \| standard \| verbose |
| `CAPTURE_RESPONSES` | true | Save full agent output to logs/responses/ |
| `NOTIFY` | 1 | Set to 0 to disable desktop notifications |
| `SLACK_BOT_TOKEN` | (unset) | Slack bot token for remote notifications |

## v2 → v3 Migration

v3 is a **superset of v2** — all v2 scripts still work unchanged.

| What changed | v2 | v3 |
|---|---|---|
| Runner scripts | `run_implementer.sh` etc. | One-line shims → `run_agent.sh` |
| New agent types | Write a new `run_<type>.sh` | Add a `[roles.<name>]` block to `orchestration.toml` |
| Task routing | First Pending task with deps met | Tag-based prefix matching |
| Config | Environment variables only | `orchestration.toml` + env overrides |
| Logging | Activity log in AGENT_LOG.md | Structured JSONL per invocation |
| Supervision | Open N terminals manually | `supervisor.sh` spawns and monitors all agents |
