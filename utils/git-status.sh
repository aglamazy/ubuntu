#!/bin/bash

# Script to show git status for all git repositories in subdirectories
# Usage: ./git-status.sh [--push|-p] [--branch|-b <branch>] [--prod|-bp] [--dev|-bd] [--stg|-bs] [directory]
# If no directory specified, uses current directory

PUSH_TO_ORIGIN=false
CHECKOUT_BRANCH=""
TARGET_DIR="."

while [ "$#" -gt 0 ]; do
    case "$1" in
        -p|--push)
            PUSH_TO_ORIGIN=true
            shift
            ;;
        -b|--branch)
            CHECKOUT_BRANCH="$2"
            shift 2
            ;;
        -bp|--prod)
            CHECKOUT_BRANCH="prod"
            shift
            ;;
        -bd|--dev)
            CHECKOUT_BRANCH="dev"
            shift
            ;;
        -bs|--stg)
            CHECKOUT_BRANCH="stg"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--push|-p] [--branch|-b <branch>] [--prod|-bp] [--dev|-bd] [--stg|-bs] [directory]"
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Unknown option: $1"
            echo "Usage: $0 [--push|-p] [--branch|-b <branch>] [--prod|-bp] [--dev|-bd] [--stg|-bs] [directory]"
            exit 1
            ;;
        *)
            TARGET_DIR="$1"
            shift
            ;;
    esac
done

# Convert to absolute path
TARGET_DIR=$(cd "$TARGET_DIR" && pwd)

# Find all directories and files named .git (to support both regular repos and worktrees)
find "$TARGET_DIR" -name ".git" \( -type d -o -type f \) 2>/dev/null | while read -r git_path; do
    # Get the repository directory (parent of .git)
    repo_dir=$(dirname "$git_path")

    # Get just the directory name
    dirname=$(basename "$repo_dir")

    # Print header
    echo ""
    echo "--- $dirname ---"

    # Change to repository directory and show status
    (
        cd "$repo_dir" || exit

        if [ -n "$CHECKOUT_BRANCH" ]; then
            if git show-ref --verify --quiet "refs/heads/$CHECKOUT_BRANCH"; then
                git checkout "$CHECKOUT_BRANCH"
            elif git show-ref --verify --quiet "refs/remotes/origin/$CHECKOUT_BRANCH"; then
                git checkout -b "$CHECKOUT_BRANCH" "origin/$CHECKOUT_BRANCH"
            else
                echo "Skip checkout: branch $CHECKOUT_BRANCH not found"
            fi
        fi

        # Show branch and ahead/behind info first
        branch=$(git branch --show-current 2>/dev/null)
        display_branch="$branch"
        commit=""
        if [ -z "$branch" ]; then
            commit=$(git rev-parse --short HEAD 2>/dev/null)
            display_branch="(detached at $commit)"
        fi

        echo "Branch: $display_branch"
        ahead=0
        behind=0

        if [ -n "$branch" ]; then
            ahead_behind=$(git rev-list --left-right --count origin/"$branch"..."$branch" 2>/dev/null)
            if [ -n "$ahead_behind" ]; then
                behind=$(echo "$ahead_behind" | awk '{print $1}')
                ahead=$(echo "$ahead_behind" | awk '{print $2}')

                if [ "$ahead" -gt 0 ]; then
                    echo "⚠️  PUSH NEEDED: $ahead commit(s) ahead of origin/$branch"
                fi
                if [ "$behind" -gt 0 ]; then
                    echo "⬇️  PULL NEEDED: $behind commit(s) behind origin/$branch"
                fi
            fi
        fi

        # Show uncommitted changes
        status_output=$(git status -s)
        if [ -n "$status_output" ]; then
            echo "Uncommitted changes:"
            echo "$status_output"
        fi

        # Show clean status only if everything is clean
        if [ -z "$status_output" ] && [ "$ahead" -eq 0 ] && [ "$behind" -eq 0 ]; then
            if [ -n "$branch" ]; then
                echo "✓ Clean (up to date with origin/$branch)"
            else
                echo "✓ Clean $display_branch"
            fi
        fi

        if [ "$PUSH_TO_ORIGIN" = true ]; then
            if [ -z "$branch" ]; then
                echo "Skip push: $display_branch"
            elif git remote get-url origin >/dev/null 2>&1; then
                echo "Pushing origin/$branch..."
                git push origin "$branch"
            else
                echo "Skip push: no origin remote"
            fi
        fi
    )
done

echo ""
