#!/bin/bash
set -euo pipefail

# --- Parse args: optional --behind <N>, optional <main_branch> ---
BEHIND_THRESH=""
MAIN_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --behind)
      if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then
        BEHIND_THRESH="$2"
        shift 2
      else
        echo "Usage: $0 [--behind <commits>] [<main-branch>]"
        exit 1
      fi
      ;;
    *)
      if [[ -z "$MAIN_ARG" ]]; then
        MAIN_ARG="$1"
        shift
      else
        echo "Usage: $0 [--behind <commits>] [<main-branch>]"
        exit 1
      fi
      ;;
  esac
done

# --- Determine reference branch (main/dev/develop/master or user-provided) ---
if [[ -n "$MAIN_ARG" ]]; then
  main_branch="$MAIN_ARG"
  if ! git show-ref --verify --quiet "refs/remotes/origin/$main_branch"; then
    echo "Branch '$main_branch' not found on origin. Exiting."
    exit 1
  fi
else
  main_branch=""
  for candidate in dev develop main master; do
    if git show-ref --verify --quiet "refs/remotes/origin/$candidate"; then
      main_branch=$candidate
      break
    fi
  done
  if [[ -z "$main_branch" ]]; then
    echo "No main branch found! Exiting."
    exit 1
  fi
  read -p "Detected '$main_branch' as the reference branch. Is this correct? [yN] " approve
  if [[ ! "$approve" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo "Reference branch: $main_branch"
git fetch --prune

protected_branches="main|master|develop|dev"
protected_regex="^origin/(${protected_branches})$"

# --- Helpers (bash >=4) ---
declare -A BEHIND AHEAD REASON

get_counts() {
  local rb="$1"
  local out behind ahead
  out=$(git rev-list --left-right --count --cherry --no-merges "origin/$main_branch...$rb" 2>/dev/null || echo "")
  behind=$(awk '{print $1}' <<<"$out")
  ahead=$(awk '{print $2}' <<<"$out")
  echo "${behind:-0} ${ahead:-0}"
}

# --- 1) Collect merged-into-main remote branches ---
merged_list=$(
  git branch -r --merged "origin/$main_branch" \
    | grep -vE "origin/(${protected_branches})\$" \
    | grep -v ' -> ' \
    | sed 's#origin/##'
)

# Fill maps for merged branches (also compute behind/ahead for display)
while read -r b; do
  [[ -z "$b" ]] && continue
  read bh ah < <(get_counts "origin/$b")
  BEHIND["$b"]="$bh"
  AHEAD["$b"]="$ah"
  REASON["$b"]="merged"
done <<<"$merged_list"

# --- 2) If requested, collect far-behind remote branches (behind >= N) ---
if [[ -n "$BEHIND_THRESH" ]]; then
  while read -r rb; do
    [[ -z "$rb" ]] && continue
    [[ "$rb" == "origin/HEAD ->"* ]] && continue
    [[ "$rb" =~ $protected_regex ]] && continue
    b="${rb#origin/}"

    read bh ah < <(get_counts "$rb")
    # store counts (also for branches already in maps)
    BEHIND["$b"]="${bh}"
    AHEAD["$b"]="${ah}"

    if (( bh >= BEHIND_THRESH )); then
      if [[ -n "${REASON[$b]:-}" ]]; then
        REASON["$b"]="${REASON[$b]},behind>=${BEHIND_THRESH}"
      else
        REASON["$b"]="behind>=${BEHIND_THRESH}"
      fi
    fi
  done < <(git for-each-ref --format='%(refname:short)' refs/remotes/origin)
fi

# --- 3) Build combined candidate list (remote) ---
candidates=()
for b in "${!REASON[@]}"; do
  candidates+=("$b")
done

# Sort candidates by behind desc (nice UX)
if ((${#candidates[@]} > 0)); then
  IFS=$'\n' candidates=($(for b in "${candidates[@]}"; do
    printf "%s\t%010d\t%010d\t%s\n" "$b" "${BEHIND[$b]:-0}" "${AHEAD[$b]:-0}" "${REASON[$b]}"
  done | sort -k2,2nr | awk -F'\t' '{print $1}'))
fi

# --- 4) Show table & confirm deletion on origin ---
echo
if ((${#candidates[@]} == 0)); then
  if [[ -n "$BEHIND_THRESH" ]]; then
    echo "No remote branches are merged nor ≥ $BEHIND_THRESH behind."
  else
    echo "No remote branches merged into $main_branch to delete."
  fi
else
  echo "Remote branches to delete on origin (merged and/or far-behind):"
  printf "%-45s %8s %8s %s\n" "branch" "behind" "ahead" "reason"
  printf "%-45s %8s %8s %s\n" "---------------------------------------------" "--------" "--------" "-------------------------"
  for b in "${candidates[@]}"; do
    printf "%-45s %8s %8s %s\n" "$b" "${BEHIND[$b]:-0}" "${AHEAD[$b]:-0}" "${REASON[$b]}"
  done

  echo
  read -p "Delete ALL the above branches from origin? [yN] " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    for b in "${candidates[@]}"; do
      echo "Deleting origin/$b ..."
      git push origin --delete "$b" || true
    done
    echo "Remote deletion done."
  else
    echo "Aborted remote deletion."
  fi
fi

# --- 5) Local merged branches cleanup (unchanged) ---
current_branch=$(git symbolic-ref --short HEAD)
local_branches_to_delete=$(git branch --merged "origin/$main_branch" \
  | sed 's/* //' \
  | grep -vE "^\s*(${protected_branches})\s*$" \
  | grep -v "^\s*$current_branch\s*$" \
  | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

echo
if [[ -n "$local_branches_to_delete" ]]; then
  echo "Local branches merged into $main_branch and candidates for local deletion:"
  echo "$local_branches_to_delete"
  echo
  read -p "Delete these local branches? [yN] " answer_local
  if [[ "$answer_local" =~ ^[Yy]$ ]]; then
    while read -r lb; do
      [[ -z "$lb" ]] && continue
      echo "Deleting local branch $lb ..."
      git branch -d "$lb" || true
    done <<<"$local_branches_to_delete"
    echo "Local branch cleanup done."
  else
    echo "Local branch deletion aborted."
  fi
else
  echo "No local merged branches found to delete."
fi

