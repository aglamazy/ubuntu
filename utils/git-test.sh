#!/bin/bash

set -e
if ! git diff-index --quiet HEAD --; then
  echo "Working directory is not clean! Commit or stash your changes before running this script."
  exit 1
fi

start_branch=$(git rev-parse --abbrev-ref HEAD)
main_branch=main 

# Step 1: fetch and capture output

# Step 2: parse new branches from fetch output
# Lines that look like:   * [new branch]      feature/xyz   -> origin/feature/xyz
branches_to_test=$(git branch -r --no-merged origin/$main_branch | grep -v "origin/$main_branch" | sed 's/origin\///')


if [[ -z "$branches_to_test" ]]; then
  echo "No new branches to test."
  exit 0
fi

for branch in $branches_to_test; do
  echo
  echo "====="
  echo "Testing new branch: $branch"
  echo "====="

  git checkout "$branch"

  echo "You are now on branch $branch."
  echo "Please test/fix as needed."
  read -p "Merge $branch into $main_branch? [yN] " answer

  if [[ "$answer" =~ ^[Yy]$ ]]; then
    git checkout "$main_branch"
    git merge "$branch"
    echo "$branch merged into $main_branch."
  else
    echo "Skipped merging $branch."
  fi
done

git checkout "$start_branch"
echo "Done! Returned to $start_branch."

