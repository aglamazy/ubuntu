#!/bin/bash
#
# run-dev.sh — Start the project dev server (Next.js)
#
# Usage: run-dev.sh <project-dir>
#
# - Detects port from package.json dev script (-p XXXX) or .env PORT=
# - Kills any existing process on that port
# - Launches Chrome with remote debugging if not already running
# - Starts npm run dev, tee'd to run.log

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${BLUE}[taskbot]${NC} $*"; }
ok()   { echo -e "${GREEN}[taskbot]${NC} $*"; }
warn() { echo -e "${YELLOW}[taskbot]${NC} $*"; }
err()  { echo -e "${RED}[taskbot]${NC} $*" >&2; }

PROJECT_DIR="${1:-$(pwd)}"
PROJECT_DIR="$(realpath "$PROJECT_DIR")"
PROJECT_NAME="$(basename "$PROJECT_DIR")"
PKG="$PROJECT_DIR/package.json"
PID_FILE="$PROJECT_DIR/.taskbot-run.pid"
RUN_LOG="$PROJECT_DIR/run.log"

if [ ! -f "$PKG" ]; then
  err "No package.json found in $PROJECT_DIR"
  exit 1
fi

# ── Detect port ───────────────────────────────────────────────────────
PORT=$(python3 -c "
import json, re, os
pkg = json.load(open('$PKG'))
dev_cmd = pkg.get('scripts', {}).get('dev', '')
m = re.search(r'-p\s+(\d+)', dev_cmd)
if m:
    print(m.group(1)); exit()
env_file = os.path.join('$PROJECT_DIR', '.env')
if os.path.exists(env_file):
    for line in open(env_file):
        m = re.match(r'^PORT=(\d+)', line)
        if m:
            print(m.group(1)); exit()
print('3000')
" 2>/dev/null)

log "Project: $PROJECT_NAME  port: $PORT"

# ── Kill previous taskbot-managed instance ────────────────────────────
kill_descendants() {
  local pid=$1
  local children
  children=$(pgrep -P "$pid" 2>/dev/null) || true
  for child in $children; do kill_descendants "$child"; done
  kill "$pid" 2>/dev/null || true
}

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

# ── Kill anything holding the port and wait for it to be free ────────
if fuser "$PORT/tcp" >/dev/null 2>&1; then
  log "Killing all processes on port $PORT..."
  fuser -k "$PORT/tcp" 2>/dev/null || true
  # Wait up to 5s for the port to be released
  for i in $(seq 1 10); do
    fuser "$PORT/tcp" >/dev/null 2>&1 || break
    sleep 0.5
  done
  if fuser "$PORT/tcp" >/dev/null 2>&1; then
    err "Port $PORT still in use after 5s — aborting"
    exit 1
  fi
fi

# ── Launch Chrome with remote debugging ──────────────────────────────
URL="http://localhost:$PORT"
if lsof -ti:9222 >/dev/null 2>&1; then
  log "Chrome remote debugging already active on port 9222"
else
  log "Launching Chrome → $URL"
  google-chrome --remote-debugging-port=9222 \
    --user-data-dir="$HOME/.chrome-dev-profile" \
    "$URL" >/dev/null 2>&1 &
fi

# ── Start dev server ─────────────────────────────────────────────────
log "Starting npm run dev... (log: $RUN_LOG)"
cd "$PROJECT_DIR"
script -q -e -c "npm run dev" /dev/null \
  2>&1 | tee >(sed -u -r 's/\x1B\[[0-9;]*[ -/]*[@-~]//g' > "$RUN_LOG") &
RUN_PID=$!
echo "$RUN_PID" > "$PID_FILE"
wait "$RUN_PID" || true
rm -f "$PID_FILE"
