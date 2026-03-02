#!/bin/bash
#
# taskbot.sh — Taskbot — unattended Claude agent that executes task docs
#
# Picks the next task doc from {project}/docs/, launches Claude Code
# to implement + test it, commits, pushes to dev, and moves the task doc
# to docs/dev/.
#
# Usage:
#   ./taskbot.sh [project-dir] [task-number] [--all] [--dry-run] [--configure] [--new] [--promote <n>]
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

# Kill all descendant processes on Ctrl-C / Ctrl-Z
CHILD_PID=""
kill_descendants() {
  local pid=$1
  local children
  children=$(pgrep -P "$pid" 2>/dev/null) || true
  for child in $children; do
    kill_descendants "$child"
  done
  kill "$pid" 2>/dev/null || true
}
cleanup() {
  trap - SIGINT SIGTERM SIGTSTP
  # Kill tracked child and all its descendants
  if [ -n "$CHILD_PID" ]; then
    kill_descendants "$CHILD_PID"
  fi
  # Also kill any remaining children of this script
  pkill -P $$ 2>/dev/null || true
  wait 2>/dev/null
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
    --promote)   MODE="promote" ;;
    --abort)     MODE="abort" ;;
    -h|--help)
      echo "Usage: $0 [project-dir] [task-number] [--all] [--dry-run] [--configure] [--new] [--promote <n>]"
      echo ""
      echo "  [project-dir]  Path to the project root (default: current directory)"
      echo "  (no number)    Run the next pending task"
      echo "  <number>       Run a specific task by index"
      echo "  --all          Run all pending tasks sequentially"
      echo "  --dry-run      Show pending tasks without executing"
      echo "  --list         Show tasks needing attention (pending + on dev)"
      echo "  --configure    Set up taskbot for this project (interactive)"
      echo "  --new          Create a new task (interactive interview)"
      echo "  --promote <n>  Create PR, wait for merge, test on prod, move to done"
      echo "  --abort <n>    Move task to aborted, clean up worktree"
      exit 0
      ;;
    [0-9]*)
      TARGET_INDEX="$arg"
      # Don't override MODE if --promote/--abort was already set
      [ "$MODE" = "promote" ] || [ "$MODE" = "abort" ] || MODE="specific"
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
STREAM_FILTER="$TASKBOT_HOME/stream-filter.py"
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

