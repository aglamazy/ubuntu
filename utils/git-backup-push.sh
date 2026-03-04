#!/usr/bin/env bash
#
# Push unpushed local branches to origin under a backup prefix.
# This ensures committed work is safely on the remote even if not
# merged or pushed to the real branch yet.
#
# Usage:
#   git-backup-push.sh [-n|--dry-run]
#
# Each unpushed branch "feature-x" in repo "myapp" gets pushed as:
#   origin backup/<hostname>/feature-x
#
# The backup/ prefix avoids triggering CI/CD pipelines.

set -euo pipefail

DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

DEV_ROOT="${HOME}/develop"
BACKUP_PREFIX="backup/$(hostname)"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pushed=0
skipped=0

while IFS= read -r gitdir; do
  repo="${gitdir%/.git}"
  repo_name="${repo#"${DEV_ROOT}/"}"

  # Skip repos without an origin remote
  if ! git -C "$repo" remote | grep -q '^origin$'; then
    continue
  fi

  git -C "$repo" fetch origin --quiet 2>/dev/null || continue

  while IFS= read -r branch; do
    upstream=$(git -C "$repo" rev-parse --abbrev-ref "${branch}@{u}" 2>/dev/null) || upstream=""

    needs_push=false
    if [[ -z "$upstream" ]]; then
      # Local-only branch with no upstream
      needs_push=true
    else
      ahead=$(git -C "$repo" rev-list --count "${upstream}..${branch}" 2>/dev/null) || ahead=0
      if [[ "$ahead" -gt 0 ]]; then
        needs_push=true
      fi
    fi

    if $needs_push; then
      backup_ref="${BACKUP_PREFIX}/${branch}"
      if $DRY_RUN; then
        echo -e "${YELLOW}[dry-run]${NC} ${repo_name}: ${branch} -> origin ${backup_ref}"
      else
        if git -C "$repo" push --force --no-verify origin "${branch}:refs/heads/${backup_ref}" 2>/dev/null; then
          echo -e "${GREEN}pushed${NC}  ${repo_name}: ${branch} -> origin ${backup_ref}"
        else
          echo -e "${YELLOW}failed${NC}  ${repo_name}: ${branch} -> origin ${backup_ref}" >&2
          skipped=$((skipped + 1))
          continue
        fi
      fi
      pushed=$((pushed + 1))
    fi
  done < <(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads/)

done < <(find "$DEV_ROOT" -name .git -type d -print 2>/dev/null)

echo ""
if $DRY_RUN; then
  echo -e "${BLUE}Dry run: ${pushed} branch(es) would be pushed${NC}"
else
  echo -e "${BLUE}Done: ${pushed} branch(es) pushed, ${skipped} failed${NC}"
fi

# Ping healthchecks.io on success (if no failures)
if [[ "$skipped" -eq 0 ]] && ! $DRY_RUN; then
  curl -fsS -m 10 --retry 5 https://hc-ping.com/60bf2edb-c00a-4335-bdf9-4b2da39db758 >/dev/null 2>&1 || true
fi
