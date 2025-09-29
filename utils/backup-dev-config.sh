#!/usr/bin/env bash
set -euo pipefail

# Backup JetBrains configs + Chrome/Chromium profile configs into a single ZIP,
# excluding caches and temp files.
#
# Usage:
#   ./backup-dev-configs.sh
#   ./backup-dev-configs.sh --chromium
#   ./backup-dev-configs.sh --chrome-dir /custom/path
#   ./backup-dev-configs.sh --out /path/to/my-backup.zip
#
# Notes:
# - By default backs up Google Chrome from ~/.config/google-chrome
#   Use --chromium to switch to ~/.config/chromium
#   Or override with --chrome-dir /custom/path
# - Excludes: browser caches (Cache, Code Cache, GPUCache, etc.), Crashpad,
#   JetBrains caches (~/.cache/JetBrains) & logs.
# - Result: a ZIP that contains `JetBrains/` and `chrome/` top-level folders.

CHROME_DIR_DEFAULT="$HOME/.config/google-chrome"
CHROMIUM_DIR_DEFAULT="$HOME/.config/chromium"
USE_CHROMIUM=false
CUSTOM_CHROME_DIR=""
OUTZIP=""
TS="$(date +'%Y%m%d-%H%M%S')"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chromium) USE_CHROMIUM=true; shift ;;
    --chrome-dir) CUSTOM_CHROME_DIR="${2:-}"; shift 2 ;;
    --out) OUTZIP="${2:-}"; shift 2 ;;
    -h|--help)
      grep '^# ' "$0" | sed 's/^# //'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -n "$CUSTOM_CHROME_DIR" ]]; then
  CHROME_DIR="$CUSTOM_CHROME_DIR"
elif $USE_CHROMIUM; then
  CHROME_DIR="$CHROMIUM_DIR_DEFAULT"
else
  CHROME_DIR="$CHROME_DIR_DEFAULT"
fi

if [[ -z "${OUTZIP}" ]]; then
  OUTZIP="$PWD/dev-configs-${TS}.zip"
fi

echo ">> Chrome base dir: $CHROME_DIR"
echo ">> Output zip:      $OUTZIP"

# Sanity checks
if [[ ! -d "$CHROME_DIR" ]]; then
  echo "!! Chrome directory not found: $CHROME_DIR"
  echo "   Use --chromium or --chrome-dir to point to the right location."
  exit 2
fi

# Prepare staging dir
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/chrome" "$STAGE/JetBrains"

echo ">> Staging to: $STAGE"

############################################
# 1) Chrome / Chromium (config only, no caches)
############################################
# Stop Chrome to avoid file locks
pkill -x chrome || true
pkill -x chromium || true
sleep 1

# Copy Chrome profile while excluding caches & temp dirs
# Common cache folders across profiles: Cache, Code Cache, GPUCache, ShaderCache,
# GrShaderCache, Crashpad, Safe Browsing (optional), BrowserMetrics, Service Worker/CacheStorage
rsync -a \
  --delete \
  --exclude='*/Cache/**' \
  --exclude='*/Code Cache/**' \
  --exclude='*/GPUCache/**' \
  --exclude='*/ShaderCache/**' \
  --exclude='*/GrShaderCache/**' \
  --exclude='*/Crashpad/**' \
  --exclude='*/BrowserMetrics/**' \
  --exclude='*/Service Worker/CacheStorage/**' \
  --exclude='*/OptimizationGuideModelStore/**' \
  --exclude='*/Media Cache/**' \
  --exclude='*/Application Cache/**' \
  --exclude='*/GrShaderCache/**' \
  --exclude='*/OnDeviceHeadSuggestModel/**' \
  "$CHROME_DIR"/ "$STAGE/chrome/"

############################################
# 2) JetBrains (configs & data, no caches)
############################################
# We copy:
#   ~/.config/JetBrains   -> settings (options/, keymaps/, colors/, codestyles/, plugins configs)
#   ~/.local/share/JetBrains -> plugins & shared data (keep), excluding logs
# We DO NOT copy:
#   ~/.cache/JetBrains    -> caches (auto-regenerated)
JB_CFG="$HOME/.config/JetBrains"
JB_SHARE="$HOME/.local/share/JetBrains"
JB_CACHE="$HOME/.cache/JetBrains"

if [[ -d "$JB_CFG" ]]; then
  rsync -a "$JB_CFG"/ "$STAGE/JetBrains/config/"
fi

if [[ -d "$JB_SHARE" ]]; then
  rsync -a \
    --exclude='**/log/**' \
    --exclude='**/logs/**' \
    "$JB_SHARE"/ "$STAGE/JetBrains/share/"
fi

# We intentionally skip ~/.cache/JetBrains

############################################
# Make the ZIP
############################################
# Ensure correct ownership (just in case)
chown -R "$USER":"$USER" "$STAGE"

# Create zip
( cd "$STAGE" && zip -r -q --symlinks "$OUTZIP" chrome JetBrains )
# Move to requested output path if OUTZIP not absolute
if [[ "$OUTZIP" != /* ]]; then
  mv "$STAGE/$OUTZIP" "$OUTZIP" 2>/dev/null || true
fi

echo ">> Done."
echo "Backup created at: $OUTZIP"

cat <<'USAGE'

Restore notes:
  - Close Chrome/Chromium and JetBrains IDEs first.
  - Chrome: copy the 'chrome/' contents back to your profile dir (e.g. ~/.config/google-chrome).
      rsync -a chrome/ ~/.config/google-chrome/
    Then fix ownership if needed:
      chown -R $USER:$USER ~/.config/google-chrome
  - JetBrains: copy 'JetBrains/config/' -> ~/.config/JetBrains/
               copy 'JetBrains/share/'  -> ~/.local/share/JetBrains/
      rsync -a JetBrains/config/ ~/.config/JetBrains/
      rsync -a JetBrains/share/  ~/.local/share/JetBrains/
    Then:
      chown -R $USER:$USER ~/.config/JetBrains ~/.local/share/JetBrains

Tip:
  If you use Chromium instead of Chrome, run the backup script with --chromium
  or specify a custom path with --chrome-dir.

USAGE


