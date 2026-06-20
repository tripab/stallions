#!/bin/bash
# setup.sh — Initialize project directory for multi-agent orchestration.
# Run once at the start of a new project.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; RESET='\033[0m'

echo -e "${CYAN}Setting up multi-agent project structure...${RESET}"

# Create directories
mkdir -p "$PROJECT_ROOT/tasks"
mkdir -p "$PROJECT_ROOT/schemas"
mkdir -p "$PROJECT_ROOT/prompts"
mkdir -p "$PROJECT_ROOT/scripts"
mkdir -p "$PROJECT_ROOT/providers"
mkdir -p "$PROJECT_ROOT/logs/agents"
mkdir -p "$PROJECT_ROOT/logs/responses"

# Ensure git repo exists
if ! git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree &>/dev/null; then
  echo -e "${GREEN}Initializing git repository...${RESET}"
  git -C "$PROJECT_ROOT" init
fi

# Add .worktrees to .gitignore if not already there
GITIGNORE="$PROJECT_ROOT/.gitignore"
touch "$GITIGNORE"
grep -qxF '.worktrees/' "$GITIGNORE" 2>/dev/null || echo '.worktrees/' >> "$GITIGNORE"

# Copy orchestration.toml template if not already present
TOML_TEMPLATE="$SCRIPT_DIR/../orchestration.toml"
TOML_TARGET="$PROJECT_ROOT/orchestration.toml"
if [ ! -f "$TOML_TARGET" ]; then
  if [ -f "$TOML_TEMPLATE" ]; then
    cp "$TOML_TEMPLATE" "$TOML_TARGET"
    echo -e "${GREEN}Created orchestration.toml from template.${RESET}"
  else
    echo -e "${RED}Warning: orchestration.toml template not found at $TOML_TEMPLATE${RESET}"
  fi
else
  echo -e "${CYAN}orchestration.toml already exists — skipping copy.${RESET}"
fi

# Make scripts and providers executable
chmod +x "$PROJECT_ROOT/scripts/"*.sh 2>/dev/null || true
chmod +x "$PROJECT_ROOT/providers/"*.sh 2>/dev/null || true

echo ""
echo -e "${GREEN}✅ Setup complete.${RESET}"
echo ""
echo "Next steps:"
echo "  1. Edit orchestration.toml to configure your project topology."
echo "     (Or skip — defaults work for single-implementer projects.)"
echo ""
echo "     ⚠️  Slack notifications: set enabled=true in [notifications] and export"
echo "     SLACK_BOT_TOKEN=xoxb-your-token before running agents."
echo ""
echo "  2. Open the Architect agent interactively:"
echo "     claude --system-prompt-file prompts/architect.md"
echo "     # Already have a plan? Point the Architect at it to skip drafting:"
echo "     # claude --system-prompt-file prompts/architect.md \"Use the plan in IMPLEMENTATION_PLAN.md\""
echo ""
echo "  3. After the Architect creates AGENT_LOG.md and tasks/, launch workers:"
echo "     # v3: supervisor spawns all agents from orchestration.toml"
echo "     ./scripts/supervisor.sh"
echo ""
echo "     # Or launch individual agents manually (v2-compatible):"
echo "     ./scripts/run_agent.sh --role implementer   (terminal 1)"
echo "     ./scripts/run_agent.sh --role reviewer      (terminal 2)"
echo "     ./scripts/run_agent.sh --role qa            (terminal 3, optional)"
echo ""
echo "  4. Check progress anytime:"
echo "     ./scripts/status.sh"
echo ""
echo "  To use a different provider:"
echo "     ./scripts/run_agent.sh --role backend --provider providers/codex.sh"
echo ""
echo "  Logs are written to logs/orchestrator.jsonl and logs/agents/<role>_<N>.jsonl"
echo ""
