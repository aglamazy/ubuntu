#!/bin/bash
#
# taskbot new-task — interactive task creation via Claude
#
# Interviews the user about what needs to be done, explores the codebase,
# and writes a task doc following the project's TASK_TEMPLATE.md.
#
# Usage: ./new-task.sh <project-dir>
#

set -euo pipefail

TASKBOT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

err() { echo -e "${RED}[taskbot]${NC} $*" >&2; }
ok()  { echo -e "${GREEN}[taskbot]${NC} $*"; }
log() { echo -e "${BLUE}[taskbot]${NC} $*"; }

# ── Validate ──────────────────────────────────────────────────────────
if [ -z "${1:-}" ]; then
  echo "Usage: $0 <project-dir>"
  exit 1
fi

PROJECT_DIR="$(realpath "$1")"
DOCS_DIR="$PROJECT_DIR/docs"

if [ ! -f "$DOCS_DIR/taskbot.json" ]; then
  err "Project not configured. Run: taskbot.sh $PROJECT_DIR --configure"
  exit 1
fi

# ── Determine next task index ─────────────────────────────────────────
LAST_INDEX=$(find "$DOCS_DIR" "$DOCS_DIR/dev" "$DOCS_DIR/done" -maxdepth 1 -name '[0-9]*-*.md' -printf '%f\n' 2>/dev/null | grep -oP '^\d+' | sort -n | tail -1 || true)
NEXT_INDEX=$(( ${LAST_INDEX:-0} + 1 ))

log "Project: $(basename "$PROJECT_DIR")"
log "Next task index: $NEXT_INDEX"
echo ""

# ── Launch Claude for interview ───────────────────────────────────────
claude \
  --permission-mode acceptEdits \
  --model opus \
  "You are a TASK WRITER, not a task executor. Do NOT implement or write any code.
Your ONLY job is to interview the user and write a task document.

Read these files first:
- $DOCS_DIR/taskbot.json (project config)
- $DOCS_DIR/TASK_TEMPLATE.md (template to follow)

Then interview the user about what needs to be done. Ask short, focused questions:
1. What's the problem or feature needed?
2. Clarify scope — what's in, what's out.
3. Explore the codebase to find relevant files and understand current architecture.
4. Suggest an approach and which files to modify.
5. Does this task involve UI changes? If yes, ask what page/action/expected result for MCP browser verification. If no UI is involved, skip MCP browser steps entirely — use only code-level checks (lint, typecheck, DB queries, API calls, script output, etc.).
6. Should the agent run a local dev server and test against it, or are code-level checks sufficient?
7. What branch should the agent start from? (default: dev_branch from taskbot.json)
   What branch should changes merge into? (default: dev_branch from taskbot.json)
7b. Which workflow preset fits this task?
   - instant: trivial change — code then merge directly (no PR)
   - standard: normal feature — code then PR (DEFAULT)
   - thorough: UI/data/complex — code, then agent review pass, then local human test, then PR
   If unsure, default to standard.
8. Ask how to VERIFY the outcome — not just 'does it deploy' but 'how do we prove it worked':
   - For data changes: what DB query proves the data is correct?
   - For bug fixes: what scenario triggered the bug, and what should happen now?
   - For UI features: what page, what action, what should appear?
   Push the user to define concrete pass/fail criteria.

Don't ask all questions at once — go through them conversationally, a few at a time.
Use sensible defaults and confirm them rather than asking open-ended questions for everything.

After the interview, write the task doc to:
  $DOCS_DIR/${NEXT_INDEX}-SLUG.md

Replace SLUG with a short kebab-case name based on the task (e.g. ${NEXT_INDEX}-add-teacher-receipts.md).

Follow the TASK_TEMPLATE.md format exactly. Always write a ## Workflow section BEFORE ## Problem:
  ## Workflow
  preset: <chosen preset>
  operations: <comma-separated list matching preset: instant→code,merge / standard→code,pr / thorough→code,review,run,pr>
  branch_from: <default: dev_branch from taskbot.json>
  merge_into: <default: dev_branch from taskbot.json>

Include all sections: Workflow, Problem, Fix, Files, Verify.

IMPORTANT: Do NOT implement the task. Do NOT write application code. Only write the task document.

Start by reading the project config and template, then greet the user and ask what they need."
