#!/bin/bash

# Shared utilities for git-sync and git-status scripts
# Source this file: source "$(dirname "$0")/git-sync-utils.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

GIT_SYNC_SETTINGS_FILE=".git-sync-settings.json"
GIT_SYNC_SETTINGS_PATH="${GIT_SYNC_SETTINGS_PATH:-}"

# Find settings file in current dir or parent dirs
# Sets GIT_SYNC_SETTINGS_PATH, returns 1 if not found
gs_find_settings() {
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
        if [ -f "$dir/$GIT_SYNC_SETTINGS_FILE" ]; then
            GIT_SYNC_SETTINGS_PATH="$dir/$GIT_SYNC_SETTINGS_FILE"
            return 0
        fi
        dir=$(dirname "$dir")
    done
    return 1
}

# Check that jq is available
gs_require_jq() {
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}Error: jq is required. Install with: sudo apt install jq${NC}"
        exit 1
    fi
}

# Get number of repos in settings
gs_repo_count() {
    jq '.repos | length' "$GIT_SYNC_SETTINGS_PATH"
}

# Get repo name by index
gs_repo_name() {
    local index="$1"
    jq -r ".repos[$index].name" "$GIT_SYNC_SETTINGS_PATH"
}

# Get all branch names for a repo by index (newline-separated)
gs_repo_branches() {
    local index="$1"
    jq -r ".repos[$index].branches | keys[]" "$GIT_SYNC_SETTINGS_PATH"
}

# Get the directory path for a specific branch in a repo
gs_branch_path() {
    local index="$1"
    local branch="$2"
    jq -r ".repos[$index].branches[\"$branch\"]" "$GIT_SYNC_SETTINGS_PATH"
}

# Get the deploy URL for a repo/branch
gs_deploy_url() {
    local index="$1"
    local branch="$2"
    jq -r ".repos[$index].deploy[\"$branch\"].url // empty" "$GIT_SYNC_SETTINGS_PATH"
}

# Get the jq extraction path for a repo/branch (default: .version)
gs_deploy_jq_path() {
    local index="$1"
    local branch="$2"
    local path
    path=$(jq -r ".repos[$index].deploy[\"$branch\"].jqPath // empty" "$GIT_SYNC_SETTINGS_PATH")
    echo "${path:-.version}"
}

# Get expected version from a repo's package.json
gs_expected_version() {
    local index="$1"
    local branch="$2"
    local branch_path
    branch_path=$(gs_branch_path "$index" "$branch")
    if [ -f "$branch_path/package.json" ]; then
        jq -r '.version' "$branch_path/package.json"
    fi
}

# Get global poll timeout (default: 600)
gs_poll_timeout() {
    local timeout
    timeout=$(jq -r '.deployPoll.timeout // empty' "$GIT_SYNC_SETTINGS_PATH")
    echo "${timeout:-600}"
}

# Get global poll interval (default: 15)
gs_poll_interval() {
    local interval
    interval=$(jq -r '.deployPoll.interval // empty' "$GIT_SYNC_SETTINGS_PATH")
    echo "${interval:-15}"
}

# Poll a deploy URL until the version matches or timeout
# Usage: gs_poll_deploy <url> <jq_path> <expected_version> [timeout] [interval]
# Returns 0 on success, 1 on timeout
gs_poll_deploy() {
    local url="$1"
    local jq_path="$2"
    local expected="$3"
    local timeout="${4:-$(gs_poll_timeout)}"
    local interval="${5:-$(gs_poll_interval)}"
    local elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        local current
        current=$(curl -sf --max-time 10 "$url" 2>/dev/null | jq -r "$jq_path" 2>/dev/null)

        if [ "$current" = "$expected" ]; then
            echo -e "    ${GREEN}✓ v${expected} deployed (${elapsed}s)${NC}"
            return 0
        fi

        local display_current="${current:-unreachable}"
        echo -e "    ⏳ ${elapsed}s - current: v${display_current}"

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    echo -e "    ${RED}✗ Timed out after ${timeout}s (current: v${current:-unreachable}, expected: v${expected})${NC}"
    return 1
}

# Given a directory path, find all branch names for its repo in settings
# Prints newline-separated branch names, or nothing if not found
gs_branches_for_path() {
    local repo_path="$1"
    [ -z "$GIT_SYNC_SETTINGS_PATH" ] && return
    local count
    count=$(gs_repo_count)
    for ((ri=0; ri<count; ri++)); do
        local match
        match=$(jq -r ".repos[$ri].branches | to_entries[] | select(.value == \"$repo_path\") | .key" "$GIT_SYNC_SETTINGS_PATH")
        if [ -n "$match" ]; then
            gs_repo_branches "$ri"
            return
        fi
    done
}
