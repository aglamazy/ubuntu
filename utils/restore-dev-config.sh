#!/usr/bin/env bash
set -euo pipefail

# Restore JetBrains configs and Chrome/Chromium profiles from a backup ZIP
# produced by backup-dev-config.sh. Intended for fresh machines where existing
# directories can be replaced entirely.
#
# Usage:
#   ./restore-dev-config.sh /path/to/dev-configs.zip
#   ./restore-dev-config.sh --chromium /path/to/dev-configs.zip
#   ./restore-dev-config.sh --chrome-dir /custom/path /path/to/dev-configs.zip
#
# Notes:
# - Expects the archive to contain `chrome/` and optional `JetBrains/` folders
#   matching the layout produced by the backup script.
# - Existing Chrome and JetBrains config directories will be removed before
#   files are restored.

CHROME_DIR_DEFAULT="$HOME/.config/google-chrome"
CHROMIUM_DIR_DEFAULT="$HOME/.config/chromium"
USE_CHROMIUM=false
CUSTOM_CHROME_DIR=""
ZIP_PATH=""

usage() {
  grep '^# ' "$0" | sed 's/^# //'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chromium)
      USE_CHROMIUM=true
      shift
      ;;
    --chrome-dir)
      CUSTOM_CHROME_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      ZIP_PATH="$1"
      shift
      ;;
  esac
done

if [[ -z "$ZIP_PATH" ]]; then
  echo "Missing ZIP path. See --help for usage." >&2
  exit 1
fi

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "Backup ZIP not found: $ZIP_PATH" >&2
  exit 2
fi

if [[ -n "$CUSTOM_CHROME_DIR" ]]; then
  CHROME_DIR="$CUSTOM_CHROME_DIR"
elif $USE_CHROMIUM; then
  CHROME_DIR="$CHROMIUM_DIR_DEFAULT"
else
  CHROME_DIR="$CHROME_DIR_DEFAULT"
fi

JB_CFG="$HOME/.config/JetBrains"
JB_SHARE="$HOME/.local/share/JetBrains"

echo ">> Restoring from: $ZIP_PATH"
echo ">> Chrome target:  $CHROME_DIR"
echo ">> JetBrains cfg:  $JB_CFG"
echo ">> JetBrains data: $JB_SHARE"

python3 - <<'PY' "$ZIP_PATH" "$CHROME_DIR" "$JB_CFG" "$JB_SHARE"
from __future__ import annotations

import os
import shutil
import stat
import sys
import zipfile
from pathlib import Path
from typing import Iterable, Tuple

zip_path = Path(sys.argv[1])
chrome_dir = Path(sys.argv[2])
jb_cfg_dir = Path(sys.argv[3])
jb_share_dir = Path(sys.argv[4])


def contains_prefix(zf: zipfile.ZipFile, prefix: str) -> bool:
    normalized = prefix.rstrip("/") + "/"
    return any(name.startswith(normalized) for name in zf.namelist())


def ensure_clean_dir(path: Path) -> None:
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)


def resolve_target(root: Path, relative_parts: Iterable[str]) -> Path:
    if not relative_parts:
        raise ValueError("Relative path expected")

    rel_path = Path()
    for part in relative_parts:
        if part in {"", ".", ".."}:
            raise ValueError(f"Unsafe path component '{part}' in archive entry")
        rel_path = rel_path / part

    if rel_path.is_absolute():
        raise ValueError("Archive entry uses an absolute path")

    target = root.joinpath(rel_path)
    try:
        target.relative_to(root)
    except ValueError as exc:
        raise ValueError("Archive entry escapes destination directory") from exc
    return target


def extract_entry(zf: zipfile.ZipFile, info: zipfile.ZipInfo, root: Path, prefix: str) -> None:
    rel_path = info.filename[len(prefix) :]
    if not rel_path:
        return
    parts = tuple(Path(rel_path).parts)
    target = resolve_target(root, parts)

    if info.is_dir():
        target.mkdir(parents=True, exist_ok=True)
        return

    mode = (info.external_attr >> 16) & 0xFFFF
    file_type = stat.S_IFMT(mode)

    target.parent.mkdir(parents=True, exist_ok=True)

    if file_type == stat.S_IFLNK:
        if target.exists() or target.is_symlink():
            try:
                target.unlink()
            except FileNotFoundError:
                pass
        data = zf.read(info)
        link_target = data.decode("utf-8")
        os.symlink(link_target, target)
        return

    with zf.open(info) as source, open(target, "wb") as dest:
        shutil.copyfileobj(source, dest)

    if mode & 0o777:
        os.chmod(target, mode & 0o777)


def restore_group(
    zf: zipfile.ZipFile,
    prefix: str,
    destination: Path,
) -> None:
    ensure_clean_dir(destination)
    for info in zf.infolist():
        if not info.filename.startswith(prefix):
            continue
        extract_entry(zf, info, destination, prefix)


try:
    with zipfile.ZipFile(zip_path) as zf:
        has_chrome = contains_prefix(zf, "chrome")
        has_jb_config = contains_prefix(zf, "JetBrains/config")
        has_jb_share = contains_prefix(zf, "JetBrains/share")

        if not any([has_chrome, has_jb_config, has_jb_share]):
            raise ValueError("Archive does not contain chrome/ or JetBrains/ data")

        if has_chrome:
            print(f"  - Restoring Chrome profile into {chrome_dir}")
            restore_group(zf, "chrome/", chrome_dir)

        if has_jb_config:
            print(f"  - Restoring JetBrains config into {jb_cfg_dir}")
            restore_group(zf, "JetBrains/config/", jb_cfg_dir)

        if has_jb_share:
            print(f"  - Restoring JetBrains shared data into {jb_share_dir}")
            restore_group(zf, "JetBrains/share/", jb_share_dir)

    print(">> Restore complete. Restart Chrome/JetBrains before using the restored profiles.")
except FileNotFoundError as exc:
    sys.exit(f"Missing required path: {exc}")
except (zipfile.BadZipFile, ValueError) as exc:
    sys.exit(f"Restore failed: {exc}")
PY
