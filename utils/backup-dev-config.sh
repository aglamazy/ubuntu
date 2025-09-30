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

# Resolve output path now that we operate directly on source directories
if [[ "$OUTZIP" != /* ]]; then
  OUTZIP_ABS="$PWD/$OUTZIP"
else
  OUTZIP_ABS="$OUTZIP"
fi

OUTDIR="$(dirname "$OUTZIP_ABS")"
mkdir -p "$OUTDIR"
rm -f "$OUTZIP_ABS"

echo ">> Writing zip directly to: $OUTZIP_ABS"

############################################
# 1) Chrome / Chromium (config only, no caches)
############################################
# Stop Chrome to avoid file locks
pkill -x chrome || true
pkill -x chromium || true
sleep 1

# Copy Chrome profile while excluding caches & temp dirs
# Show which profile is being collected for easier troubleshooting
echo ">> Archiving Chrome profile without staging copy"

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

echo ">> Collecting JetBrains configs without staging copy"

############################################
# Make the ZIP
############################################
python3 - <<'PY' "$OUTZIP_ABS" "$CHROME_DIR" "$JB_CFG" "$JB_SHARE"
from __future__ import annotations

import os
import stat
import sys
import zipfile
from pathlib import Path
from typing import Set, Tuple

try:
    import zlib  # noqa: F401
    COMPRESSION = zipfile.ZIP_DEFLATED
except ModuleNotFoundError:  # pragma: no cover
    COMPRESSION = zipfile.ZIP_STORED

out_zip = Path(sys.argv[1])
chrome_dir = Path(sys.argv[2])
jb_cfg = Path(sys.argv[3])
jb_share = Path(sys.argv[4])

# Directories to skip entirely inside Chrome/Chromium profiles
CHROME_SKIP_NAMES: Set[str] = {
    "Cache",
    "Code Cache",
    "GPUCache",
    "ShaderCache",
    "GrShaderCache",
    "Crashpad",
    "BrowserMetrics",
    "OptimizationGuideModelStore",
    "Media Cache",
    "Application Cache",
    "OnDeviceHeadSuggestModel",
}
CHROME_SKIP_PAIRS: Set[Tuple[str, str]] = {
    (
        "Service Worker",
        "CacheStorage",
    ),
}

# JetBrains shared data: drop logs/caches
JB_SHARE_SKIP_NAMES: Set[str] = {"log", "logs"}

written_dirs: Set[str] = set()


def arc_from_parts(prefix: str, parts: Tuple[str, ...]) -> str:
    return prefix if not parts else f"{prefix}/{'/'.join(parts)}"


def should_exclude(parts: Tuple[str, ...], skip_names: Set[str], skip_pairs: Set[Tuple[str, str]]) -> bool:
    if not parts:
        return False
    if any(part in skip_names for part in parts):
        return True
    for parent, child in skip_pairs:
        for idx in range(len(parts) - 1):
            if parts[idx] == parent and parts[idx + 1] == child:
                return True
    return False


def write_dir(zipf: zipfile.ZipFile, arcname: str) -> None:
    arc = arcname.rstrip("/") + "/"
    if arc in written_dirs:
        return
    info = zipfile.ZipInfo(arc)
    info.create_system = 3  # Unix
    info.external_attr = (stat.S_IFDIR | 0o755) << 16
    zipf.writestr(info, b"")
    written_dirs.add(arc)


def add_symlink(zipf: zipfile.ZipFile, source: Path, arcname: str) -> None:
    target = os.readlink(source)
    info = zipfile.ZipInfo(arcname)
    info.create_system = 3
    info.external_attr = (stat.S_IFLNK | 0o777) << 16
    zipf.writestr(info, target)


def add_tree(
    zipf: zipfile.ZipFile,
    base_path: Path,
    prefix: str,
    skip_names: Set[str],
    skip_pairs: Set[Tuple[str, str]],
) -> None:
    if not base_path.exists():
        return

    write_dir(zipf, prefix)

    for root, dirs, files in os.walk(base_path, topdown=True, followlinks=False):
        rel_root = Path(root).relative_to(base_path)
        rel_parts = tuple(part for part in rel_root.parts if part)

        # Handle directories first so we can prune traversal or record symlinks
        for entry in list(dirs):
            dir_parts = rel_parts + (entry,)
            if should_exclude(dir_parts, skip_names, skip_pairs):
                dirs.remove(entry)
                continue

            full_path = Path(root) / entry
            parent_parts = dir_parts[:-1]
            if parent_parts:
                write_dir(zipf, arc_from_parts(prefix, parent_parts))
            else:
                write_dir(zipf, prefix)

            if full_path.is_symlink():
                dirs.remove(entry)
                add_symlink(zipf, full_path, arc_from_parts(prefix, dir_parts))
            else:
                write_dir(zipf, arc_from_parts(prefix, dir_parts))

        for file_name in files:
            file_parts = rel_parts + (file_name,)
            if should_exclude(file_parts, skip_names, skip_pairs):
                continue

            full_file = Path(root) / file_name
            parent_parts = file_parts[:-1]
            if parent_parts:
                write_dir(zipf, arc_from_parts(prefix, parent_parts))
            else:
                write_dir(zipf, prefix)

            arcname = arc_from_parts(prefix, file_parts)
            if full_file.is_symlink():
                add_symlink(zipf, full_file, arcname)
            else:
                zipf.write(full_file, arcname)


with zipfile.ZipFile(out_zip, mode="w", compression=COMPRESSION, allowZip64=True) as zipf:
    if chrome_dir.exists():
        add_tree(zipf, chrome_dir, "chrome", CHROME_SKIP_NAMES, CHROME_SKIP_PAIRS)

    jetbrains_available = False
    if jb_cfg.exists():
        jetbrains_available = True
        add_tree(zipf, jb_cfg, "JetBrains/config", set(), set())

    if jb_share.exists():
        jetbrains_available = True
        add_tree(zipf, jb_share, "JetBrains/share", JB_SHARE_SKIP_NAMES, set())

    if jetbrains_available:
        write_dir(zipf, "JetBrains")

PY

echo ">> Done."
echo "Backup created at: $OUTZIP_ABS"

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
