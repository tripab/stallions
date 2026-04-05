# Multi-Agent Coding Starter Pack (v2)

A lightweight orchestration setup for running Architect → Implementer → Reviewer agents on any project. Provider-agnostic — works with Claude Code, Codex CLI, OpenCode, Aider, or any coding agent with a CLI.

## Quick Start

```bash
# 1. Copy this pack into your project root
cp -r scripts/ prompts/ schemas/ providers/ /path/to/your/project/

# 2. Initialize
cd /path/to/your/project
./scripts/setup.sh

# 3. Run the Architect interactively
claude --prompt-file prompts/architect.md

# 4. After Architect creates AGENT_LOG.md and tasks/, launch workers
./scripts/run_implementer.sh     # terminal 1
./scripts/run_reviewer.sh        # terminal 2
./scripts/run_qa_responder.sh    # terminal 3 (optional)

# 5. Check progress anytime
./scripts/status.sh
```

### Using a different coding agent

```bash
# OpenAI Codex CLI
./scripts/run_implementer.sh --provider providers/codex.sh
./scripts/run_reviewer.sh    --provider providers/codex.sh

# OpenCode (any model)
AGENT_MODEL=google:gemini-2.5-pro ./scripts/run_implementer.sh --provider providers/opencode.sh

# Aider
./scripts/run_implementer.sh --provider providers/aider.sh

# Your own — copy the template and adapt
cp providers/_template.sh providers/my-agent.sh
```

## Architecture

```
                    ┌────────────────┐
                    │   Architect    │  Interactive — creates plan,
                    │  (one-shot)    │  AGENT_LOG.md, task files
                    └───────┬────────┘
                            │ writes
              ┌─────────────┼──────────────┐
              ▼             ▼              ▼
        AGENT_LOG.md   tasks/TASK-*.md  IMPL_PLAN.md
              ▲             ▲
    reads ┌───┴──┐    reads │
          │ bash │──────────┘       ◄── shell pre-filters tasks
          └──┬───┘                      (zero tokens)
             │ injects task content
     ┌───────┴────────┐
     ▼                ▼
┌──────────┐   ┌───────────┐   ┌──────────────┐
│Implementer│   │ Reviewer  │   │QA Responder  │
│  (loop)   │   │  (loop)   │   │(loop/on-demand)│
└──────────┘   └───────────┘   └──────────────┘
     any provider    any provider     any provider
```

## Token Savings vs v1

The core insight: **bash can parse a markdown table for free; the coding agent cannot.**

| Hotspot | v1 Behavior | v2 Fix | Saving |
|---------|-------------|--------|--------|
| Task selection | Agent reads AGENT_LOG.md every invocation to find work | Bash `awk` parses the table, passes only the target task ID + content | ~500-1000 tokens/invocation |
| Implementer prompt | 3.5KB of instructions re-sent every loop iteration | Condensed to ~1.5KB; redundant steps removed | ~40% per invocation |
| Reviewer prompt | Agent runs `git diff` itself | Shell pre-computes the diff and injects it inline | ~200 tokens + 1 tool turn saved |
| Architect Phase E | Polls inside interactive session → unbounded context growth | Separate `run_qa_responder.sh` runs one-shot invocations | Prevents context blowup |
| No-op invocations | Agent invoked even when nothing to do, just to discover "nothing to do" | Shell detects WAITING/ALL_DONE states without invoking agent | 100% saving on idle cycles |
| Crash recovery | Approved tasks needed a full agent invocation to commit | Bash commits directly — `git add -A && git commit` | 100% saving per recovered task |
| Phantom polling | Prompt tells agent to "poll every 60s" in non-interactive mode (impossible) | Removed — polling is shell's job | Eliminates wasted instructions |
| Unbounded turns | No turn limit → agent could spin indefinitely | `--max-turns 25` (configurable via `MAX_TURNS` env var) | Caps worst-case cost |

**Estimated overall saving: 40-60% token reduction per implementer/reviewer cycle.**

## Key Features

### Automatic Phase Merging

When the Architect creates separate git worktrees per phase, each branches off `main` at creation time. Phase 2's worktree doesn't have phase 1's code. The implementer runner handles this automatically:

1. Before invoking the agent for a task in phase N, the shell checks if all tasks in phases 1..(N-1) are "Done"
2. For each completed prior phase not yet merged, it runs `git merge` into `main`
3. Then merges `main` into phase N's worktree so the agent sees all prior work
4. When all tasks are complete, a final `merge_all_phases` merges everything into `main` before the implementer exits