# ── Abort mode ──────────────────────────────────────────────────────
if [ "$MODE" = "abort" ]; then
  if [ -z "$TARGET_INDEX" ]; then
    err "Abort requires a task index: $0 --abort <number>"
    exit 1
  fi

  ABORTED_DIR="$DOCS_DIR/aborted"
  mkdir -p "$ABORTED_DIR"

  # Find task in any location: pending, dev, or done
  ABORT_TASK=""
  ABORT_SOURCE=""
  for search_dir in "$DOCS_DIR" "$DEV_DIR" "$DOCS_DIR/done"; do
    found=$(find "$search_dir" -maxdepth 1 -name "${TARGET_INDEX}-*.md" -printf '%f\n' 2>/dev/null | head -1)
    if [ -n "$found" ]; then
      ABORT_TASK="$found"
      ABORT_SOURCE="$search_dir"
      break
    fi
  done

  if [ -z "$ABORT_TASK" ]; then
    err "No task with index $TARGET_INDEX found"
    exit 1
  fi

  # Clean up worktrees (primary + siblings) and branches
  SLUG="${ABORT_TASK%.md}"
  BRANCH="taskbot/${SLUG}"

  # Collect all repo dirs to clean: primary + any from repos config
  REPO_DIRS="$PROJECT_DIR"
  REPOS_JSON=$(python3 -c "
import json
cfg = json.load(open('$DOCS_DIR/taskbot.json'))
repos = cfg.get('repos', {})
print(json.dumps(repos))
" 2>/dev/null || echo "{}")
  if [ "$REPOS_JSON" != "{}" ]; then
    for repo_rel in $(python3 -c "import json; [print(v) for v in json.loads('$REPOS_JSON').values()]"); do
      repo_abs=$(realpath "$PROJECT_DIR/$repo_rel" 2>/dev/null) || continue
      [ -d "$repo_abs/.git" ] && REPO_DIRS="$REPO_DIRS $repo_abs"
    done
  fi

  for repo_dir in $REPO_DIRS; do
    local_wt="$repo_dir/.taskbot-worktrees/${SLUG}"
    if [ -d "$local_wt" ]; then
      cd "$repo_dir"
      git worktree remove --force "$local_wt" 2>/dev/null || true
      ok "Removed worktree: $local_wt"
    fi
    if cd "$repo_dir" 2>/dev/null && git show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null; then
      git branch -D "$BRANCH" 2>/dev/null || true
      ok "Deleted branch $BRANCH in $(basename "$repo_dir")"
    fi
  done

  # Move task to aborted
  mv "$ABORT_SOURCE/$ABORT_TASK" "$ABORTED_DIR/$ABORT_TASK"
  ok "Moved $ABORT_TASK → docs/aborted/"
  exit 0
fi

# ── Promote mode ────────────────────────────────────────────────────
if [ "$MODE" = "promote" ]; then
  if [ -z "$TARGET_INDEX" ]; then
    err "Promote requires a task index: $0 --promote <number>"
    exit 1
  fi

  PROMOTE_INSTRUCTIONS="$DOCS_DIR/PROMOTE_INSTRUCTIONS.md"
  if [ ! -f "$PROMOTE_INSTRUCTIONS" ]; then
    PROMOTE_INSTRUCTIONS="$TASKBOT_HOME/PROMOTE_INSTRUCTIONS.md"
  fi

  # Find the task in docs/dev/
  PROMOTE_TASK=$(find "$DEV_DIR" -maxdepth 1 -name "${TARGET_INDEX}-*.md" -printf '%f\n' | head -1)
  if [ -z "$PROMOTE_TASK" ]; then
    err "No task with index $TARGET_INDEX found in docs/dev/"
    err "Only tasks on dev can be promoted. Current dev tasks:"
    find "$DEV_DIR" -maxdepth 1 -name '[0-9]*-*.md' -printf '  %f\n' 2>/dev/null | sort -n
    exit 1
  fi

  PROMOTE_TASK_PATH="$DEV_DIR/$PROMOTE_TASK"
  DONE_DIR="$DOCS_DIR/done"
  mkdir -p "$DONE_DIR" "$LOG_DIR"

  TIMESTAMP=$(date +%Y%m%d-%H%M%S)
  PROMOTE_LOG="$LOG_DIR/${TARGET_INDEX}-promote-${TIMESTAMP}.log"

  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Promote: $PROMOTE_TASK"
  log "Log:     $PROMOTE_LOG"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  PROMOTE_EXIT=0
  cd "$PROJECT_DIR"

  (
    claude -p \
      --permission-mode bypassPermissions \
      --model opus \
      --verbose \
      --output-format stream-json \
      "Read ${PROMOTE_INSTRUCTIONS} for how to execute, then read ${PROMOTE_TASK_PATH} for the task. Execute it." \
      2>&1 | tee "$PROMOTE_LOG.raw" | \
      python3 -u "$STREAM_FILTER" | tee "$PROMOTE_LOG"
  ) &
  CHILD_PID=$!
  wait "$CHILD_PID" || PROMOTE_EXIT=$?
  CHILD_PID=""

  if [ $PROMOTE_EXIT -ne 0 ]; then
    err "Claude exited with code $PROMOTE_EXIT"
    err "See log: $PROMOTE_LOG"
    exit 1
  fi

  if tail -20 "$PROMOTE_LOG" | grep -qi "SUCCESS"; then
    ok "Task $PROMOTE_TASK promoted successfully"
    mv "$PROMOTE_TASK_PATH" "$DONE_DIR/$PROMOTE_TASK"
    ok "Moved $PROMOTE_TASK → docs/done/"
  else
    warn "Promote may have failed — check log: $PROMOTE_LOG"
    exit 1
  fi

  exit 0
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

# ── Execute a single task ─────────────────────────────────────────────
run_task() {
  local task_file="$1"
  local task_path="$DOCS_DIR/$task_file"
  local index=$(task_index "$task_file")
  local slug="${task_file%.md}"
  local branch="taskbot/${slug}"
  local timestamp=$(date +%Y%m%d-%H%M%S)
  local log_file="$LOG_DIR/${index}-${timestamp}.log"
  local worktree_dir="$PROJECT_DIR/.taskbot-worktrees/${slug}"

  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Task:     $task_file"
  log "Branch:   $branch"
  log "Worktree: $worktree_dir"
  log "Log:      $log_file"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Read config from taskbot.json
  local dev_branch
  dev_branch=$(python3 -c "import json; print(json.load(open('$DOCS_DIR/taskbot.json'))['dev_branch'])")

  # Read additional repos (if multi-repo project)
  local repos_json
  repos_json=$(python3 -c "
import json
cfg = json.load(open('$DOCS_DIR/taskbot.json'))
repos = cfg.get('repos', {})
print(json.dumps(repos))
")

  # Create worktree for primary repo
  local worktree_base="$PROJECT_DIR/.taskbot-worktrees/${slug}"
  cd "$PROJECT_DIR"
  git fetch origin "$dev_branch" 2>/dev/null || true
  if git show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
    log "Reusing existing branch $branch"
  else
    git branch "$branch" "origin/$dev_branch" 2>/dev/null || git branch "$branch" "$dev_branch"
  fi
  if [ -d "$worktree_dir" ]; then
    git worktree remove --force "$worktree_dir" 2>/dev/null || true
  fi
  mkdir -p "$(dirname "$worktree_dir")"
  git worktree add "$worktree_dir" "$branch"

  # Create worktrees for sibling repos (multi-repo projects)
  local sibling_worktrees=""
  local sibling_info=""
  if [ "$repos_json" != "{}" ]; then
    local repo_names
    repo_names=$(python3 -c "import json; [print(k) for k in json.loads('$repos_json')]")
    while IFS= read -r repo_name; do
      [ -z "$repo_name" ] && continue
      local repo_rel
      repo_rel=$(python3 -c "import json; print(json.loads('$repos_json')['$repo_name'])")
      local repo_abs
      repo_abs=$(realpath "$PROJECT_DIR/$repo_rel")

      # Skip the primary repo (already has a worktree)
      [ "$repo_abs" = "$PROJECT_DIR" ] && continue
      [ ! -d "$repo_abs/.git" ] && continue

      local sibling_wt="$repo_abs/.taskbot-worktrees/${slug}"
      local sibling_branch="$branch"

      cd "$repo_abs"
      git fetch origin "$dev_branch" 2>/dev/null || true
      if git show-ref --verify --quiet "refs/heads/$sibling_branch" 2>/dev/null; then
        log "Reusing existing branch $sibling_branch in $repo_name"
      else
        git branch "$sibling_branch" "origin/$dev_branch" 2>/dev/null || git branch "$sibling_branch" "$dev_branch"
      fi
      if [ -d "$sibling_wt" ]; then
        git worktree remove --force "$sibling_wt" 2>/dev/null || true
      fi
      mkdir -p "$(dirname "$sibling_wt")"
      git worktree add "$sibling_wt" "$sibling_branch"

      sibling_worktrees="$sibling_worktrees $repo_abs:$sibling_wt"
      sibling_info="${sibling_info}\n- ${repo_name}: $sibling_wt (branch: $sibling_branch)"
      log "Worktree: $sibling_wt ($repo_name)"
    done <<< "$repo_names"
  fi

  local exit_code=0

  # Build repo context for the agent
  local repo_context="You are working in a git worktree at $worktree_dir on branch $branch (feature branch off $dev_branch)."
  if [ -n "$sibling_info" ]; then
    repo_context="${repo_context}
Additional repo worktrees have been created for you:${sibling_info}
All repos use the same branch name ($branch). Commit and push each repo separately."
  fi

  # Run pipeline in background, track PID for cleanup
  (
    cd "$worktree_dir"
    claude -p \
      --permission-mode bypassPermissions \
      --model opus \
      --verbose \
      --output-format stream-json \
      "${repo_context}
Read ${INSTRUCTIONS} for how to execute, then read ${task_path} for the task. Execute it." \
      2>&1 | tee "$log_file.raw" | \
      python3 -u "$STREAM_FILTER" | tee "$log_file"
  ) &
  CHILD_PID=$!
  wait "$CHILD_PID" || exit_code=$?
  CHILD_PID=""

  # Check result
  if [ $exit_code -ne 0 ]; then
    err "Claude exited with code $exit_code"
    err "See log: $log_file"
    # Keep worktrees for debugging
    return 1
  fi

  # Check if the agent reported success (look for SUCCESS in last 20 lines)
  if tail -20 "$log_file" | grep -qi "SUCCESS"; then
    ok "Task $task_file completed successfully"

    # Clean up all worktrees
    cd "$PROJECT_DIR"
    git worktree remove --force "$worktree_dir" 2>/dev/null || true
    git branch -d "$branch" 2>/dev/null || true
    for pair in $sibling_worktrees; do
      local sib_repo="${pair%%:*}"
      local sib_wt="${pair##*:}"
      cd "$sib_repo"
      git worktree remove --force "$sib_wt" 2>/dev/null || true
      git branch -d "$branch" 2>/dev/null || true
    done

    # Move task doc to docs/dev/
    mv "$task_path" "$DEV_DIR/$task_file"
    ok "Moved $task_file → docs/dev/"

    return 0
  else
    warn "Task $task_file may have failed — check log: $log_file"
    warn "Worktree preserved at: $worktree_dir"
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

    # Aborted
    local aborted_tasks
    aborted_tasks=$(find "$DOCS_DIR/aborted" -maxdepth 1 -name '[0-9]*-*.md' -printf '%f\n' 2>/dev/null | sort -n)
    if [ -n "$aborted_tasks" ]; then
      echo ""
      err "Aborted:"
      echo "$aborted_tasks" | while read -r t; do
        echo "  $(task_index "$t"). $t"
      done
    fi

    if [ -z "$dev_tasks" ] && [ -z "$tasks" ] && [ -z "$done_tasks" ] && [ -z "$aborted_tasks" ]; then
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
