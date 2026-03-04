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
    --idea)      MODE="idea" ;;
    --promote)   MODE="promote" ;;
    --abort)     MODE="abort" ;;
    --run)       MODE="run" ;;
    --close)     MODE="close" ;;
    --review)    MODE="review" ;;
    --next)      MODE="auto_next" ;;
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
  echo "  --idea         Capture a one-line task placeholder instantly"
      echo "  --promote <n>  Create PR, wait for merge, test on prod, move to done"
      echo "  --close <n>    Create dev→prod PR, wait for merge, move task to done"
      echo "  --abort <n>    Move task to aborted, clean up worktree"
      echo "  --run <n>      Run the worktree locally (links .env + node_modules, kills previous)"
      echo "  --review <n>   Run agent code review pass on task worktree"
      echo "  --next <n>     Advance to the next pending workflow operation"
      exit 0
      ;;
    [0-9]*)
      TARGET_INDEX="$arg"
      # Don't override MODE if --promote/--close/--abort/--run/--review/--next was already set
      [ "$MODE" = "promote" ] || [ "$MODE" = "close" ] || [ "$MODE" = "abort" ] || \
      [ "$MODE" = "run" ] || [ "$MODE" = "review" ] || [ "$MODE" = "auto_next" ] || \
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
STREAM_FILTER="$TASKBOT_HOME/stream-filter.py"
DOCS_DIR="$PROJECT_DIR/docs"
DEV_DIR="$DOCS_DIR/dev"
LOG_DIR="$PROJECT_DIR/task-logs"
INSTRUCTIONS="$DOCS_DIR/AGENT_INSTRUCTIONS.md"
STATE_DIR="$PROJECT_DIR/.taskbot-state"

# ── Bare --run: start the project dev server (Next.js), no task needed ──
if [ "$MODE" = "run" ] && [ -z "$TARGET_INDEX" ]; then
  exec "$TASKBOT_HOME/run-dev.sh" "$PROJECT_DIR"
fi

# ── Versioned migration ───────────────────────────────────────────────
TASKBOT_VERSION="$(cat "$TASKBOT_HOME/VERSION" 2>/dev/null | tr -d '[:space:]')"
TASKBOT_VERSION="${TASKBOT_VERSION:-1}"

