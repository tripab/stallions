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

# Ensure git repo exists
if ! git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree &>/dev/null; then
  echo -e "${GREEN}Initializing git repository...${RESET}"
  git -C "$PROJECT_ROOT" init
fi

# Add .worktrees to .gitignore if not already there
GITIGNORE="$PROJECT_ROOT/.gitignore"
touch "$GITIGNORE"
grep -qxF '.worktrees/' "$GITIGNORE" 2>/dev/null || echo '.worktrees/' >> "$GITIGNORE"

# Make scripts and providers executable
chmod +x "$PROJECT_ROOT/scripts/"*.sh 2>/dev/null || true
chmod +x "$PROJECT_ROOT/providers/"*.sh 2>/dev/null || true

echo ""
echo -e "${GREEN}✅ Setup complete.${RESET}"
echo ""
echo "Next steps:"
echo "  1. Open the Architect agent interactively:"
echo "     claude --prompt-file prompts/architect.md"
echo ""
echo "  2. After the Architect creates AGENT_LOG.md and tasks/, launch workers:"
echo "     ./scripts/run_implementer.sh   (terminal 1)"
echo "     ./scripts/run_reviewer.sh      (terminal 2)"
echo "     ./scripts/run_qa_responder.sh  (terminal 3, optional)"
echo ""
echo "  3. Check progress anytime:"
echo "     ./scripts/status.sh"
echo ""
echo "  To use a different coding agent:"
echo "     ./scripts/run_implementer.sh --provider providers/codex.sh"
echo ""
