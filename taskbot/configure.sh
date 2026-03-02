#!/bin/bash
#
# taskbot configure — interactive setup for a project
#
# Creates docs/taskbot.json, copies AGENT_INSTRUCTIONS.md and TASK_TEMPLATE.md,
# and creates docs/dev/ and docs/done/ directories.
#
# Usage: ./configure.sh <project-dir>
#

set -euo pipefail

TASKBOT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

ask() { echo -en "${BLUE}$1${NC} "; }
ok()  { echo -e "${GREEN}$1${NC}"; }

# ── Validate arguments ────────────────────────────────────────────────
if [ -z "${1:-}" ]; then
  echo "Usage: $0 <project-dir>"
  exit 1
fi

PROJECT_DIR="$(realpath "$1")"
DOCS_DIR="$PROJECT_DIR/docs"

if [ ! -d "$PROJECT_DIR" ]; then
  echo "Directory not found: $PROJECT_DIR"
  exit 1
fi

PROJECT_NAME="$(basename "$PROJECT_DIR")"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Configuring taskbot for: $PROJECT_NAME"
echo "  Path: $PROJECT_DIR"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check if already configured
if [ -f "$DOCS_DIR/taskbot.json" ]; then
  ask "taskbot.json already exists. Overwrite? [y/N]"
  read -r overwrite
  if [ "$overwrite" != "y" ] && [ "$overwrite" != "Y" ]; then
    echo "Aborted."
    exit 0
  fi
fi

# ── Interview ─────────────────────────────────────────────────────────

# Project name
ask "Project name [$PROJECT_NAME]:"
read -r input_name
PROJECT_NAME="${input_name:-$PROJECT_NAME}"

# Dev port
DEFAULT_PORT=3000
if [ -f "$PROJECT_DIR/package.json" ]; then
  # Try to detect port from scripts
  detected=$(grep -oP '(?<=-p\s)\d+' "$PROJECT_DIR/package.json" 2>/dev/null | head -1)
  if [ -n "$detected" ]; then
    DEFAULT_PORT="$detected"
  fi
fi
ask "Dev server port [$DEFAULT_PORT]:"
read -r input_port
DEV_PORT="${input_port:-$DEFAULT_PORT}"

# Branches
ask "Dev branch [dev]:"
read -r input_dev_branch
DEV_BRANCH="${input_dev_branch:-dev}"

ask "Prod branch [main]:"
read -r input_prod_branch
PROD_BRANCH="${input_prod_branch:-main}"

# Lint command
DEFAULT_LINT="npx eslint"
if [ -f "$PROJECT_DIR/package.json" ]; then
  if grep -q '"next lint"' "$PROJECT_DIR/package.json" 2>/dev/null; then
    DEFAULT_LINT="npx next lint"
  fi
fi
ask "Lint command [$DEFAULT_LINT]:"
read -r input_lint
LINT="${input_lint:-$DEFAULT_LINT}"

# Typecheck command
ask "Typecheck command [npx tsc --noEmit]:"
read -r input_typecheck
TYPECHECK="${input_typecheck:-npx tsc --noEmit}"

# Hosting
echo ""
echo "  Hosting options:"
echo "    1) vercel    — auto-deploy previews, poll via GitHub"
echo "    2) azure     — custom deployment, poll via health API"
echo "    3) none      — no deployment (local only)"
ask "Hosting [1/2/3]:"
read -r input_hosting
case "$input_hosting" in
  1|vercel)  HOSTING="vercel" ;;
  2|azure)   HOSTING="azure" ;;
  3|none|"") HOSTING="none" ;;
  *)         HOSTING="$input_hosting" ;;
esac

# Deploy config
DEPLOY_JSON="null"
if [ "$HOSTING" = "vercel" ]; then
  # Detect GitHub repo
  DEFAULT_REPO=""
  if [ -d "$PROJECT_DIR/.git" ]; then
    DEFAULT_REPO=$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||')
  fi
  ask "GitHub repo (owner/name) [$DEFAULT_REPO]:"
  read -r input_repo
  GH_REPO="${input_repo:-$DEFAULT_REPO}"
  DEPLOY_JSON=$(cat <<DJSON
{
    "poll_status": "gh api repos/${GH_REPO}/commits/${DEV_BRANCH}/status --jq '.state'"
  }
DJSON
  )
elif [ "$HOSTING" = "azure" ]; then
  ask "Dev environment URL (e.g. https://dev.example.com):"
  read -r dev_url
  ask "Server health poll command [curl -s ${dev_url}/api/health | jq -r '.version']:"
  read -r input_poll_server
  POLL_SERVER="${input_poll_server:-curl -s ${dev_url}/api/health | jq -r '.version'}"
  ask "Frontend version poll command (leave empty to skip):"
  read -r input_poll_frontend
  if [ -n "$input_poll_frontend" ]; then
    DEPLOY_JSON=$(cat <<DJSON
{
    "dev_url": "${dev_url}",
    "poll_server": "${POLL_SERVER}",
    "poll_frontend": "${input_poll_frontend}"
  }
DJSON
    )
  else
    DEPLOY_JSON=$(cat <<DJSON
{
    "dev_url": "${dev_url}",
    "poll_server": "${POLL_SERVER}"
  }
DJSON
    )
  fi