This happens entirely in bash (zero tokens). If a merge conflict occurs, the script pauses with an error and waits for you to resolve it manually before retrying.

### Crash Recovery

If the workflow crashes mid-run, just restart the scripts. The implementer detects "Approved" tasks (reviewed but not yet committed) and handles them in pure bash — `git add -A && git commit` plus AGENT_LOG update — without spending any tokens. It also handles the edge case where the commit happened but the status update didn't.

### Desktop Notifications

Every meaningful event fires a notification so you can work on other things:

- **Terminal bell** (`\a`) — works in every terminal, triggers tab/window attention indicators
- **macOS**: native notification center via `osascript` + system sounds (Glass for success, Basso for errors)
- **Linux**: `notify-send` with urgency levels

Events notified: task committed, task submitted for review, review approved, review comments posted, phase merge conflicts, all-tasks-done. Set `NOTIFY=0` to disable.

### Provider-Agnostic Design

All runner scripts call `invoke_coding_agent()` which reads the prompt from stdin. The default implementation uses Claude Code. Pass `--provider path/to/provider.sh` to use any other CLI agent.

A provider file is a shell script that defines one function:

```bash
invoke_coding_agent() {
  # Read prompt from stdin, pass to your agent, run to completion
  my-agent --non-interactive --model "$AGENT_MODEL"
}
```

Included providers: `claude.sh` (default), `codex.sh` (OpenAI), `opencode.sh` (multi-model), `aider.sh`, and `_template.sh` for building your own.

Environment variables available to providers: `AGENT_MODEL`, `AGENT_MAX_TURNS`, `AGENT_EFFORT`, `AGENT_ALLOWED_TOOLS`.

## Configuration

Environment variables (set before running scripts or export in shell):

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_TURNS` | 25 | Max tool-use turns per agent invocation |
| `AGENT_MODEL` | sonnet | Model to use (provider-specific format) |
| `AGENT_EFFORT` | (unset) | Effort level (reviewer defaults to "high") |
| `PROMPTS_DIR` | ./prompts | Path to agent prompt files |
| `SIGNAL_DIR` | /tmp/claude-agents | Directory for inter-agent signals |
| `QA_POLL_INTERVAL` | 120 | Seconds between QA responder polls |
| `NOTIFY` | 1 | Set to 0 to disable desktop notifications |

## Customization

**Change the project name**: Replace `<project-name>` in all `prompts/*.md` files.

**Change the language/framework**: The implementer prompt references Swift/Xcode by default. Adapt the test command and code standards section to match your stack.

**Add a Tester agent**: Copy the implementer pattern — add a `run_tester.sh` that finds tasks with status "In Review", runs the test suite, and updates results.

**Override prompts directory**: Set `PROMPTS_DIR` to point prompts at a provider-native location if desired (e.g., `PROMPTS_DIR=.claude/prompts` or `PROMPTS_DIR=.codex/prompts`).

## File Structure

```
your-project/
├── prompts/
│   ├── architect.md        # Interactive planning prompt
│   ├── implementer.md      # Compact implementation instructions
│   └── reviewer.md         # Compact review instructions
├── schemas/
│   ├── AGENT_LOG_SCHEMA.md # Template for AGENT_LOG.md
│   └── TASK_SCHEMA.md      # Template for task files
├── providers/
│   ├── claude.sh           # Claude Code (default, documented as reference)
│   ├── codex.sh            # OpenAI Codex CLI
│   ├── opencode.sh         # OpenCode (multi-model)
│   ├── aider.sh            # Aider
│   └── _template.sh        # Copy this for your own agent
├── scripts/
│   ├── common.sh           # Shared utilities (task parsing, merge, notify, provider)
│   ├── run_implementer.sh  # Implementer loop with shell-side task selection
│   ├── run_reviewer.sh     # Reviewer loop with shell-side task selection + diff injection
│   ├── run_qa_responder.sh # Lightweight Q&A answering (replaces Architect Phase E)
│   ├── setup.sh            # One-time project initialization
│   └── status.sh           # Progress dashboard (zero tokens)
├── AGENT_LOG.md            # Created by Architect
├── IMPLEMENTATION_PLAN.md  # Created by Architect
└── tasks/                  # Created by Architect
    ├── TASK-001.md
    ├── TASK-002.md
    └── ...
```
