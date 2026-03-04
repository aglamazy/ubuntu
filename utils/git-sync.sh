#!/bin/bash

# Git Sync Utility
# Syncs branches across repos defined in .git-sync-settings.json
# Each branch can have its own working directory

source "$(dirname "$0")/git-sync-utils.sh"

FILTER_BRANCHES=()
PUSHED_BRANCHES=()
QUIET=false

# Usage
usage() {
    echo "Usage: $(basename "$0") [OPTIONS]"
    echo ""
    echo "Syncs branches across repos defined in $GIT_SYNC_SETTINGS_FILE"
    echo "Each branch can have its own working directory."
    echo ""
    echo "Options:"
    echo "  -b, --branch BRANCH   Only sync the specified branch (can be repeated)"
    echo "  -q, --quiet, -y       Auto-approve syncing from most advanced branch"
    echo "  -h, --help            Show this help message"
    echo ""
    echo "The settings file is searched for in the current directory and"
    echo "parent directories."
    exit 0
}

# Parse arguments
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
        -q|--quiet|-y)
            QUIET=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

gs_find_settings || { echo -e "${RED}Error: $GIT_SYNC_SETTINGS_FILE not found in current or parent directories${NC}"; exit 1; }
gs_require_jq

echo -e "${BLUE}Using settings: $GIT_SYNC_SETTINGS_PATH${NC}"
if [ ${#FILTER_BRANCHES[@]} -gt 0 ]; then
    echo -e "${BLUE}Filtering to branches: ${FILTER_BRANCHES[*]}${NC}"
fi

repo_count=$(gs_repo_count)

for ((i=0; i<repo_count; i++)); do
    repo_name=$(gs_repo_name "$i")
    all_branches=$(gs_repo_branches "$i")

    # Filter branches for pull/push, but keep all_branches for comparison
    if [ ${#FILTER_BRANCHES[@]} -gt 0 ]; then
        sync_branches=""
        for fb in "${FILTER_BRANCHES[@]}"; do
            if echo "$all_branches" | grep -qx "$fb"; then
                sync_branches="${sync_branches:+$sync_branches$'\n'}$fb"
            fi
        done
        if [ -z "$sync_branches" ]; then
            continue  # No matching branches in this repo, skip it
        fi
    else
        sync_branches="$all_branches"
    fi

    echo -e "\n${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}  Repository: ${YELLOW}$repo_name${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"

    # Fetch all branches first
    echo -e "${YELLOW}  Fetching remotes...${NC}"
    for branch in $all_branches; do
        branch_path=$(gs_branch_path "$i" "$branch")
        if [ -e "$branch_path/.git" ]; then
            (cd "$branch_path" && git fetch --all --quiet 2>/dev/null)
            break  # Only need to fetch once per remote
        fi
    done

    # Sync local commits with origin (pull if behind, then push if ahead)
    for branch in $sync_branches; do
        branch_path=$(gs_branch_path "$i" "$branch")
        if [ -e "$branch_path/.git" ]; then
            local_ahead=$(cd "$branch_path" && git rev-list --count "origin/$branch..$branch" 2>/dev/null || echo "0")
            remote_ahead=$(cd "$branch_path" && git rev-list --count "$branch..origin/$branch" 2>/dev/null || echo "0")

            # Pull if remote is ahead
            if [ "$remote_ahead" -gt 0 ]; then
                echo -e "  ${YELLOW}Pulling $remote_ahead commit(s) from origin/$branch...${NC}"
                if (cd "$branch_path" && git pull --rebase --quiet origin "$branch"); then
                    echo -e "  ${GREEN}✓ Pulled from origin/$branch${NC}"
                else
                    echo -e "  ${RED}✗ Failed to pull from origin/$branch${NC}"
                    continue
                fi
            fi

            # Push if local is ahead
            if [ "$local_ahead" -gt 0 ]; then
                echo -e "  ${YELLOW}Pushing $local_ahead local commit(s) to origin/$branch...${NC}"
                if (cd "$branch_path" && git push --quiet origin "$branch"); then
                    echo -e "  ${GREEN}✓ Pushed to origin/$branch${NC}"
                    PUSHED_BRANCHES+=("$branch")
                else
                    echo -e "  ${RED}✗ Failed to push to origin/$branch${NC}"
                fi
            fi
        fi
    done

    # Compare branches using first available repo
    first_path=""
    for branch in $all_branches; do
        branch_path=$(gs_branch_path "$i" "$branch")
        if [ -e "$branch_path/.git" ]; then
            first_path="$branch_path"
            break
        fi
    done

    if [ -z "$first_path" ]; then
        echo -e "${RED}  Error: No valid git repository found${NC}"
        continue
    fi

    cd "$first_path" || continue

    echo -e "\n  ${GREEN}Branch status:${NC}"

    declare -A ahead_counts
    branch_array=($all_branches)

    for branch in $all_branches; do
        ahead_counts[$branch]=0
    done

    # Include unpushed local commits in the count
    for branch in $all_branches; do
        branch_path=$(gs_branch_path "$i" "$branch")
        if [ -e "$branch_path/.git" ]; then
            local_extra=$(cd "$branch_path" && git rev-list --count "origin/$branch..$branch" 2>/dev/null || echo "0")
            ahead_counts[$branch]=$((${ahead_counts[$branch]} + local_extra))
        fi
    done

    # Compare each pair of branches (remote refs)
    for ((j=0; j<${#branch_array[@]}; j++)); do
        for ((k=j+1; k<${#branch_array[@]}; k++)); do
            b1=${branch_array[$j]}
            b2=${branch_array[$k]}

            ahead_1=$(git rev-list --count "origin/$b2..origin/$b1" 2>/dev/null || echo "0")
            ahead_2=$(git rev-list --count "origin/$b1..origin/$b2" 2>/dev/null || echo "0")

            ahead_counts[$b1]=$((${ahead_counts[$b1]} + ahead_1))
            ahead_counts[$b2]=$((${ahead_counts[$b2]} + ahead_2))
        done
    done

    # Find most advanced and display status
    most_advanced=""
    max_ahead=0

    for branch in $all_branches; do
        total_ahead=${ahead_counts[$branch]}
        if [ "$total_ahead" -gt "$max_ahead" ]; then
            max_ahead=$total_ahead
            most_advanced=$branch
        fi
        echo -e "    $branch: ${total_ahead} commits ahead"
    done

    if [ -z "$most_advanced" ] || [ "$max_ahead" -eq 0 ]; then
        echo -e "\n  ${GREEN}✓ All branches are in sync${NC}"
        continue
    fi

    # When a filter is active, filter branches are merge targets — source must be a non-filter branch.
    # If most_advanced is itself a filter branch, find the most advanced non-filter branch instead.
    if [ ${#FILTER_BRANCHES[@]} -gt 0 ]; then
        for fb in "${FILTER_BRANCHES[@]}"; do
            if [ "$fb" = "$most_advanced" ]; then
                most_advanced=""
                max_ahead=0
                for branch in $all_branches; do
                    skip=false
                    for ffb in "${FILTER_BRANCHES[@]}"; do
                        [ "$ffb" = "$branch" ] && skip=true && break
                    done
                    [ "$skip" = true ] && continue
                    total_ahead=${ahead_counts[$branch]}
                    if [ "$total_ahead" -gt "$max_ahead" ]; then
                        max_ahead=$total_ahead
                        most_advanced=$branch
                    fi
                done
                break
            fi
        done
    fi

    if [ -z "$most_advanced" ] || [ "$max_ahead" -eq 0 ]; then
        echo -e "\n  ${GREEN}✓ All branches are in sync${NC}"
        continue
    fi

    echo -e "\n  ${YELLOW}Most advanced: $most_advanced (+$max_ahead commits)${NC}"

    # Determine which branches to merge into
    if [ ${#FILTER_BRANCHES[@]} -gt 0 ]; then
        merge_branches="$sync_branches"
    else
        merge_branches="$all_branches"
    fi

    most_advanced_path=$(gs_branch_path "$i" "$most_advanced")

    # Show what will be merged
    echo -e "\n  ${BLUE}Changes to sync from $most_advanced:${NC}"
    for branch in $merge_branches; do
        if [ "$branch" != "$most_advanced" ]; then
            behind=${ahead_counts[$most_advanced]}
            if [ "$behind" -gt 0 ]; then
                branch_path=$(gs_branch_path "$i" "$branch")
                echo -e "    → $branch @ $branch_path"
            fi
        fi
    done

    # Prompt user (skip in quiet mode)
    if [ "$QUIET" = true ]; then
        REPLY=y
    else
        echo ""
        read -p "  Sync $most_advanced to other branches? [y/N] " -n 1 -r
        echo ""
    fi

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        for branch in $merge_branches; do
            if [ "$branch" != "$most_advanced" ]; then
                branch_path=$(gs_branch_path "$i" "$branch")

                if [ ! -e "$branch_path/.git" ]; then
                    echo -e "  ${RED}✗ Invalid path for $branch: $branch_path${NC}"
                    continue
                fi

                echo -e "  ${YELLOW}Merging $most_advanced → $branch @ $branch_path${NC}"
                cd "$branch_path" || continue

                git checkout "$branch" --quiet 2>/dev/null
                git pull --quiet origin "$branch" 2>/dev/null

                # Merge directly from the local source directory (avoids pushing to origin first)
                if git pull --no-edit "$most_advanced_path" "$most_advanced"; then
                    if git push --quiet origin "$branch"; then
                        PUSHED_BRANCHES+=("$branch")
                    fi
                    echo -e "  ${GREEN}✓ $branch updated and pushed${NC}"
                else
                    echo -e "  ${RED}✗ Merge conflict in $branch - resolve manually${NC}"
                    git merge --abort 2>/dev/null
                fi
            fi
        done

        echo -e "  ${GREEN}✓ Sync complete${NC}"
    else
        echo -e "  ${YELLOW}Skipped${NC}"
    fi
done

# Deduplicate pushed branches
unique_pushed=($(printf '%s\n' "${PUSHED_BRANCHES[@]}" | sort -u))

if [ ${#unique_pushed[@]} -gt 0 ]; then
    echo -e "\n${BLUE}Branches pushed: ${unique_pushed[*]}${NC}"
    if [ "$QUIET" = true ]; then
        REPLY=n
    else
        read -p "  Poll deployments? [y/N] " -n 1 -r
        echo ""
    fi
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        poll_args=()
        for pb in "${unique_pushed[@]}"; do
            poll_args+=(-b "$pb")
        done
        GIT_SYNC_SETTINGS_PATH="$GIT_SYNC_SETTINGS_PATH" "$(dirname "$0")/git-sync-deploy-poll.sh" "${poll_args[@]}"
    fi
fi

echo -e "\n${GREEN}Done!${NC}\n"