fi

# PR config
echo ""
echo "  PR creation:"
echo "    1) gh_cli         — GitHub CLI (gh pr create)"
echo "    2) mcp_browser    — Open Bitbucket PR page via MCP browser"
echo "    3) none           — Skip PR creation"
ask "PR method [1/2/3]:"
read -r input_pr_method
case "$input_pr_method" in
  1|gh_cli|"") PR_METHOD="gh_cli" ;;
  2|mcp_browser) PR_METHOD="mcp_browser" ;;
  3|none) PR_METHOD="none" ;;
  *) PR_METHOD="$input_pr_method" ;;
esac

PR_JSON="{}"
if [ "$PR_METHOD" = "gh_cli" ]; then
  # Detect GitHub repo
  DEFAULT_REPO=""
  if [ -d "$PROJECT_DIR/.git" ]; then
    DEFAULT_REPO=$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||')
  fi
  ask "GitHub repo (owner/name) [$DEFAULT_REPO]:"
  read -r input_repo
  GH_REPO="${input_repo:-$DEFAULT_REPO}"
  ask "Reviewer GitHub username [aglamazy]:"
  read -r input_reviewer
  REVIEWER="${input_reviewer:-aglamazy}"
  PR_JSON=$(cat <<PJSON
{
    "platform": "github",
    "repo": "${GH_REPO}",
    "create_method": "gh_cli",
    "reviewer": "${REVIEWER}"
  }
PJSON
  )
elif [ "$PR_METHOD" = "mcp_browser" ]; then
  ask "Bitbucket workspace/repo (e.g. myworkspace/myrepo):"
  read -r bb_repo
  PR_URL="https://bitbucket.org/${bb_repo}/pull-requests/new?source=${DEV_BRANCH}&dest=${PROD_BRANCH}"
  PR_JSON=$(cat <<PJSON
{
    "platform": "bitbucket",
    "repo": "${bb_repo}",
    "create_method": "mcp_browser",
    "pr_url": "${PR_URL}"
  }
PJSON
  )
fi

# Notes
echo ""
ask "Project notes (comma-separated, or press Enter to skip):"
read -r input_notes
NOTES_JSON="[]"
if [ -n "$input_notes" ]; then
  NOTES_JSON=$(python3 -c "
import json, sys
notes = [n.strip() for n in sys.argv[1].split(',') if n.strip()]
print(json.dumps(notes))
" "$input_notes")
fi

# ── Write taskbot.json ────────────────────────────────────────────────
mkdir -p "$DOCS_DIR/dev" "$DOCS_DIR/done"

python3 -c "
import json, sys

config = {
    'project': sys.argv[1],
    'dev_port': int(sys.argv[2]),
    'dev_branch': sys.argv[3],
    'prod_branch': sys.argv[4],
    'lint': sys.argv[5],
    'typecheck': sys.argv[6],
    'hosting': sys.argv[7],
    'deploy': json.loads(sys.argv[8]),
    'pr': json.loads(sys.argv[9]),
    'notes': json.loads(sys.argv[10])
}

with open(sys.argv[11], 'w') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
    f.write('\n')
" "$PROJECT_NAME" "$DEV_PORT" "$DEV_BRANCH" "$PROD_BRANCH" "$LINT" "$TYPECHECK" "$HOSTING" "$DEPLOY_JSON" "$PR_JSON" "$NOTES_JSON" "$DOCS_DIR/taskbot.json"

# ── Copy shared files ─────────────────────────────────────────────────
cp "$TASKBOT_DIR/AGENT_INSTRUCTIONS.md" "$DOCS_DIR/AGENT_INSTRUCTIONS.md"
cp "$TASKBOT_DIR/TASK_TEMPLATE.md" "$DOCS_DIR/TASK_TEMPLATE.md"

# ── Summary ───────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ok "  Taskbot configured for $PROJECT_NAME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Created:"
echo "    docs/taskbot.json          — project config"
echo "    docs/AGENT_INSTRUCTIONS.md — agent instructions"
echo "    docs/TASK_TEMPLATE.md      — task doc template"
echo "    docs/dev/                  — completed tasks staging"
echo "    docs/done/                 — released tasks archive"
echo ""
echo "  Next steps:"
echo "    1. Create a task: docs/1-my-task.md (use TASK_TEMPLATE.md)"
echo "    2. Run it:        taskbot.sh $PROJECT_DIR 1"
echo ""
