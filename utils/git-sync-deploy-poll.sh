#!/bin/bash

# Git Sync Deploy Poll
# Polls deployment URLs to verify that the expected version is live.
# Can be run standalone or called from git-sync.sh after pushes.

source "$(dirname "$0")/git-sync-utils.sh"

FILTER_BRANCHES=()

usage() {
    echo "Usage: $(basename "$0") [OPTIONS]"
    echo ""
    echo "Polls deployment URLs to verify expected versions are live."
    echo "Uses deploy config from $GIT_SYNC_SETTINGS_FILE."
    echo ""
    echo "Options:"
    echo "  -b, --branch BRANCH   Only poll the specified branch (can be repeated)"
    echo "  -h, --help            Show this help message"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            ;;
        -b|--branch)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Error: --branch requires an argument"
                exit 1
            fi
            FILTER_BRANCHES+=("$2")
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

if [ -z "$GIT_SYNC_SETTINGS_PATH" ] || [ ! -f "$GIT_SYNC_SETTINGS_PATH" ]; then
    gs_find_settings || { echo -e "${RED}Error: $GIT_SYNC_SETTINGS_FILE not found in current or parent directories${NC}"; exit 1; }
fi
gs_require_jq

echo -e "\n${BLUE}Polling deployments...${NC}"

repo_count=$(gs_repo_count)
any_polled=false
any_failed=false

for ((i=0; i<repo_count; i++)); do
    repo_name=$(gs_repo_name "$i")
    all_branches=$(gs_repo_branches "$i")

    if [ ${#FILTER_BRANCHES[@]} -gt 0 ]; then
        poll_branches=""
        for fb in "${FILTER_BRANCHES[@]}"; do
            if echo "$all_branches" | grep -qx "$fb"; then
                poll_branches="${poll_branches:+$poll_branches$'\n'}$fb"
            fi
        done
        if [ -z "$poll_branches" ]; then
            continue
        fi
    else
        poll_branches="$all_branches"
    fi

    for branch in $poll_branches; do
        deploy_url=$(gs_deploy_url "$i" "$branch")
        if [ -z "$deploy_url" ]; then
            continue
        fi

        jq_path=$(gs_deploy_jq_path "$i" "$branch")
        expected=$(gs_expected_version "$i" "$branch")

        if [ -z "$expected" ]; then
            echo -e "\n  ${YELLOW}${repo_name} (${branch}): no package.json found, skipping${NC}"
            continue
        fi

        any_polled=true
        echo -e "\n  ${BLUE}${repo_name} (${branch}):${NC} waiting for v${expected} at ${deploy_url}"

        if ! gs_poll_deploy "$deploy_url" "$jq_path" "$expected"; then
            any_failed=true
        fi
    done
done

if [ "$any_polled" = false ]; then
    echo -e "\n  ${YELLOW}No deployments configured for the selected branches.${NC}"
fi

echo ""

if [ "$any_failed" = true ]; then
    exit 1
fi
