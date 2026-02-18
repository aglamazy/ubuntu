#!/usr/bin/env bash
set -euo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
umask 077

LOG_DIR="$HOME/.local/state/cleanup"
LOG_FILE="$LOG_DIR/weekly-cleanup.log"
mkdir -p "$LOG_DIR"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

RECOVERED_BYTES=0

format_bytes() {
  local bytes="$1"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec --suffix=B "$bytes"
  else
    printf '%sB' "$bytes"
  fi
}

CONFIG_FILE="${CONFIG_FILE:-$HOME/.config/cleanup/clean_weekly.conf}"

DRY_RUN="${DRY_RUN:-0}"
DRY_RUN_VERBOSE="${DRY_RUN_VERBOSE:-0}"
DRY_RUN_MAX_ITEMS="${DRY_RUN_MAX_ITEMS:-20}"
DRY_RUN_TOP_FILES="${DRY_RUN_TOP_FILES:-10}"
CACHE_DAYS="${CACHE_DAYS:-30}"
NODE_MODULES_DAYS="${NODE_MODULES_DAYS:-90}"
SEARCH_ROOTS="${SEARCH_ROOTS:-$HOME}"
EXCLUDE_PATHS="${EXCLUDE_PATHS:-$HOME/installs $HOME/.config $HOME/.local/share/JetBrains $HOME/snap}"

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

CACHE_TARGETS=(
  "$HOME/.cache"
  "$HOME/.npm/_cacache"
  "$HOME/.cache/google-chrome"
  "$HOME/.cache/JetBrains"
  "$HOME/.cache/ms-playwright"
  "$HOME/.cache/ms-playwright-go"
  "$HOME/.cache/puppeteer"
)

run_rm() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN: $*"
  else
    "$@"
  fi
}

clean_old_files() {
  local target="$1"
  local days="$2"
  if [[ ! -e "$target" ]]; then
    return 0
  fi

  log "Cleaning old files in $target (older than ${days}d)"
  if [[ "$DRY_RUN" == "1" ]]; then
    local count total bytes_human
    count=0
    total=0
    while IFS= read -r -d '' size; do
      count=$((count + 1))
      total=$((total + size))
    done < <(find "$target" -type f -mtime "+$days" -printf '%s\0')
    bytes_human="$(format_bytes "$total")"
    log "DRY_RUN summary for $target: ${count} files, ${bytes_human} total"
    RECOVERED_BYTES=$((RECOVERED_BYTES + total))

    log "DRY_RUN dirs with old files in $target (first ${DRY_RUN_MAX_ITEMS})"
    local dir_count
    dir_count=0
    while IFS= read -r -d '' dir; do
      log "DIR: $dir"
      dir_count=$((dir_count + 1))
    done < <(
      find "$target" -type f -mtime "+$days" -printf '%h\0' | sort -zu | head -z -n "$DRY_RUN_MAX_ITEMS"
    )
    if [[ "$dir_count" -eq 0 ]]; then
      log "DIR: (none)"
    fi

    log "DRY_RUN largest old files in $target (top ${DRY_RUN_TOP_FILES})"
    local file_count
    file_count=0
    while IFS=$'\t' read -r -d '' size path; do
      if command -v numfmt >/dev/null 2>&1; then
        size="$(numfmt --to=iec --suffix=B "$size")"
      else
        size="${size}B"
      fi
      log "FILE: $size $path"
      file_count=$((file_count + 1))
    done < <(
      find "$target" -type f -mtime "+$days" -printf '%s\t%p\0' | sort -z -nr | head -z -n "$DRY_RUN_TOP_FILES"
    )
    if [[ "$file_count" -eq 0 ]]; then
      log "FILE: (none)"
    fi

    if [[ "$DRY_RUN_VERBOSE" == "1" ]]; then
      while IFS= read -r -d '' file; do
        log "DRY_RUN would remove file: $file"
      done < <(find "$target" -type f -mtime "+$days" -print0)
      while IFS= read -r -d '' dir; do
        log "DRY_RUN would remove empty dir: $dir"
      done < <(find "$target" -type d -empty -print0)
    fi
  else
    local count total
    count=0
    total=0
    while IFS= read -r -d '' size; do
      count=$((count + 1))
      total=$((total + size))
    done < <(find "$target" -type f -mtime "+$days" -printf '%s\0')
    RECOVERED_BYTES=$((RECOVERED_BYTES + total))
    find "$target" -type f -mtime "+$days" -print0 | xargs -0 -r -I{} bash -c 'rm -f "$1"' _ {}
    # Remove empty directories left behind
    find "$target" -type d -empty -print0 | xargs -0 -r -I{} bash -c 'rmdir "$1" 2>/dev/null || true' _ {}
  fi
}

