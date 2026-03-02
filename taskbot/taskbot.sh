#!/bin/bash
#
# taskbot.sh — Taskbot — unattended Claude agent that executes task docs
#
# Picks the next task doc from {project}/docs/, launches Claude Code
# to implement + test it, commits, pushes to dev, and moves the task doc
# to docs/dev/.
#
# Usage:
#   ./taskbot.sh [project-dir] [task-number] [--all] [--dry-run] [--configure] [--new]
#
# If project-dir is omitted, uses the current directory.
#
# Examples:
#   ./taskbot.sh --new                                       # new task in current dir
#   ./taskbot.sh --dry-run                                   # list tasks in current dir
#   ./taskbot.sh 1                                           # run task 1 in current dir
#   ./taskbot.sh ~/develop/Importa/importa-server 1          # run task 1 in specific dir
#   ./taskbot.sh ~/develop/Ilya/Ilya.mortgage --all           # all tasks
#

set -euo pipefail

# Kill all child processes on Ctrl-C / Ctrl-Z
cleanup() {
  # Kill entire process group
  trap - SIGINT SIGTERM SIGTSTP
  pkill -P $$ 2>/dev/null
  kill -- -$$ 2>/dev/null
  exit 130
}
trap cleanup SIGINT SIGTERM SIGTSTP

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[taskbot]${NC} $*"; }
ok()   { echo -e "${GREEN}[taskbot]${NC} $*"; }
warn() { echo -e "${YELLOW}[taskbot]${NC} $*"; }
err()  { echo -e "${RED}[taskbot]${NC} $*" >&2; }

# ── Parse arguments ────────────────────────────────────────────────────
PROJECT_DIR=""
MODE="next"
TARGET_INDEX=""

for arg in "$@"; do
  case "$arg" in
    --all)       MODE="all" ;;
    --dry-run)   MODE="dry" ;;
    --list)      MODE="list" ;;
    --configure) MODE="configure" ;;
    --new)       MODE="new" ;;
    -h|--help)
      echo "Usage: $0 [project-dir] [task-number] [--all] [--dry-run] [--configure] [--new]"
      echo ""
      echo "  [project-dir]  Path to the project root (default: current directory)"
      echo "  (no number)    Run the next pending task"
      echo "  <number>       Run a specific task by index"
      echo "  --all          Run all pending tasks sequentially"
      echo "  --dry-run      Show pending tasks without executing"
      echo "  --list         Show tasks needing attention (pending + on dev)"
      echo "  --configure    Set up taskbot for this project (interactive)"
      echo "  --new          Create a new task (interactive interview)"
      exit 0
      ;;
    [0-9]*)
      TARGET_INDEX="$arg"
      MODE="specific"
      ;;
    *)
      if [ -z "$PROJECT_DIR" ]; then
        PROJECT_DIR="$arg"
      else
        err "Unknown argument: $arg"
        exit 1
      fi
      ;;
  esac
done

# Default to current directory if no project dir specified
if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR="$(pwd)"
fi

# Resolve to absolute path
PROJECT_DIR="$(realpath "$PROJECT_DIR")"
PROJECT_NAME="$(basename "$PROJECT_DIR")"
TASKBOT_HOME="$(cd "$(dirname "$0")" && pwd)"
DOCS_DIR="$PROJECT_DIR/docs"
DEV_DIR="$DOCS_DIR/dev"
LOG_DIR="$PROJECT_DIR/task-logs"
INSTRUCTIONS="$DOCS_DIR/AGENT_INSTRUCTIONS.md"

