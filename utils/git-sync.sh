#!/bin/bash

# Git Sync Utility
# Syncs branches across repos defined in .git-sync-settings.json
# Each branch can have its own working directory

SETTINGS_FILE=".git-sync-settings.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Find settings file in current dir or parent dirs
find_settings() {
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
        if [ -f "$dir/$SETTINGS_FILE" ]; then
            echo "$dir/$SETTINGS_FILE"
            return 0
        fi
        dir=$(dirname "$dir")
    done
    return 1
}

SETTINGS_PATH=$(find_settings)

if [ -z "$SETTINGS_PATH" ]; then
    echo -e "${RED}Error: $SETTINGS_FILE not found in current or parent directories${NC}"
    exit 1
fi

echo -e "${BLUE}Using settings: $SETTINGS_PATH${NC}"

# Check for jq
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is required. Install with: sudo apt install jq${NC}"
    exit 1
fi

# Get number of repos
repo_count=$(jq '.repos | length' "$SETTINGS_PATH")

for ((i=0; i<repo_count; i++)); do
    repo_name=$(jq -r ".repos[$i].name" "$SETTINGS_PATH")
    branches=$(jq -r ".repos[$i].branches | keys[]" "$SETTINGS_PATH")

    echo -e "\n${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}  Repository: ${YELLOW}$repo_name${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"

    # Fetch all branches first
    echo -e "${YELLOW}  Fetching remotes...${NC}"
    for branch in $branches; do
        branch_path=$(jq -r ".repos[$i].branches[\"$branch\"]" "$SETTINGS_PATH")
        if [ -e "$branch_path/.git" ]; then
            (cd "$branch_path" && git fetch --all --quiet 2>/dev/null)
            break  # Only need to fetch once per remote
        fi
    done

    # Compare branches using first available repo
    first_path=""
    for branch in $branches; do
        branch_path=$(jq -r ".repos[$i].branches[\"$branch\"]" "$SETTINGS_PATH")
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
    branch_array=($branches)

    for branch in $branches; do
        ahead_counts[$branch]=0
    done

    # Compare each pair of branches
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

    for branch in $branches; do
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

    echo -e "\n  ${YELLOW}Most advanced: $most_advanced (+$max_ahead commits)${NC}"

    # Show what will be merged
    echo -e "\n  ${BLUE}Changes to sync from $most_advanced:${NC}"
    for branch in $branches; do
        if [ "$branch" != "$most_advanced" ]; then
            behind=$(git rev-list --count "origin/$branch..origin/$most_advanced" 2>/dev/null || echo "0")
            if [ "$behind" -gt 0 ]; then
                branch_path=$(jq -r ".repos[$i].branches[\"$branch\"]" "$SETTINGS_PATH")
                echo -e "    → $branch (${behind} commits behind) @ $branch_path"
            fi
        fi
    done

    # Prompt user
    echo ""
    read -p "  Sync $most_advanced to other branches? [y/N] " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        for branch in $branches; do
            if [ "$branch" != "$most_advanced" ]; then
                behind=$(git rev-list --count "origin/$branch..origin/$most_advanced" 2>/dev/null || echo "0")
                if [ "$behind" -gt 0 ]; then
                    branch_path=$(jq -r ".repos[$i].branches[\"$branch\"]" "$SETTINGS_PATH")

                    if [ ! -e "$branch_path/.git" ]; then
                        echo -e "  ${RED}✗ Invalid path for $branch: $branch_path${NC}"
                        continue
                    fi

                    echo -e "  ${YELLOW}Merging $most_advanced → $branch @ $branch_path${NC}"
                    cd "$branch_path" || continue

                    git checkout "$branch" --quiet 2>/dev/null
                    git pull --quiet

                    if git merge "origin/$most_advanced" --no-edit; then
                        git push --quiet
                        echo -e "  ${GREEN}✓ $branch updated${NC}"
                    else
                        echo -e "  ${RED}✗ Merge conflict in $branch - resolve manually${NC}"
                        git merge --abort 2>/dev/null
                    fi
                fi
            fi
        done

        echo -e "  ${GREEN}✓ Sync complete${NC}"
    else
        echo -e "  ${YELLOW}Skipped${NC}"
    fi
done

echo -e "\n${GREEN}Done!${NC}\n"