clean_node_modules() {
  log "Removing node_modules older than ${NODE_MODULES_DAYS}d under ${SEARCH_ROOTS}"
  local tmp_sizes
  if [[ "$DRY_RUN" == "1" ]]; then
    tmp_sizes="$(mktemp "$LOG_DIR/node_modules_sizes.XXXXXX")"
  else
    tmp_sizes="$(mktemp "$LOG_DIR/node_modules_sizes.XXXXXX")"
  fi
  local find_args=()
  for root in $SEARCH_ROOTS; do
    find_args+=("$root")
  done
  for ex in $EXCLUDE_PATHS; do
    find_args+=(-path "$ex" -prune -o)
  done
  find_args+=(-type d -name node_modules -prune -mtime "+$NODE_MODULES_DAYS" -print0)

  while IFS= read -r -d '' nm_dir; do
    local size
    size="$(du -sb "$nm_dir" 2>/dev/null | awk '{print $1}')"
    size="${size:-0}"
    printf '%s\t%s\0' "$size" "$nm_dir" >> "$tmp_sizes"
    if [[ "$DRY_RUN" != "1" ]]; then
      log "Removing $nm_dir"
      rm -rf "$nm_dir"
    fi
  done < <(find "${find_args[@]}")

  local total count size_h
  total=0
  count=0
  while IFS=$'\t' read -r -d '' size path; do
    total=$((total + size))
    count=$((count + 1))
  done < "$tmp_sizes"
  RECOVERED_BYTES=$((RECOVERED_BYTES + total))
  size_h="$(format_bytes "$total")"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN node_modules summary: ${count} dirs, ${size_h} total"
  else
    log "node_modules summary: ${count} dirs, ${size_h} removed"
  fi

  log "Largest node_modules (top ${DRY_RUN_MAX_ITEMS})"
  local nm_count
  nm_count=0
  while IFS=$'\t' read -r -d '' size path; do
    size="$(format_bytes "$size")"
    log "NODE_MODULES: $size $path"
    nm_count=$((nm_count + 1))
  done < <(sort -z -nr "$tmp_sizes" | head -z -n "$DRY_RUN_MAX_ITEMS")
  if [[ "$nm_count" -eq 0 ]]; then
    log "NODE_MODULES: (none)"
  fi
  rm -f "$tmp_sizes"
}

clean_build_artifacts() {
  log "Cleaning build artifacts"

  local artifacts=(
    "$HOME/develop/Azure/agent*/_work/*/drop"
    "$HOME/develop/Azure/agent*/_work/*/a"
    "$HOME/develop/*/dist"
    "$HOME/develop/*/*/dist"
  )

  local total=0
  local count=0

  for pattern in "${artifacts[@]}"; do
    for dir in $pattern; do
      [[ -d "$dir" ]] || continue
      local size
      size="$(du -sb "$dir" 2>/dev/null | awk '{print $1}')"
      size="${size:-0}"
      total=$((total + size))
      count=$((count + 1))
      if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY_RUN would remove: $dir ($(format_bytes "$size"))"
      else
        log "Removing $dir ($(format_bytes "$size"))"
        rm -rf "$dir"
      fi
    done
  done

  RECOVERED_BYTES=$((RECOVERED_BYTES + total))
  log "Build artifacts: ${count} dirs, $(format_bytes "$total")"
}

clean_git_repos() {
  log "Running git gc on repos under ${SEARCH_ROOTS}"
  local total_before=0
  local total_after=0
  local count=0

  local find_args=()
  for root in $SEARCH_ROOTS; do
    find_args+=("$root")
  done
  for ex in $EXCLUDE_PATHS; do
    find_args+=(-path "$ex" -prune -o)
  done
  find_args+=(-type d -name .git -print0)

  while IFS= read -r -d '' git_dir; do
    local repo_dir
    repo_dir="$(dirname "$git_dir")"
    local before after saved
    before="$(du -sb "$git_dir" 2>/dev/null | awk '{print $1}')"
    before="${before:-0}"

    if [[ "$DRY_RUN" == "1" ]]; then
      log "DRY_RUN would gc: $repo_dir (.git=$(format_bytes "$before"))"
    else
      git -C "$repo_dir" gc --prune=now --quiet 2>/dev/null || true
      after="$(du -sb "$git_dir" 2>/dev/null | awk '{print $1}')"
      after="${after:-0}"
      saved=$((before - after))
      if [[ "$saved" -gt 0 ]]; then
        log "gc $repo_dir: $(format_bytes "$before") -> $(format_bytes "$after") (saved $(format_bytes "$saved"))"
      fi
      total_before=$((total_before + before))
      total_after=$((total_after + after))
    fi
    count=$((count + 1))
  done < <(find "${find_args[@]}")

  local total_saved=$((total_before - total_after))
  RECOVERED_BYTES=$((RECOVERED_BYTES + total_saved))
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN git gc: ${count} repos found"
  else
    log "git gc: ${count} repos, saved $(format_bytes "$total_saved")"
  fi
}

clean_system() {
  if [[ "${CLEAN_SYSTEM:-0}" != "1" ]]; then
    return 0
  fi

  local SUDO=""
  if [[ "$EUID" -ne 0 ]]; then
    if sudo -n true 2>/dev/null; then
      SUDO="sudo -n"
    else
      log "Skipping system cleanup (no passwordless sudo)."
      return 0
    fi
  fi

  log "System cleanup: journalctl vacuum, apt clean/autoremove, snap cleanup"
  $SUDO journalctl --vacuum-time=2d || true
  $SUDO apt-get clean || true
  $SUDO apt-get autoclean || true
  $SUDO apt-get autoremove -y || true

  if [[ -x "$(dirname "$0")/clean_snap" ]]; then
    $SUDO "$(dirname "$0")/clean_snap" || true
  fi
}

log "Weekly cleanup started"

for target in "${CACHE_TARGETS[@]}"; do
  clean_old_files "$target" "$CACHE_DAYS"
done

clean_node_modules
clean_build_artifacts
clean_git_repos
clean_system

log "Weekly cleanup complete"
if [[ "$DRY_RUN" == "1" ]]; then
  log "DRY_RUN total recoverable (file deletions only): $(format_bytes "$RECOVERED_BYTES")"
else
  log "Recovered from file deletions: $(format_bytes "$RECOVERED_BYTES") (excluding apt/journal/snap)"
  # Ping healthchecks.io on success
  curl -fsS -m 10 --retry 5 https://hc-ping.com/c882a0d4-50fb-49e5-b6f8-92c6c1297a53 >/dev/null 2>&1 || true
fi
