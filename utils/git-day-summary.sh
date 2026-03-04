#!/bin/bash

# Git Daily Summary - Shows commits and estimates working hours

show_help() {
    echo "Usage: git-day-summary.sh [OPTIONS] [YYYY-MM-DD] [repo_path1] [repo_path2] ..."
    echo ""
    echo "Shows git commits for a specific day and estimates working hours."
    echo ""
    echo "Arguments:"
    echo "  YYYY-MM-DD    Date to check (default: yesterday)"
    echo "  repo_path     One or more git repository paths (default: current dir)"
    echo "                If path contains multiple repos, they are auto-discovered"
    echo ""
    echo "Options:"
    echo "  -h, --help        Show this help message"
    echo "  -a, --author NAME Filter by author (default: git config user.name)"
    echo "  --all             Show commits from all authors"
    echo "  -m, --month       Show monthly calendar view (YYYY-MM or YYYY-MM-DD)"
    echo "  -w, --week        Show full work week (Sun-Thu) containing the given date"
    echo "  --digest          AI digest: 3-5 bullets on biggest investments (requires claude)"
    echo ""
    echo "Examples:"
    echo "  git-day-summary.sh                              # Yesterday, current repo"
    echo "  git-day-summary.sh 2025-12-14                   # Specific date"
    echo "  git-day-summary.sh 2025-12-14 ~/projects        # Auto-find repos in folder"
    echo "  git-day-summary.sh --all 2025-12-14 ~/projects  # All authors"
    echo "  git-day-summary.sh -a \"John\" 2025-12-14         # Specific author"
    echo "  git-day-summary.sh -m 2025-12 ~/projects        # Monthly calendar view"
    echo "  git-day-summary.sh -w 2026-02-17 ~/projects     # Full work week"
    echo "  git-day-summary.sh -w --digest 2026-02-17 ~/p   # Week + AI summary"
    exit 0
}

# Parse options
AUTHOR=""
ALL_AUTHORS=false
MONTH_VIEW=false
WEEK_VIEW=false
DIGEST=false
DATE=""
INPUT_PATHS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            ;;
        -a|--author)
            AUTHOR="$2"
            shift 2
            ;;
        --all)
            ALL_AUTHORS=true
            shift
            ;;
        -m|--month)
            MONTH_VIEW=true
            shift
            ;;
        -w|--week)
            WEEK_VIEW=true
            shift
            ;;
        --digest)
            DIGEST=true
            shift
            ;;
        -*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            # First non-option is date, rest are paths
            if [ -z "$DATE" ]; then
                DATE="$1"
            else
                INPUT_PATHS+=("$1")
            fi
            shift
            ;;
    esac
done

# Set default date
if [ -z "$DATE" ]; then
    if [ "$MONTH_VIEW" = true ]; then
        DATE=$(date +%Y-%m)
    else
        DATE=$(date -d 'yesterday' +%Y-%m-%d)
    fi
fi