# ── Auto-detect sub-project if not a configured project ─────────────
if [ ! -f "$DOCS_DIR/taskbot.json" ]; then
  # Scan for configured sub-projects
  subs=()
  for sub in "$PROJECT_DIR"/*/docs/taskbot.json; do
    [ -f "$sub" ] || continue
    subs+=("$(dirname "$(dirname "$sub")")")
  done

  if [ ${#subs[@]} -eq 1 ]; then
    PROJECT_DIR="${subs[0]}"
    PROJECT_NAME="$(basename "$PROJECT_DIR")"
    DOCS_DIR="$PROJECT_DIR/docs"
    DEV_DIR="$DOCS_DIR/dev"
    LOG_DIR="$PROJECT_DIR/task-logs"
    INSTRUCTIONS="$DOCS_DIR/AGENT_INSTRUCTIONS.md"
    log "Auto-detected project: $PROJECT_NAME"
  elif [ ${#subs[@]} -gt 1 ]; then
    # For list/dry-run, scan all sub-projects
    if [ "$MODE" = "list" ] || [ "$MODE" = "dry" ]; then
      for s in "${subs[@]}"; do
        echo ""
        echo "━━━ $(basename "$s") ━━━"
        _flag="--$MODE"
        [ "$MODE" = "dry" ] && _flag="--dry-run"
        "$0" "$s" "$_flag" 2>&1
      done
      exit 0
    fi
    err "Multiple projects found. Specify which one:"
    for s in "${subs[@]}"; do
      echo "  $0 $s $*"
    done
    exit 1
  else
    err "No configured project found in $PROJECT_DIR"
    err "Run: $0 $PROJECT_DIR --configure"
    exit 1
  fi
fi

# ── Configure mode ───────────────────────────────────────────────────
if [ "$MODE" = "configure" ]; then
  exec "$TASKBOT_HOME/configure.sh" "$PROJECT_DIR"
fi

# ── New task mode ────────────────────────────────────────────────────
if [ "$MODE" = "new" ]; then
  exec "$TASKBOT_HOME/new-task.sh" "$PROJECT_DIR"
fi

# ── Validate project ────────────────────────────────────────────────
if [ ! -f "$INSTRUCTIONS" ]; then
  err "No AGENT_INSTRUCTIONS.md found in $DOCS_DIR"
  err "Run: $0 $PROJECT_DIR --configure"
  exit 1
fi

# ── Ensure directories exist ──────────────────────────────────────────
mkdir -p "$DEV_DIR" "$LOG_DIR"

# ── Find pending task docs ────────────────────────────────────────────
find_tasks() {
  find "$DOCS_DIR" -maxdepth 1 -name '[0-9]*-*.md' -printf '%f\n' | sort -n
}

find_task_by_index() {
  local index="$1"
  find "$DOCS_DIR" -maxdepth 1 -name "${index}-*.md" -printf '%f\n' | head -1
}

task_index() {
  echo "$1" | grep -oP '^\d+'
}

# ── Pre-flight checks ────────────────────────────────────────────────
preflight() {
  if ! command -v claude &>/dev/null; then
    err "claude CLI not found in PATH"
    exit 1
  fi

  log "Project: $PROJECT_NAME ($PROJECT_DIR)"
}

# ── Stream filter ─────────────────────────────────────────────────────
STREAM_FILTER="$TASKBOT_HOME/stream-filter.py"

# ── Execute a single task ─────────────────────────────────────────────
run_task() {
  local task_file="$1"
  local task_path="$DOCS_DIR/$task_file"
  local index=$(task_index "$task_file")
  local timestamp=$(date +%Y%m%d-%H%M%S)
  local log_file="$LOG_DIR/${index}-${timestamp}.log"

  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Task: $task_file"
  log "Log:  $log_file"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  local exit_code=0
  cd "$PROJECT_DIR"

  # Run in a subshell with its own process group so cleanup can kill everything
  set -m
  (
    claude -p \
      --permission-mode bypassPermissions \
      --model opus \
      --verbose \
      --output-format stream-json \
      "Read ${INSTRUCTIONS} for how to execute, then read ${task_path} for the task. Execute it." \
      2>&1 | tee "$log_file.raw" | \
      python3 -u "$STREAM_FILTER" | tee "$log_file"
  ) || exit_code=$?
  set +m

  # Check result
  if [ $exit_code -ne 0 ]; then
    err "Claude exited with code $exit_code"
    err "See log: $log_file"
    return 1
  fi

  # Check if the agent reported success (look for SUCCESS in last 20 lines)
  if tail -20 "$log_file" | grep -qi "SUCCESS"; then
    ok "Task $task_file completed successfully"

    # Move task doc to docs/dev/
    mv "$task_path" "$DEV_DIR/$task_file"
    ok "Moved $task_file → docs/dev/"

    return 0
  else
    warn "Task $task_file may have failed — check log: $log_file"
    return 1
  fi
}

# ── Main ──────────────────────────────────────────────────────────────
main() {
  # List pending tasks
  local tasks
  tasks=$(find_tasks)

  if [ -z "$tasks" ] && [ "$MODE" != "list" ]; then
    ok "No pending tasks in $DOCS_DIR"
    exit 0
  fi

  if [ -n "$tasks" ] && [ "$MODE" != "list" ]; then
    log "Pending tasks:"
    echo "$tasks" | while read -r t; do
      echo "  $(task_index "$t"). $t"
    done
    echo ""
  fi

  # Dry run — just list pending and exit
  if [ "$MODE" = "dry" ]; then
    exit 0
  fi

  # List — show tasks needing attention across all stages
  if [ "$MODE" = "list" ]; then
    # On dev (need testing/review)
    local dev_tasks
    dev_tasks=$(find "$DEV_DIR" -maxdepth 1 -name '[0-9]*-*.md' -printf '%f\n' 2>/dev/null | sort -n)
    if [ -n "$dev_tasks" ]; then
      echo ""
      warn "On dev (need review/merge):"
      echo "$dev_tasks" | while read -r t; do
        echo "  $(task_index "$t"). $t"
      done
    fi

    # Pending (ready to run)
    if [ -n "$tasks" ]; then
      echo ""
      log "Pending (ready to run):"
      echo "$tasks" | while read -r t; do
        echo "  $(task_index "$t"). $t"
      done
    fi

    # Done
    local done_tasks
    done_tasks=$(find "$DOCS_DIR/done" -maxdepth 1 -name '[0-9]*-*.md' -printf '%f\n' 2>/dev/null | sort -n)
    if [ -n "$done_tasks" ]; then
      echo ""
      ok "Done:"
      echo "$done_tasks" | while read -r t; do
        echo "  $(task_index "$t"). $t"
      done
    fi

    if [ -z "$dev_tasks" ] && [ -z "$tasks" ] && [ -z "$done_tasks" ]; then
      echo "  No tasks found."
    fi

    echo ""
    exit 0
  fi

  # Pre-flight checks
  preflight

  case "$MODE" in
    specific)
      local task_file
      task_file=$(find_task_by_index "$TARGET_INDEX")
      if [ -z "$task_file" ]; then
        err "No task found with index $TARGET_INDEX"
        exit 1
      fi
      run_task "$task_file"
      ;;

    next)
      local first_task
      first_task=$(echo "$tasks" | head -1)
      run_task "$first_task"
      ;;

    all)
      local failed=0
      while IFS= read -r task_file; do
        if ! run_task "$task_file"; then
          err "Task $task_file failed — stopping"
          failed=1
          break
        fi
        echo ""
      done <<< "$tasks"

      if [ $failed -eq 0 ]; then
        ok "All tasks completed"
      else
        err "Stopped due to failure"
        exit 1
      fi
      ;;
  esac
}

main
