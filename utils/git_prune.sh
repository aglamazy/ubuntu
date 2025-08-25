#!/bin/bash

set -e

if [[ -n "$1" ]]; then
  main_branch="$1"
  if ! git show-ref --verify --quiet refs/remotes/origin/$main_branch; then
    echo "Branch '$main_branch' not found on origin. Exiting."
    exit 1
  fi
else
  main_branch=""
  for candidate in dev develop main master; do
    if git show-ref --verify --quiet refs/remotes/origin/$candidate; then
      main_branch=$candidate
      break
    fi
  done

  if [[ -z "$main_branch" ]]; then
    echo "No main branch found! Exiting."
    exit 1
  fi

  # Ask for user approval of detected reference branch
  read -p "Detected '$main_branch' as the reference branch. Is this correct? [yN] " approve
  if [[ ! "$approve" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo "Reference branch: $main_branch"

git fetch --prune

protected_branches="main|master|develop|dev"
branches_to_delete=$(git branch -r --merged origin/$main_branch \
  | grep -vE "origin/($protected_branches)\$" \
  | grep -v " -> " \
  | sed 's#origin/##')

if [[ -z "$branches_to_delete" ]]; then
  echo "No merged branches found to delete."
  exit 0
fi

echo "Branches merged into $main_branch and candidates for deletion:"
echo "$branches_to_delete"
echo

read -p "Delete these branches on origin? [yN] " answer
if [[ "$answer" =~ ^[Yy]$ ]]; then
  for branch in $branches_to_delete; do
    echo "Deleting $branch from origin..."
    git push origin --delete "$branch"
  done
  echo "Done."
else
  echo "Aborted."
fi

# Handle local branches
current_branch=$(git symbolic-ref --short HEAD)
local_branches_to_delete=$(git branch --merged origin/$main_branch \
  | sed 's/* //' \
  | grep -vE "^\s*($protected_branches)\s*$" \
  | grep -v "^\s*$current_branch\s*$" \
  | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

if [[ -n "$local_branches_to_delete" ]]; then
  echo "Local branches merged into $main_branch and candidates for local deletion:"
  echo "$local_branches_to_delete"
  echo
  read -p "Delete these local branches? [yN] " answer_local
  if [[ "$answer_local" =~ ^[Yy]$ ]]; then
    for branch in $local_branches_to_delete; do
      echo "Deleting local branch $branch..."
      git branch -d "$branch"
    done
    echo "Local branch cleanup done."
  else
    echo "Local branch deletion aborted."
  fi
else
  echo "No local merged branches found to delete."
fi