migrate_project() {
  local docs_dir="$1"
  local project_dir="$2"

  _migrate_assets() {
    local docs_dir="$1" project_dir="$2"
    # Copy AGENT_INSTRUCTIONS.md if missing
    if [ ! -f "$docs_dir/AGENT_INSTRUCTIONS.md" ] && [ -f "$TASKBOT_HOME/AGENT_INSTRUCTIONS.md" ]; then
      cp "$TASKBOT_HOME/AGENT_INSTRUCTIONS.md" "$docs_dir/AGENT_INSTRUCTIONS.md"
      log "Copied AGENT_INSTRUCTIONS.md to $docs_dir/"
    fi
    # Add .taskbot-state to .gitignore if missing
    local gitignore="$project_dir/.gitignore"
    if ! grep -qsF '.taskbot-state' "$gitignore"; then
      echo '.taskbot-state' >> "$gitignore"
      log "Added .taskbot-state to $project_dir/.gitignore"
    fi
  }

  # Case 1: No taskbot.json but docs/ has task files → bootstrap
  if [ ! -f "$docs_dir/taskbot.json" ] && [ -d "$docs_dir" ] && \
     [ -n "$(find "$docs_dir" -maxdepth 2 -name '[0-9]*-*.md' 2>/dev/null | head -1)" ]; then
    local _dev _prod _name
    _dev=$(git -C "$project_dir" symbolic-ref --short HEAD 2>/dev/null || echo "dev")
    _prod="main"
    _name="$(basename "$project_dir")"
    for _b in main master prod; do
      if git -C "$project_dir" show-ref --verify --quiet "refs/heads/$_b" 2>/dev/null || \
         git -C "$project_dir" show-ref --verify --quiet "refs/remotes/origin/$_b" 2>/dev/null; then
        _prod="$_b"; break
      fi
    done
    python3 -c "
import json
data = {
  'project': '$_name',
  'dev_branch': '$_dev',
  'prod_branch': '$_prod',
  'taskbot_version': $TASKBOT_VERSION
}
json.dump(data, open('$docs_dir/taskbot.json', 'w'), indent=2)
print('[taskbot] Bootstrapped $docs_dir/taskbot.json (dev=$_dev, prod=$_prod)')
"
    _migrate_assets "$docs_dir" "$project_dir"
    return
  fi

  # Case 2: taskbot.json exists but taskbot_version is missing or outdated
  if [ -f "$docs_dir/taskbot.json" ]; then
    local file_version
    file_version=$(python3 -c "
import json, sys
try:
  d = json.load(open('$docs_dir/taskbot.json'))
  print(d.get('taskbot_version', 0))
except Exception:
  print(0)
")
    if [ "$file_version" -lt "$TASKBOT_VERSION" ] 2>/dev/null; then
      python3 -c "
import json
path = '$docs_dir/taskbot.json'
d = json.load(open(path))
d['taskbot_version'] = $TASKBOT_VERSION
json.dump(d, open(path, 'w'), indent=2)
print('[taskbot] Migrated $docs_dir/taskbot.json to version $TASKBOT_VERSION')
"
      _migrate_assets "$docs_dir" "$project_dir"
    fi
  fi
}

migrate_project "$DOCS_DIR" "$PROJECT_DIR"

# ── Auto-detect sub-project if not a configured project ─────────────
if [ ! -f "$DOCS_DIR/taskbot.json" ]; then
  # Scan for configured sub-projects
  subs=()
  if [ "$MODE" = "list" ] || [ "$MODE" = "dry" ]; then
    # Recurse deeply for list/dry — find all projects under this directory
    # Collect all candidate project dirs (excluding CI agent workspaces)
    _all_subs=()
    while IFS= read -r sub; do
      _all_subs+=("$(realpath "$(dirname "$(dirname "$sub")")")")
    done < <(find "$PROJECT_DIR" \
      -name 'taskbot.json' -path '*/docs/taskbot.json' \
      -not -path '*/.git/*' \
      -not -path '*/node_modules/*' \
      -not -path '*/.taskbot-worktrees/*' \
      -not -path '*/_work/*' \
      | sort)
    # Keep only top-level projects (drop nested), then deduplicate by project name
    declare -A _seen_names
    for _p in "${_all_subs[@]}"; do
      _nested=0
      for _q in "${_all_subs[@]}"; do
        [ "$_p" = "$_q" ] && continue
        [[ "$_p" == "$_q/"* ]] && { _nested=1; break; }
      done
      if [ $_nested -eq 0 ]; then
        _name="$(basename "$_p")"
        if [ -z "${_seen_names[$_name]+x}" ]; then
          _seen_names[$_name]=1
          subs+=("$_p")
        fi
      fi
    done
    unset _all_subs _nested _p _q _name _seen_names
  else
    for sub in "$PROJECT_DIR"/*/docs/taskbot.json; do
      [ -f "$sub" ] || continue
      subs+=("$(dirname "$(dirname "$sub")")")
    done
  fi

  if [ ${#subs[@]} -ge 1 ] && ([ "$MODE" = "list" ] || [ "$MODE" = "dry" ]); then
    # For list/dry-run from a parent dir, always iterate all found projects
    _scan_root="$(realpath "$PROJECT_DIR")"
    for s in "${subs[@]}"; do
      echo ""
      _label="${s#"$_scan_root/"}"
      echo "━━━ $_label ━━━"
      _flag="--$MODE"
      [ "$MODE" = "dry" ] && _flag="--dry-run"
      "$0" "$s" "$_flag" 2>&1 || true
    done
    exit 0
  elif [ ${#subs[@]} -eq 1 ]; then
    PROJECT_DIR="${subs[0]}"
    PROJECT_NAME="$(basename "$PROJECT_DIR")"
    DOCS_DIR="$PROJECT_DIR/docs"
    DEV_DIR="$DOCS_DIR/dev"
    LOG_DIR="$PROJECT_DIR/task-logs"
    INSTRUCTIONS="$DOCS_DIR/AGENT_INSTRUCTIONS.md"
    STATE_DIR="$PROJECT_DIR/.taskbot-state"
    log "Auto-detected project: $PROJECT_NAME"
  elif [ ${#subs[@]} -gt 1 ]; then
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

# ── Idea mode — one-line placeholder task ────────────────────────────
if [ "$MODE" = "idea" ]; then
  LAST_INDEX=$(find "$DOCS_DIR" "$DOCS_DIR/dev" "$DOCS_DIR/done" -maxdepth 1 \
    -name '[0-9]*-*.md' -printf '%f\n' 2>/dev/null \
    | grep -oP '^\d+' | sort -n | tail -1 || true)
  NEXT_INDEX=$(( ${LAST_INDEX:-0} + 1 ))

  printf "Idea: "
  read -r IDEA_TITLE

  if [ -z "$IDEA_TITLE" ]; then
    err "No title given."
    exit 1
  fi

  # Slugify: lowercase, spaces→hyphens, strip non-alphanumeric except hyphens
  IDEA_SLUG=$(echo "$IDEA_TITLE" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')
  IDEA_FILE="$DOCS_DIR/${NEXT_INDEX}-${IDEA_SLUG}.md"

  printf '# %s\n' "$IDEA_TITLE" > "$IDEA_FILE"
  ok "Created: docs/${NEXT_INDEX}-${IDEA_SLUG}.md"
  exit 0
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
  rm -f "$STATE_DIR/$SLUG.json"
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
  PROMOTE_SLUG="${PROMOTE_TASK%.md}"
  DONE_DIR="$DOCS_DIR/done"
  mkdir -p "$DONE_DIR" "$LOG_DIR"

  # Build state context for agent
  if [ -f "$STATE_DIR/$PROMOTE_SLUG.json" ]; then
    PROMOTE_STATE_CTX="State file: $(cat "$STATE_DIR/$PROMOTE_SLUG.json")
If pr_url is non-null in the state, skip Step 2.5 (PR already created). Branch is in state.branch."
  else
    PROMOTE_STATE_CTX="No state file. Assume feature→dev PR already created. Skip Step 2.5."
  fi

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
      "${PROMOTE_STATE_CTX}
Read ${PROMOTE_INSTRUCTIONS} for how to execute, then read ${PROMOTE_TASK_PATH} for the task. Execute it." \
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

    # Clean up worktrees + branches + state file
    PROMOTE_BRANCH=$(load_state_field "$PROMOTE_SLUG" "branch")
    [ -z "$PROMOTE_BRANCH" ] && PROMOTE_BRANCH="taskbot/$PROMOTE_SLUG"
    PROMOTE_WORKTREE="$PROJECT_DIR/.taskbot-worktrees/${PROMOTE_SLUG}"
    cd "$PROJECT_DIR"
    if [ -d "$PROMOTE_WORKTREE" ]; then
      git worktree remove --force "$PROMOTE_WORKTREE" 2>/dev/null || true
      ok "Removed worktree: $PROMOTE_WORKTREE"
    fi
    git branch -d "$PROMOTE_BRANCH" 2>/dev/null || true

    # Clean up sibling worktrees
    PROMOTE_REPOS_JSON=$(python3 -c "import json; print(__import__('json').dumps(json.load(open('$DOCS_DIR/taskbot.json')).get('repos', {})))" 2>/dev/null || echo "{}")
    if [ "$PROMOTE_REPOS_JSON" != "{}" ]; then
      for repo_rel in $(python3 -c "import json; [print(v) for v in json.loads('$PROMOTE_REPOS_JSON').values()]"); do
        repo_abs=$(realpath "$PROJECT_DIR/$repo_rel" 2>/dev/null) || continue
        [ -d "$repo_abs/.git" ] || continue
        [ "$repo_abs" = "$PROJECT_DIR" ] && continue
        sibling_wt="$repo_abs/.taskbot-worktrees/${PROMOTE_SLUG}"
        if [ -d "$sibling_wt" ]; then
          cd "$repo_abs"
          git worktree remove --force "$sibling_wt" 2>/dev/null || true
          ok "Removed sibling worktree: $sibling_wt"
        fi
        cd "$repo_abs" && git branch -d "$PROMOTE_BRANCH" 2>/dev/null || true
      done
    fi

    rm -f "$STATE_DIR/$PROMOTE_SLUG.json"
  else
    warn "Promote may have failed — check log: $PROMOTE_LOG"
    exit 1
  fi

  exit 0
fi

# ── Close mode ──────────────────────────────────────────────────────
# Lightweight dev→prod PR + wait for merge + move to done.
# Used after a feature branch is already merged into dev by anyone.
if [ "$MODE" = "close" ]; then
  if [ -z "$TARGET_INDEX" ]; then
    err "Close requires a task index: $0 --close <number>"
    exit 1
  fi

  # Find the task in docs/dev/
  CLOSE_TASK=$(find "$DEV_DIR" -maxdepth 1 -name "${TARGET_INDEX}-*.md" -printf '%f\n' | head -1)
  if [ -z "$CLOSE_TASK" ]; then
    err "No task with index $TARGET_INDEX found in docs/dev/"
    err "Only tasks on dev can be closed. Current dev tasks:"
    find "$DEV_DIR" -maxdepth 1 -name '[0-9]*-*.md' -printf '  %f\n' 2>/dev/null | sort -n
    exit 1
  fi

  CLOSE_TASK_PATH="$DEV_DIR/$CLOSE_TASK"
  CLOSE_SLUG="${CLOSE_TASK%.md}"
  DONE_DIR="$DOCS_DIR/done"
  mkdir -p "$DONE_DIR"

  # Read config
  CLOSE_DEV_BRANCH=$(python3 -c "import json; print(json.load(open('$DOCS_DIR/taskbot.json'))['dev_branch'])" 2>/dev/null || echo "dev")
  CLOSE_PROD_BRANCH=$(python3 -c "import json; print(json.load(open('$DOCS_DIR/taskbot.json'))['prod_branch'])" 2>/dev/null || echo "main")
  CLOSE_PR_METHOD=$(python3 -c "import json; print(json.load(open('$DOCS_DIR/taskbot.json')).get('pr', {}).get('create_method', 'gh_cli'))" 2>/dev/null || echo "gh_cli")
  CLOSE_PR_REPO=$(python3 -c "import json; print(json.load(open('$DOCS_DIR/taskbot.json')).get('pr', {}).get('repo', ''))" 2>/dev/null || echo "")
  CLOSE_PR_REVIEWER=$(python3 -c "import json; print(json.load(open('$DOCS_DIR/taskbot.json')).get('pr', {}).get('reviewer', ''))" 2>/dev/null || echo "")

  if [ "$CLOSE_PR_METHOD" != "gh_cli" ]; then
    warn "PR method is '$CLOSE_PR_METHOD' — create the dev→prod PR manually:"
    warn "  $CLOSE_DEV_BRANCH → $CLOSE_PROD_BRANCH"
    warn "When merged, move the task to done:"
    warn "  mv '$CLOSE_TASK_PATH' '$DONE_DIR/$CLOSE_TASK'"
    warn "  rm -f '$STATE_DIR/$CLOSE_SLUG.json'"
    exit 0
  fi

  # Build PR title from task doc ## Problem first line
  CLOSE_PR_TITLE=$(python3 - "$CLOSE_TASK_PATH" <<'PYEOF'
import sys, re, os
task = open(sys.argv[1]).read()
m = re.search(r'^## Problem\n(.+?)(?:\n|$)', task, re.MULTILINE)
if m:
    print(m.group(1).strip()[:72])
else:
    fname = os.path.basename(sys.argv[1]).replace('.md', '').replace('-', ' ')
    print(fname[:72])
PYEOF
)

  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Close: $CLOSE_TASK"
  log "PR:    $CLOSE_DEV_BRANCH → $CLOSE_PROD_BRANCH"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  cd "$PROJECT_DIR"
  CLOSE_PR_ARGS=(--base "$CLOSE_PROD_BRANCH" --head "$CLOSE_DEV_BRANCH" --title "$CLOSE_PR_TITLE")
  [ -n "$CLOSE_PR_REPO" ] && CLOSE_PR_ARGS=(--repo "$CLOSE_PR_REPO" "${CLOSE_PR_ARGS[@]}")
  [ -n "$CLOSE_PR_REVIEWER" ] && CLOSE_PR_ARGS=("${CLOSE_PR_ARGS[@]}" --reviewer "$CLOSE_PR_REVIEWER")

  CLOSE_PR_URL=$(gh pr create "${CLOSE_PR_ARGS[@]}" 2>&1 | grep -E 'https?://' | tail -1 || true)
  if [ -z "$CLOSE_PR_URL" ]; then
    err "PR creation may have failed — check output above"
    err "If a PR already exists, wait for merge and then run:"
    err "  mv '$CLOSE_TASK_PATH' '$DONE_DIR/$CLOSE_TASK'"
    err "  rm -f '$STATE_DIR/$CLOSE_SLUG.json'"
    exit 1
  fi

  ok "PR created: $CLOSE_PR_URL"
  log "Polling for merge (every 60s, up to 30m)..."

  CLOSE_DEADLINE=$(( $(date +%s) + 1800 ))
  while true; do
    if [ "$(date +%s)" -ge "$CLOSE_DEADLINE" ]; then
      warn "Timed out waiting for PR to merge after 30m"
      warn "When merged, move the task to done:"
      warn "  mv '$CLOSE_TASK_PATH' '$DONE_DIR/$CLOSE_TASK'"
      warn "  rm -f '$STATE_DIR/$CLOSE_SLUG.json'"
      exit 1
    fi

    CLOSE_PR_STATE=$(gh pr view "$CLOSE_PR_URL" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")
    if [ "$CLOSE_PR_STATE" = "MERGED" ]; then
      ok "PR merged!"
      mv "$CLOSE_TASK_PATH" "$DONE_DIR/$CLOSE_TASK"
      ok "Moved $CLOSE_TASK → docs/done/"
      rm -f "$STATE_DIR/$CLOSE_SLUG.json"
      exit 0
    elif [ "$CLOSE_PR_STATE" = "CLOSED" ]; then
      err "PR was closed without merging: $CLOSE_PR_URL"
      exit 1
    fi

    log "PR state: $CLOSE_PR_STATE — waiting 60s..."
    sleep 60
  done
fi

# ── Run mode ────────────────────────────────────────────────────────
if [ "$MODE" = "run" ]; then
  if [ -z "$TARGET_INDEX" ]; then
    err "Run requires a task index: $0 --run <number>"
    exit 1
  fi

  # Read run config
  RUN_CMD=$(python3 -c "import json; print(json.load(open('$DOCS_DIR/taskbot.json')).get('run', {}).get('cmd', ''))" 2>/dev/null || true)
  RUN_PORT=$(python3 -c "import json; print(json.load(open('$DOCS_DIR/taskbot.json')).get('run', {}).get('port', ''))" 2>/dev/null || true)
  RUN_ENV_FILES=$(python3 -c "import json; [print(f) for f in json.load(open('$DOCS_DIR/taskbot.json')).get('run', {}).get('env_files', ['.env'])]" 2>/dev/null || echo ".env")

  if [ -z "$RUN_CMD" ]; then
    err "No 'run.cmd' configured in $DOCS_DIR/taskbot.json"
    err 'Add: "run": { "cmd": "npm run dev", "port": 3000, "env_files": [".env"] }'
    exit 1
  fi

  # Find task slug across all stages
  RUN_TASK=""
  for search_dir in "$DOCS_DIR" "$DEV_DIR" "$DOCS_DIR/done"; do
    found=$(find "$search_dir" -maxdepth 1 -name "${TARGET_INDEX}-*.md" -printf '%f\n' 2>/dev/null | head -1)
    if [ -n "$found" ]; then
      RUN_TASK="$found"
      break
    fi
  done

  if [ -z "$RUN_TASK" ]; then
    err "No task with index $TARGET_INDEX found"
    exit 1
  fi

  SLUG="${RUN_TASK%.md}"
  BRANCH="taskbot/${SLUG}"
  WORKTREE_DIR="$PROJECT_DIR/.taskbot-worktrees/${SLUG}"
  RUN_LOG="$PROJECT_DIR/run.log"
  PID_FILE="$PROJECT_DIR/.taskbot-run.pid"

  if [ ! -d "$WORKTREE_DIR" ]; then
    # Check if branch still exists (local or remote) and recreate worktree
    LOCAL_BRANCH=$(git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null && echo "yes" || true)
    REMOTE_BRANCH=$(git -C "$PROJECT_DIR" ls-remote --heads origin "$BRANCH" 2>/dev/null | head -1)

    if [ -n "$LOCAL_BRANCH" ] || [ -n "$REMOTE_BRANCH" ]; then
      log "Worktree gone but branch exists — recreating..."
      cd "$PROJECT_DIR"
      [ -z "$LOCAL_BRANCH" ] && git fetch origin "$BRANCH":"$BRANCH" 2>/dev/null
      mkdir -p "$(dirname "$WORKTREE_DIR")"
      git worktree add "$WORKTREE_DIR" "$BRANCH"
    else
      DEV_BRANCH=$(python3 -c "import json; print(json.load(open('$DOCS_DIR/taskbot.json'))['dev_branch'])" 2>/dev/null || echo "dev")
      err "No worktree or branch found for task $TARGET_INDEX"
      err "Branch '$BRANCH' is gone — likely already merged into $DEV_BRANCH"
      err "To run the merged code: check out $DEV_BRANCH and run normally"
      exit 1
    fi
  fi

  # Kill previous instance
  if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
      log "Killing previous run (PID: $OLD_PID)..."
      kill_descendants "$OLD_PID"
      kill "$OLD_PID" 2>/dev/null || true
      sleep 1
    fi
    rm -f "$PID_FILE"
  fi

  # Kill anything still holding the port
  if [ -n "$RUN_PORT" ]; then
    EXISTING=$(lsof -ti:"$RUN_PORT" 2>/dev/null || true)
    if [ -n "$EXISTING" ]; then
      log "Killing process on port $RUN_PORT (PID: $EXISTING)..."
      kill -9 $EXISTING 2>/dev/null || true
      sleep 0.5
    fi
  fi

  # Setup a single repo worktree: link .env files + node_modules
  setup_run_env() {
    local wt_dir="$1"
    local src_dir="$2"

    # Symlink each env file
    while IFS= read -r env_file; do
      [ -z "$env_file" ] && continue
      local src="$src_dir/$env_file"
      local dst="$wt_dir/$env_file"
      if [ -f "$src" ]; then
        ln -sfn "$src" "$dst"
        log "Linked $env_file ($(basename "$src_dir"))"
      else
        warn "Env file not found: $src"
      fi
    done <<< "$RUN_ENV_FILES"

    # node_modules: symlink if package.json unchanged, else npm install
    if [ -f "$wt_dir/package.json" ]; then
      local main_nm="$src_dir/node_modules"
      local wt_nm="$wt_dir/node_modules"
      if [ -d "$main_nm" ] && diff -q "$src_dir/package.json" "$wt_dir/package.json" &>/dev/null; then
        ln -sfn "$main_nm" "$wt_nm"
        log "Linked node_modules ($(basename "$src_dir")) — package.json unchanged"
      else
        log "Running npm install in $(basename "$wt_dir")..."
        (cd "$wt_dir" && npm install)
      fi
    fi
  }

  setup_run_env "$WORKTREE_DIR" "$PROJECT_DIR"

  # Setup sibling repo worktrees
  REPOS_JSON=$(python3 -c "
import json
cfg = json.load(open('$DOCS_DIR/taskbot.json'))
print(json.dumps(cfg.get('repos', {})))" 2>/dev/null || echo "{}")
  if [ "$REPOS_JSON" != "{}" ]; then
    for repo_rel in $(python3 -c "import json; [print(v) for v in json.loads('$REPOS_JSON').values()]"); do
      repo_abs=$(realpath "$PROJECT_DIR/$repo_rel" 2>/dev/null) || continue
      [ -d "$repo_abs/.git" ] || continue
      [ "$repo_abs" = "$PROJECT_DIR" ] && continue
      sibling_wt="$repo_abs/.taskbot-worktrees/${SLUG}"
      [ -d "$sibling_wt" ] && setup_run_env "$sibling_wt" "$repo_abs"
    done
  fi

  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Run:      task $TARGET_INDEX ($SLUG)"
  log "Worktree: $WORKTREE_DIR"
  log "Command:  $RUN_CMD"
  log "Log:      $RUN_LOG"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Run in foreground, tee to run.log with ANSI stripped
  cd "$WORKTREE_DIR"
  script -q -e -c "$RUN_CMD" /dev/null \
    2>&1 | tee >(sed -u -r 's/\x1B\[[0-9;]*[ -/]*[@-~]//g' > "$RUN_LOG") &
  RUN_PID=$!
  echo "$RUN_PID" > "$PID_FILE"

  wait "$RUN_PID" || true
  rm -f "$PID_FILE"
  exit 0
fi

# ── Review mode ─────────────────────────────────────────────────────
if [ "$MODE" = "review" ]; then
  if [ -z "$TARGET_INDEX" ]; then
    err "Review requires a task index: $0 --review <number>"
    exit 1
  fi

  REVIEW_INSTRUCTIONS="$TASKBOT_HOME/REVIEW_INSTRUCTIONS.md"
  if [ ! -f "$REVIEW_INSTRUCTIONS" ]; then
    err "REVIEW_INSTRUCTIONS.md not found in $TASKBOT_HOME"
    exit 1
  fi

  # Find task in docs/dev/
  REVIEW_TASK=$(find "$DEV_DIR" -maxdepth 1 -name "${TARGET_INDEX}-*.md" -printf '%f\n' | head -1)
  if [ -z "$REVIEW_TASK" ]; then
    err "No task with index $TARGET_INDEX found in docs/dev/"
    exit 1
  fi

  REVIEW_TASK_PATH="$DEV_DIR/$REVIEW_TASK"
  REVIEW_SLUG="${REVIEW_TASK%.md}"
  REVIEW_BRANCH="taskbot/${REVIEW_SLUG}"
  REVIEW_WORKTREE="$PROJECT_DIR/.taskbot-worktrees/${REVIEW_SLUG}"

  # Recreate worktree if needed (same fallback as --run)
  if [ ! -d "$REVIEW_WORKTREE" ]; then
    LOCAL_BRANCH=$(git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$REVIEW_BRANCH" 2>/dev/null && echo "yes" || true)
    REMOTE_BRANCH=$(git -C "$PROJECT_DIR" ls-remote --heads origin "$REVIEW_BRANCH" 2>/dev/null | head -1)
    if [ -n "$LOCAL_BRANCH" ] || [ -n "$REMOTE_BRANCH" ]; then
      log "Worktree gone but branch exists — recreating..."
      cd "$PROJECT_DIR"
      [ -z "$LOCAL_BRANCH" ] && git fetch origin "$REVIEW_BRANCH":"$REVIEW_BRANCH" 2>/dev/null
      mkdir -p "$(dirname "$REVIEW_WORKTREE")"
      git worktree add "$REVIEW_WORKTREE" "$REVIEW_BRANCH"
    else
      err "No worktree or branch found for task $TARGET_INDEX"
      exit 1
    fi
  fi

  mkdir -p "$LOG_DIR"
  TIMESTAMP=$(date +%Y%m%d-%H%M%S)
  REVIEW_LOG="$LOG_DIR/${TARGET_INDEX}-review-${TIMESTAMP}.log"

  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Review:   $REVIEW_TASK"
  log "Worktree: $REVIEW_WORKTREE"
  log "Log:      $REVIEW_LOG"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  REVIEW_EXIT=0
  (
    cd "$REVIEW_WORKTREE"
    claude -p \
      --permission-mode bypassPermissions \
      --model opus \
      --verbose \
      --output-format stream-json \
      "Read ${REVIEW_INSTRUCTIONS} for how to execute, then read ${REVIEW_TASK_PATH} for the task. Execute the review." \
      2>&1 | tee "$REVIEW_LOG.raw" | \
      python3 -u "$STREAM_FILTER" | tee "$REVIEW_LOG"
  ) &
  CHILD_PID=$!
  wait "$CHILD_PID" || REVIEW_EXIT=$?
  CHILD_PID=""

  if [ $REVIEW_EXIT -ne 0 ]; then
    err "Claude exited with code $REVIEW_EXIT"
    err "See log: $REVIEW_LOG"
    exit 1
  fi

  if tail -20 "$REVIEW_LOG" | grep -qi "SUCCESS"; then
    mark_done "$REVIEW_SLUG" "review"
    ok "Review complete"
    next=$(next_op "$REVIEW_SLUG")
    case "$next" in
      run)  ok "Next: taskbot.sh --next $TARGET_INDEX  (run local tests, then --next again for PR)" ;;
      pr)   ok "Next: taskbot.sh --next $TARGET_INDEX  (creates PR)" ;;
      done) ok "Next: taskbot.sh --promote $TARGET_INDEX" ;;
      *)    ok "Next: taskbot.sh --next $TARGET_INDEX" ;;
    esac
  else
    warn "Review may have failed — check log: $REVIEW_LOG"
    exit 1
  fi

  exit 0
fi

# ── Auto-next mode ───────────────────────────────────────────────────
if [ "$MODE" = "auto_next" ]; then
  if [ -z "$TARGET_INDEX" ]; then
    err "Next requires a task index: $0 --next <number>"
    exit 1
  fi

  # Find task slug (must be in docs/dev/)
  NEXT_TASK=$(find "$DEV_DIR" -maxdepth 1 -name "${TARGET_INDEX}-*.md" -printf '%f\n' | head -1)
  if [ -z "$NEXT_TASK" ]; then
    err "No task with index $TARGET_INDEX found in docs/dev/"
    exit 1
  fi

  NEXT_SLUG="${NEXT_TASK%.md}"

  if [ ! -f "$STATE_DIR/$NEXT_SLUG.json" ]; then
    warn "No state file for task $TARGET_INDEX ($NEXT_SLUG)"
    warn "This task predates the workflow system."
    warn "To promote: taskbot.sh --promote $TARGET_INDEX"
    exit 0
  fi

  OP=$(next_op "$NEXT_SLUG")
  PR_METHOD=$(python3 -c "import json; print(json.load(open('$DOCS_DIR/taskbot.json')).get('pr', {}).get('create_method', 'gh_cli'))" 2>/dev/null || echo "gh_cli")

  case "$OP" in
    code)
      err "Code phase not complete. Run: taskbot.sh $TARGET_INDEX"
      exit 1
      ;;
    review)
      exec "$0" "$PROJECT_DIR" --review "$TARGET_INDEX"
      ;;
    run)
      ok "Human test step: run the app from the worktree and verify manually."
      ok "  taskbot.sh --run $TARGET_INDEX   (starts dev server from worktree)"
      ok ""
      ok "When done testing, call --next again to advance:"
      ok "  taskbot.sh --next $TARGET_INDEX"
      mark_done "$NEXT_SLUG" "run"
      next=$(next_op "$NEXT_SLUG")
      ok "Marked 'run' complete. Next op: $next"
      ;;
    pr)
      NEXT_BRANCH=$(load_state_field "$NEXT_SLUG" "branch")
      NEXT_MERGE_INTO=$(load_state_field "$NEXT_SLUG" "merge_into")
      if [ "$PR_METHOD" = "gh_cli" ]; then
        PR_REPO=$(python3 -c "import json; print(json.load(open('$DOCS_DIR/taskbot.json')).get('pr', {}).get('repo', ''))" 2>/dev/null || echo "")
        PR_REVIEWER=$(python3 -c "import json; print(json.load(open('$DOCS_DIR/taskbot.json')).get('pr', {}).get('reviewer', ''))" 2>/dev/null || echo "")
        PR_TITLE=$(python3 - "$DEV_DIR/$NEXT_TASK" <<'PYEOF'
import sys, re, os
task = open(sys.argv[1]).read()
m = re.search(r'^## Problem\n(.+?)(?:\n|$)', task, re.MULTILINE)
if m:
    print(m.group(1).strip()[:72])
else:
    fname = os.path.basename(sys.argv[1]).replace('.md', '').replace('-', ' ')
    print(fname[:72])
PYEOF
)
        log "Creating PR: $NEXT_BRANCH → $NEXT_MERGE_INTO"
        PR_ARGS=(--base "$NEXT_MERGE_INTO" --head "$NEXT_BRANCH" --title "$PR_TITLE")
        [ -n "$PR_REPO" ] && PR_ARGS=(--repo "$PR_REPO" "${PR_ARGS[@]}")
        [ -n "$PR_REVIEWER" ] && PR_ARGS=("${PR_ARGS[@]}" --reviewer "$PR_REVIEWER")
        PR_URL=$(gh pr create "${PR_ARGS[@]}" 2>&1 | grep -E 'https?://' | tail -1 || true)
        if [ -n "$PR_URL" ]; then
          set_pr_url "$NEXT_SLUG" "$PR_URL"
          mark_done "$NEXT_SLUG" "pr"
          ok "PR created: $PR_URL"
          ok "Next: taskbot.sh --promote $TARGET_INDEX"
        else
          err "PR creation may have failed — check output above"
          exit 1
        fi
      else
        warn "PR method is '$PR_METHOD' — create PR manually:"
        warn "  Branch: $NEXT_BRANCH → $NEXT_MERGE_INTO"
        warn "Then run: taskbot.sh --promote $TARGET_INDEX"
      fi
      ;;
    merge|deploy_check)
      ok "Next step is '$OP' — run: taskbot.sh --promote $TARGET_INDEX"
      ;;
    done)
      ok "All operations complete. Run: taskbot.sh --promote $TARGET_INDEX"
      ;;
    no_state)
      err "No state file found for task $TARGET_INDEX"
      exit 1
      ;;
    *)
      err "Unknown next operation: $OP"
      exit 1
      ;;
  esac

  exit 0
fi

# ── Validate project ────────────────────────────────────────────────
if [ ! -f "$INSTRUCTIONS" ] && [ "$MODE" != "list" ] && [ "$MODE" != "dry" ]; then
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

# ── Workflow + state helpers ─────────────────────────────────────────

read_workflow() {
  local task_path="$1"
  local dev_branch
  dev_branch=$(python3 -c "import json; print(json.load(open('$DOCS_DIR/taskbot.json'))['dev_branch'])" 2>/dev/null || echo "dev")
  python3 - "$task_path" "$dev_branch" <<'PYEOF'
import sys, re
task_path, dev_b = sys.argv[1], sys.argv[2]
task = open(task_path).read()
m = re.search(r'## Workflow\n(.*?)(?=\n## |\Z)', task, re.DOTALL)
if not m:
    print(f'standard:code,pr:{dev_b}:{dev_b}')
    sys.exit(0)
section = m.group(1)
def get(key, default):
    r = re.search(r'^' + key + r':\s*(.+)$', section, re.MULTILINE)
    return r.group(1).strip() if r else default
preset = get('preset', 'standard')
ops_map = {'instant': 'code,merge', 'standard': 'code,pr', 'thorough': 'code,review,run,pr'}
operations = get('operations', ops_map.get(preset, 'code,pr'))
branch_from = get('branch_from', dev_b)
merge_into = get('merge_into', dev_b)
print(f'{preset}:{operations}:{branch_from}:{merge_into}')
PYEOF
}

init_state() {
  local slug="$1" preset="$2" operations="$3" branch="$4" branch_from="$5" merge_into="$6"
  mkdir -p "$STATE_DIR"
  python3 - "$STATE_DIR/$slug.json" "$slug" "$preset" "$operations" "$branch" "$branch_from" "$merge_into" <<'PYEOF'
import sys, json
path, slug, preset, operations, branch, branch_from, merge_into = sys.argv[1:8]
data = {
    'slug': slug,
    'preset': preset,
    'branch': branch,
    'branch_from': branch_from,
    'merge_into': merge_into,
    'operations': operations.split(','),
    'completed': ['code'],
    'pr_url': None,
}
json.dump(data, open(path, 'w'), indent=2)
PYEOF
}

mark_done() {
  local slug="$1" op="$2"
  python3 - "$STATE_DIR/$slug.json" "$op" <<'PYEOF'
import sys, json
path, op = sys.argv[1], sys.argv[2]
data = json.load(open(path))
if op not in data['completed']:
    data['completed'].append(op)
json.dump(data, open(path, 'w'), indent=2)
PYEOF
}

next_op() {
  local slug="$1"
  local state_file="$STATE_DIR/$slug.json"
  if [ ! -f "$state_file" ]; then
    echo "no_state"
    return
  fi
  python3 - "$state_file" <<'PYEOF'
import sys, json
data = json.load(open(sys.argv[1]))
ops = data.get('operations', [])
done = data.get('completed', [])
for op in ops:
    if op not in done:
        print(op)
        exit()
print('done')
PYEOF
}

load_state_field() {
  local slug="$1" field="$2"
  local state_file="$STATE_DIR/$slug.json"
  [ -f "$state_file" ] || { echo ""; return; }
  python3 - "$state_file" "$field" <<'PYEOF'
import sys, json
data = json.load(open(sys.argv[1]))
val = data.get(sys.argv[2], '')
print(val if val is not None else '')
PYEOF
}

set_pr_url() {
  local slug="$1" url="$2"
  python3 - "$STATE_DIR/$slug.json" "$url" <<'PYEOF'
import sys, json
path, url = sys.argv[1], sys.argv[2]
data = json.load(open(path))
data['pr_url'] = url
json.dump(data, open(path, 'w'), indent=2)
PYEOF
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
  local dev_branch prod_branch
  dev_branch=$(python3 -c "import json; print(json.load(open('$DOCS_DIR/taskbot.json'))['dev_branch'])")
  prod_branch=$(python3 -c "import json; print(json.load(open('$DOCS_DIR/taskbot.json'))['prod_branch'])")

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
    git branch "$branch" "origin/$dev_branch" 2>/dev/null \
      || git branch "$branch" "$dev_branch" 2>/dev/null \
      || git branch "$branch" "origin/$prod_branch" 2>/dev/null \
      || git branch "$branch" "$prod_branch"
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
        git branch "$sibling_branch" "origin/$dev_branch" 2>/dev/null \
          || git branch "$sibling_branch" "$dev_branch" 2>/dev/null \
          || git branch "$sibling_branch" "origin/$prod_branch" 2>/dev/null \
          || git branch "$sibling_branch" "$prod_branch"
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

    # Parse workflow from task doc
    workflow=$(read_workflow "$task_path")
    wf_preset=$(echo "$workflow" | cut -d: -f1)
    wf_operations=$(echo "$workflow" | cut -d: -f2)
    wf_branch_from=$(echo "$workflow" | cut -d: -f3)
    wf_merge_into=$(echo "$workflow" | cut -d: -f4)

    # Write state file (worktree stays alive for review/run/promote)
    init_state "$slug" "$wf_preset" "$wf_operations" "$branch" "$wf_branch_from" "$wf_merge_into"

    # Move task doc to docs/dev/
    mv "$task_path" "$DEV_DIR/$task_file"
    ok "Moved $task_file → docs/dev/"

    # Hint next step
    next=$(next_op "$slug")
    case "$next" in
      review) ok "Next: taskbot.sh --review $index" ;;
      run)    ok "Next: taskbot.sh --run $index  (then --next $index)" ;;
      pr)     ok "Next: taskbot.sh --next $index  (creates PR)" ;;
      *)      ok "Next: taskbot.sh --next $index" ;;
    esac

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
        echo "  $(task_index "$t"). $t  [next: $(next_op "${t%.md}")]"
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