if [ ${#INPUT_PATHS[@]} -eq 0 ]; then
    INPUT_PATHS=(".")
fi

# Get author from git config if not specified
if [ -z "$AUTHOR" ] && [ "$ALL_AUTHORS" = false ]; then
    AUTHOR=$(git config user.name)
fi

NEXT_DATE=$(date -d "$DATE + 1 day" +%Y-%m-%d)

# Find all git repos (direct or nested)
REPOS=()
for PATH_ARG in "${INPUT_PATHS[@]}"; do
    if [ -d "$PATH_ARG/.git" ]; then
        REPOS+=("$PATH_ARG")
    elif [ -d "$PATH_ARG" ]; then
        while IFS= read -r repo; do
            REPOS+=("${repo%/.git}")
        done < <(find "$PATH_ARG" -maxdepth 2 -type d -name ".git" -not -path "*/node_modules/*" 2>/dev/null)
    fi
done

if [ ${#REPOS[@]} -eq 0 ]; then
    echo "No git repositories found"
    exit 1
fi

# Week view (Sun-Thu work week)
if [ "$WEEK_VIEW" = true ]; then
    # Find Sunday of the week containing DATE
    DOW=$(date -d "$DATE" +%w)  # 0=Sun, 6=Sat
    WEEK_START=$(date -d "$DATE - $DOW days" +%Y-%m-%d)

    # Build args to pass through
    PASS_ARGS=()
    if [ "$ALL_AUTHORS" = true ]; then PASS_ARGS+=(--all); fi
    if [ -n "$AUTHOR" ]; then PASS_ARGS+=(-a "$AUTHOR"); fi

    WEEK_OUTPUT=""
    TOTAL_COMMITS=0

    # Sun(0) through Thu(4)
    for ((i=0; i<=4; i++)); do
        DAY_DATE=$(date -d "$WEEK_START + $i days" +%Y-%m-%d)
        DAY_NAME=$(date -d "$DAY_DATE" +"%A")
        DAY_OUTPUT=$("$0" "${PASS_ARGS[@]}" "$DAY_DATE" "${INPUT_PATHS[@]}")
        DAY_COMMITS=$(echo "$DAY_OUTPUT" | grep "^Commits:" | awk '{print $2}')
        TOTAL_COMMITS=$((TOTAL_COMMITS + ${DAY_COMMITS:-0}))
        WEEK_OUTPUT+="$DAY_OUTPUT"$'\n\n'
    done

    WEEK_END=$(date -d "$WEEK_START + 4 days" +%Y-%m-%d)
    echo "===== Week Summary: $WEEK_START → $WEEK_END ====="
    echo "Total commits: $TOTAL_COMMITS"
    echo ""
    echo "$WEEK_OUTPUT"

    # Digest via Claude Code
    if [ "$DIGEST" = true ]; then
        if command -v claude &>/dev/null; then
            echo "--- AI Digest ---"
            echo "$WEEK_OUTPUT" | claude -p \
                "Here is a week of git commit summaries. Give me 3-5 concise bullets summarizing the biggest investments / areas of work this week. Focus on themes not individual commits. Be brief. Output in Hebrew. Use WhatsApp formatting: *bold* for emphasis. Output bullets only (use •), no intro, no markdown." \
                --output-format text
        else
            echo "(--digest skipped: 'claude' CLI not found in PATH)"
        fi
    fi

    exit 0
fi

# Monthly calendar view
if [ "$MONTH_VIEW" = true ]; then
    # Extract year-month from date (handle both YYYY-MM and YYYY-MM-DD)
    YEAR_MONTH=$(echo "$DATE" | cut -d'-' -f1-2)
    YEAR=$(echo "$YEAR_MONTH" | cut -d'-' -f1)
    MONTH=$(echo "$YEAR_MONTH" | cut -d'-' -f2)

    # Get month name
    MONTH_NAME=$(date -d "${YEAR}-${MONTH}-01" +"%B %Y")

    echo "=== Git Activity Calendar: $MONTH_NAME ==="
    if [ "$ALL_AUTHORS" = true ]; then
        echo "Author: ALL"
    else
        echo "Author: ${AUTHOR:-$(git config user.name)}"
    fi
    echo ""

    # Calendar header
    echo " Sun Mon Tue Wed Thu Fri Sat"

    # Get first day of month and number of days
    FIRST_DAY=$(date -d "${YEAR}-${MONTH}-01" +%Y-%m-%d)
    LAST_DAY=$(date -d "${YEAR}-${MONTH}-01 +1 month -1 day" +%Y-%m-%d)
    NUM_DAYS=$(date -d "$LAST_DAY" +%d)

    # Get day of week for first day (0=Sunday, 6=Saturday)
    FIRST_DOW=$(date -d "$FIRST_DAY" +%w)

    # Build calendar grid
    CALENDAR=""

    # Add leading spaces for first week
    for ((i=0; i<FIRST_DOW; i++)); do
        CALENDAR+="    "
    done

    # For each day in the month, check if there are commits
    for ((day=1; day<=NUM_DAYS; day++)); do
        CHECK_DATE=$(printf "%s-%02d-%02d" "$YEAR" "$MONTH" "$day")
        NEXT_CHECK=$(date -d "$CHECK_DATE + 1 day" +%Y-%m-%d)

        # Check all repos for commits on this day
        HAS_COMMITS=false
        for REPO in "${REPOS[@]}"; do
            if [ "$ALL_AUTHORS" = true ]; then
                COMMITS=$(cd "$REPO" && git log --after="${CHECK_DATE}T00:00:00" --before="${NEXT_CHECK}T00:00:00" \
                    --oneline --all 2>/dev/null)
            else
                COMMITS=$(cd "$REPO" && git log --after="${CHECK_DATE}T00:00:00" --before="${NEXT_CHECK}T00:00:00" \
                    --author="${AUTHOR:-$(git config user.name)}" --oneline --all 2>/dev/null)
            fi

            if [ -n "$COMMITS" ]; then
                HAS_COMMITS=true
                break
            fi
        done

        # Add day to calendar with + or space
        if [ "$HAS_COMMITS" = true ]; then
            CALENDAR+=$(printf " %2d+" "$day")
        else
            CALENDAR+=$(printf " %2d " "$day")
        fi

        # Add newline after Saturday
        DOW=$(date -d "$CHECK_DATE" +%w)
        if [ "$DOW" -eq 6 ]; then
            CALENDAR+=$'\n'
        fi
    done

    echo "$CALENDAR"
    echo ""
    echo "Legend: + = commits on that day"
    exit 0
fi

echo "=== Git Summary for $DATE ==="
if [ "$ALL_AUTHORS" = true ]; then
    echo "Author: ALL"
else
    echo "Author: $AUTHOR"
fi
echo ""

# Collect all commits from all repos
ALL_COMMITS=""
for REPO in "${REPOS[@]}"; do
    REPO_NAME=$(basename "$(cd "$REPO" && pwd)")

    if [ "$ALL_AUTHORS" = true ]; then
        COMMITS=$(cd "$REPO" && git log --after="${DATE}T00:00:00" --before="${NEXT_DATE}T00:00:00" \
            --format="%ai | [$REPO_NAME] %s" --all 2>/dev/null)
    else
        COMMITS=$(cd "$REPO" && git log --after="${DATE}T00:00:00" --before="${NEXT_DATE}T00:00:00" \
            --author="$AUTHOR" --format="%ai | [$REPO_NAME] %s" --all 2>/dev/null)
    fi

    if [ -n "$COMMITS" ]; then
        ALL_COMMITS+="$COMMITS"$'\n'
    fi
done

if [ -z "$(echo "$ALL_COMMITS" | tr -d '[:space:]')" ]; then
    echo "No commits found"
    exit 0
fi

# Sort chronologically (ascending) and display
echo "$ALL_COMMITS" | grep -v '^$' | sort | while read line; do
    TIME=$(echo "$line" | awk '{print $2}' | cut -d':' -f1-2)
    MSG=$(echo "$line" | cut -d'|' -f2-)
    echo "$TIME -$MSG"
done

# Calculate time span
TIMES=$(echo "$ALL_COMMITS" | grep -v '^$' | awk '{print $2}' | sort)
FIRST=$(echo "$TIMES" | head -1)
LAST=$(echo "$TIMES" | tail -1)

if [ -n "$FIRST" ] && [ -n "$LAST" ]; then
    FIRST_SEC=$(date -d "$FIRST" +%s 2>/dev/null)
    LAST_SEC=$(date -d "$LAST" +%s 2>/dev/null)
    if [ -n "$FIRST_SEC" ] && [ -n "$LAST_SEC" ]; then
        DIFF=$((LAST_SEC - FIRST_SEC))
        HOURS=$((DIFF / 3600))
        MINS=$(((DIFF % 3600) / 60))
        echo ""
        echo "Time span: $FIRST → $LAST (~${HOURS}h ${MINS}m)"
    fi
fi

COUNT=$(echo "$ALL_COMMITS" | grep -v '^$' | wc -l)
echo "Commits: $COUNT"
