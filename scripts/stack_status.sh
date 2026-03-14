#!/usr/bin/env bash
#
# HAF Stack Status Report
#
# Reports the health and block progress of a running HAF API node stack.
# Queries hived and apps via SQL for accurate block numbers.
# Stores state between runs to calculate block/sec progression rates.
#
# Usage:
#   # Local (run on the server hosting the stack)
#   ./scripts/stack_status.sh /haf-pool/syncad/haf_api_node_irrev
#
#   # Remote via SSH
#   ./scripts/stack_status.sh --host steem-20 /haf-pool/syncad/haf_api_node_irrev
#
#   # Custom state file location
#   ./scripts/stack_status.sh --state /tmp/my-state.json /haf-pool/syncad/haf_api_node_irrev

set -euo pipefail

# --- Argument parsing ---

HOST=""
STATE_FILE=""
STACK_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --state) STATE_FILE="$2"; shift 2 ;;
        -h|--help) sed -n '2,/^$/s/^# \?//p' "$0"; exit 0 ;;
        *) STACK_DIR="$1"; shift ;;
    esac
done

if [ -z "$STACK_DIR" ]; then
    echo "Usage: $0 [--host <ssh-host>] [--state <file>] <stack_dir>" >&2
    exit 1
fi

STATE_FILE="${STATE_FILE:-/tmp/haf-monitor-$(echo "$STACK_DIR" | tr / _).state}"
NOW=$(date +%s)

# --- Remote execution helper ---
# Runs a command locally or on the remote host

run() {
    if [ -n "$HOST" ]; then
        ssh -o ConnectTimeout=5 "$HOST" "$@"
    else
        eval "$@"
    fi
}

# --- Helpers ---

fmt_duration() {
    local secs=$1
    if (( secs < 0 )); then secs=$((-secs)); fi
    if (( secs >= 86400 )); then
        echo "$((secs/86400))d $((secs%86400/3600))h $((secs%3600/60))m"
    elif (( secs >= 3600 )); then
        echo "$((secs/3600))h $((secs%3600/60))m"
    elif (( secs >= 60 )); then
        echo "$((secs/60))m $((secs%60))s"
    else
        echo "${secs}s"
    fi
}

fmt_number() {
    printf "%'d" "$1" 2>/dev/null || echo "$1"
}

# --- Discover the stack ---

DISPLAY_HOST="${HOST:-$(hostname -s)}"

# Find the compose project name from a running container
PROJECT=$(run "docker ps --filter 'label=com.docker.compose.project.working_dir=$STACK_DIR' --format '{{.Names}}' | head -1 | xargs -r docker inspect --format '{{index .Config.Labels \"com.docker.compose.project\"}}'" 2>/dev/null) || true

if [ -z "$PROJECT" ]; then
    echo "[$DISPLAY_HOST] ERROR: No running stack found at $STACK_DIR"
    exit 1
fi

# Find the haf container name
HAF_CONTAINER="${PROJECT}-haf-1"

# Get stack start time (earliest container start in the project)
STACK_STARTED=$(run "docker ps --filter 'label=com.docker.compose.project=$PROJECT' --format '{{.Names}}' | xargs -r docker inspect --format '{{.State.StartedAt}}' | sort | head -1" 2>/dev/null) || true
STACK_START_DISPLAY=""
STACK_DURATION=""
if [ -n "$STACK_STARTED" ]; then
    STACK_START_EPOCH=$(date -d "$STACK_STARTED" +%s 2>/dev/null) || true
    if [ -n "$STACK_START_EPOCH" ]; then
        STACK_START_DISPLAY=$(date -d "$STACK_STARTED" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null) || true
        STACK_DURATION=$(fmt_duration $((NOW - STACK_START_EPOCH)))
    fi
fi

echo "========================================"
echo "  HAF Stack Status: $DISPLAY_HOST / $PROJECT"
echo "  Stack dir: $STACK_DIR"
echo "  Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"
if [ -n "$STACK_START_DISPLAY" ]; then
    echo "  Started: $STACK_START_DISPLAY ($STACK_DURATION ago)"
fi
echo "========================================"
echo ""

# --- Load previous state ---

declare -A PREV_BLOCKS
PREV_TIME=0
if [ -f "$STATE_FILE" ]; then
    PREV_TIME=$(head -1 "$STATE_FILE")
    while IFS='=' read -r key val; do
        [ -n "$key" ] && PREV_BLOCKS["$key"]="$val"
    done < <(tail -n +2 "$STATE_FILE")
fi
ELAPSED=$((NOW - PREV_TIME))

# Start new state file
echo "$NOW" > "$STATE_FILE.tmp"

# --- Helper: show progress ---

show_progress() {
    local app=$1
    local block=$2
    if [ -n "${PREV_BLOCKS[$app]:-}" ] && [ "$ELAPSED" -gt 60 ]; then
        local delta=$((block - PREV_BLOCKS[$app]))
        local rate
        rate=$(echo "scale=1; $delta * 3600 / $ELAPSED" | bc 2>/dev/null || echo "?")
        if [ "$delta" -eq 0 ]; then
            echo "    Progress:  *** NO PROGRESS in $(fmt_duration $ELAPSED) ***"
        elif [ "$delta" -gt 0 ]; then
            echo "    Progress:  +$(fmt_number $delta) blocks in $(fmt_duration $ELAPSED) (~$(fmt_number "${rate%.*}") blocks/hr)"
        else
            echo "    Progress:  $(fmt_number $delta) blocks in $(fmt_duration $ELAPSED) (REGRESSED)"
        fi
    fi
}

# --- Container status helper ---

show_container_status() {
    local container=$1
    local status uptime_secs
    status=$(run "docker ps --filter 'name=^${container}$' --format '{{.Status}}'" 2>/dev/null) || true
    if [ -z "$status" ]; then
        echo "    Status:    NOT RUNNING"
        return 1
    fi
    echo "    Status:    $status"

    # Calculate uptime
    local started
    started=$(run "docker inspect '$container' --format '{{.State.StartedAt}}'" 2>/dev/null) || true
    if [ -n "$started" ]; then
        local start_epoch
        start_epoch=$(date -d "$started" +%s 2>/dev/null) || true
        if [ -n "$start_epoch" ]; then
            echo "    Uptime:    $(fmt_duration $((NOW - start_epoch)))"
        fi
    fi
    return 0
}

# --- SQL query helper ---

psql_query() {
    local query=$1
    run "docker exec '$HAF_CONTAINER' psql -U haf_admin -d haf_block_log -qtA -c \"$query\"" 2>/dev/null || true
}

# --- 1. HAF (hived) status ---

echo "--- HAF (hived) ---"
echo "    Container: $HAF_CONTAINER"
show_container_status "$HAF_CONTAINER" || true

# Get hived head block and time via SQL
HEAD_ROW=$(psql_query "SELECT num, created_at FROM hafd.blocks ORDER BY num DESC LIMIT 1")
HEAD_BLOCK=$(echo "$HEAD_ROW" | cut -d'|' -f1)
HEAD_TIME=$(echo "$HEAD_ROW" | cut -d'|' -f2)

if [ -n "$HEAD_BLOCK" ]; then
    echo "    Head block: $(fmt_number "$HEAD_BLOCK")"
    echo "hived=$HEAD_BLOCK" >> "$STATE_FILE.tmp"
    show_progress "hived" "$HEAD_BLOCK"
    if [ -n "$HEAD_TIME" ]; then
        HEAD_EPOCH=$(date -u -d "$HEAD_TIME" +%s 2>/dev/null) || true
        if [ -n "$HEAD_EPOCH" ]; then
            AGE=$((NOW - HEAD_EPOCH))
            echo "    Block age: $(fmt_duration $AGE)"
        fi
    fi
else
    echo "    Head block: (could not query)"
fi

# Get HAF LIB (last irreversible block / consistent block)
HAF_LIB=$(psql_query "SELECT consistent_block FROM hafd.hive_state")
if [ -n "$HAF_LIB" ]; then
    echo "    HAF LIB:   $(fmt_number "$HAF_LIB")"
fi

echo ""

# --- 2. HAF Applications ---

echo "--- HAF Applications ---"

# Define apps: display_name, app_name (for SQL), container_suffix
# The SQL function hive.app_get_current_block_num('app_name') returns the current block
APPS=(
    "Hivemind|hivemind_app|hivemind-block-processing-1"
    "Block Explorer|hafbe_app|block-explorer-block-processing-1"
    "Balance Tracker|hafbe_bal|balance-tracker-block-processing-1"
    "Reputation Tracker|reptracker_app|reputation-tracker-block-processing-1"
    "NFT Tracker|nfttracker_app|nft-tracker-block-processing-1"
    "Hivesense|hivesense_app|hivesense-sync-1"
    "HAfAH|hafah_app|"
)

for app_def in "${APPS[@]}"; do
    IFS='|' read -r display_name app_name container_suffix <<< "$app_def"
    container="${PROJECT}-${container_suffix}"
    state_key=$(echo "$app_name" | tr -d '_')

    echo "  $display_name ($app_name):"

    # Check if app is installed (context exists)
    APP_EXISTS=$(psql_query "SELECT EXISTS(SELECT 1 FROM hafd.contexts WHERE name = '${app_name}')")
    if [ "$APP_EXISTS" != "t" ]; then
        echo "    Not installed"
        echo ""
        continue
    fi

    # Show container status if there's a processing container
    if [ -n "$container_suffix" ]; then
        show_container_status "$container" || true
    fi

    # Get app's current block number
    APP_BLOCK=$(psql_query "SELECT hive.app_get_current_block_num('${app_name}')")
    if [ -n "$APP_BLOCK" ] && [ "$APP_BLOCK" != "" ]; then
        echo "    Block:     $(fmt_number "$APP_BLOCK")"
        echo "${state_key}=${APP_BLOCK}" >> "$STATE_FILE.tmp"
        show_progress "$state_key" "$APP_BLOCK"

        # Show how far behind hived
        if [ -n "${HEAD_BLOCK:-}" ] && [ "$HEAD_BLOCK" -gt "$APP_BLOCK" ]; then
            BEHIND=$((HEAD_BLOCK - APP_BLOCK))
            echo "    Behind:    $(fmt_number $BEHIND) blocks behind hived"
        fi
    else
        echo "    Block:     (could not query)"
    fi

    echo ""
done

# --- 3. Service health summary ---

echo "--- Service Health ---"
ALL_CONTAINERS=$(run "docker ps --filter 'label=com.docker.compose.project=$PROJECT' --format '{{.Names}}|{{.Status}}'" 2>/dev/null | sort) || true

while IFS='|' read -r name status; do
    [ -z "$name" ] && continue
    SHORT=$(echo "$name" | sed -E "s/^${PROJECT}-//; s/-[0-9]+$//")
    if echo "$status" | grep -q "unhealthy"; then
        HEALTH="UNHEALTHY !!!"
    elif echo "$status" | grep -q "healthy"; then
        HEALTH="healthy"
    elif echo "$status" | grep -q "Up"; then
        HEALTH="up"
    else
        HEALTH="$status"
    fi
    printf "  %-50s %s\n" "$SHORT" "$HEALTH"
done <<< "$ALL_CONTAINERS"

echo ""

# --- 4. Docker image build dates ---

echo "--- Docker Images ---"
# Get all image names and their creation dates in one remote call
IMAGE_DATA=$(run "docker ps --filter 'label=com.docker.compose.project=$PROJECT' --format '{{.Image}}' | sort -u | xargs -r docker inspect --format '{{index .RepoTags 0}}|{{.Created}}' 2>/dev/null" 2>/dev/null) || true

# Collect image info for version comparison later
declare -A IMAGE_TAGS    # project_key -> running tag
declare -A IMAGE_BUILT   # project_key -> build epoch

while IFS='|' read -r image created; do
    [ -z "$image" ] && continue
    if [ -n "$created" ]; then
        built=$(date -d "$created" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || built="$created"
        build_epoch=$(date -d "$created" +%s 2>/dev/null) || true
        age=""
        if [ -n "$build_epoch" ]; then
            age=" ($(fmt_duration $((NOW - build_epoch))) ago)"
        fi
        # Shorten common registry prefixes for display
        short_image=$(echo "$image" | sed -E 's%^registry\.(hive\.blog|gitlab\.syncad\.com/hive)/%%')
        printf "  %-55s %s%s\n" "$short_image" "$built" "$age"

        # Extract project key and tag for version comparison
        # Only for GitLab registry images (skip third-party like pghero, pgadmin, varnish)
        case "$image" in
            registry.gitlab.syncad.com/hive/*|registry.hive.blog/*)
                # Strip registry prefix and extract project/tag
                stripped=$(echo "$image" | sed -E 's%^registry\.(hive\.blog|gitlab\.syncad\.com/hive)/%%')
                tag="${stripped##*:}"
                path="${stripped%%:*}"
                # Map image path to project key (first path component)
                project_key="${path%%/*}"
                # Decide whether to use this image for version tracking:
                # - Prefer main image (no subpath) over sub-images (/postgrest-rewriter, /ollama)
                # - Prefer commit-hash tags (8 hex chars) over named tags (release versions)
                is_main=false
                if [ "$path" = "$project_key" ]; then is_main=true; fi
                is_commit_tag=false
                if echo "$tag" | grep -qE '^[0-9a-f]{8}$'; then is_commit_tag=true; fi
                prev_tag="${IMAGE_TAGS[$project_key]:-}"
                prev_is_commit=false
                if echo "$prev_tag" | grep -qE '^[0-9a-f]{8}$'; then prev_is_commit=true; fi

                should_replace=false
                if [ -z "$prev_tag" ]; then
                    should_replace=true
                elif $is_main; then
                    should_replace=true
                elif $is_commit_tag && ! $prev_is_commit; then
                    should_replace=true
                fi

                if $should_replace; then
                    IMAGE_TAGS["$project_key"]="$tag"
                    if [ -n "${build_epoch:-}" ]; then
                        IMAGE_BUILT["$project_key"]="$build_epoch"
                    fi
                fi
                ;;
        esac
    fi
done <<< "$IMAGE_DATA"

echo ""

# --- 5. GitLab develop branch version comparison ---

# Map project keys to GitLab project IDs
declare -A GITLAB_IDS=(
    [haf]=323
    [hivemind]=213
    [hafah]=308
    [balance_tracker]=330
    [reputation_tracker]=418
    [nft_tracker]=536
    [hivesense]=506
    [haf_block_explorer]=358
    [drone]=446
    [haf_api_node]=444
    [hive]=198
)

GITLAB_URL="https://gitlab.syncad.com/api/v4"

if [ -n "${GITLAB_TOKEN:-}" ] && [ ${#IMAGE_TAGS[@]} -gt 0 ]; then
    echo "--- Version vs develop ---"

    for project_key in $(echo "${!IMAGE_TAGS[@]}" | tr ' ' '\n' | sort); do
        tag="${IMAGE_TAGS[$project_key]}"
        project_id="${GITLAB_IDS[$project_key]:-}"

        if [ -z "$project_id" ]; then
            continue
        fi

        # Get latest develop branch commit
        dev_info=$(curl -sf -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "$GITLAB_URL/projects/$project_id/repository/branches/develop" 2>/dev/null) || true

        if [ -z "$dev_info" ]; then
            printf "  %-30s %-20s %s\n" "$project_key" "$tag" "(could not query develop)"
            continue
        fi

        dev_short_id=$(echo "$dev_info" | grep -o '"short_id":"[^"]*"' | head -1 | cut -d'"' -f4)
        dev_date=$(echo "$dev_info" | grep -o '"committed_date":"[^"]*"' | head -1 | cut -d'"' -f4)

        if [ -z "$dev_short_id" ]; then
            printf "  %-30s %-20s %s\n" "$project_key" "$tag" "(could not parse develop)"
            continue
        fi

        # Check if running tag matches develop
        if [ "$tag" = "$dev_short_id" ]; then
            printf "  %-30s %-20s %s\n" "$project_key" "$tag" "same as develop"
        else
            # Calculate how far behind
            behind_info=""
            running_epoch="${IMAGE_BUILT[$project_key]:-}"

            # Get develop pipeline build date
            dev_pipeline=$(curl -sf -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                "$GITLAB_URL/projects/$project_id/pipelines?ref=develop&status=success&order_by=id&sort=desc&per_page=1" 2>/dev/null) || true
            dev_build_date=$(echo "$dev_pipeline" | grep -o '"created_at":"[^"]*"' | head -1 | cut -d'"' -f4)

            if [ -n "$dev_build_date" ] && [ -n "$running_epoch" ]; then
                dev_build_epoch=$(date -d "$dev_build_date" +%s 2>/dev/null) || true
                if [ -n "$dev_build_epoch" ] && [ "$dev_build_epoch" -gt "$running_epoch" ]; then
                    diff_secs=$((dev_build_epoch - running_epoch))
                    behind_info="older than develop by $(fmt_duration $diff_secs)"
                elif [ -n "$dev_build_epoch" ]; then
                    behind_info="newer than develop"
                fi
            fi

            # Check if running tag is a commit hash (8 hex chars) and find its branch
            branch_info=""
            if echo "$tag" | grep -qE '^[0-9a-f]{8}$'; then
                # Look up what branch/pipeline this commit came from
                commit_info=$(curl -sf -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                    "$GITLAB_URL/projects/$project_id/repository/commits/$tag" 2>/dev/null) || true
                if [ -n "$commit_info" ]; then
                    full_sha=$(echo "$commit_info" | grep -o '"id":"[0-9a-f]\{40\}"' | head -1 | cut -d'"' -f4)
                    if [ -n "$full_sha" ]; then
                        pipeline_info=$(curl -sf -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                            "$GITLAB_URL/projects/$project_id/pipelines?sha=$full_sha&per_page=1" 2>/dev/null) || true
                        ref=$(echo "$pipeline_info" | grep -o '"ref":"[^"]*"' | head -1 | cut -d'"' -f4)
                        if [ -n "$ref" ] && [ "$ref" != "develop" ]; then
                            branch_info=" [branch: $ref]"
                        fi
                    fi
                fi
            else
                # Named tag (e.g., v1.28.6-rc11) — it's a release tag, not a branch build
                branch_info=" [release tag]"
            fi

            status_text="${behind_info:-differs from develop ($dev_short_id)}${branch_info}"
            printf "  %-30s %-20s %s\n" "$project_key" "$tag" "$status_text"
        fi
    done

    echo ""
elif [ ${#IMAGE_TAGS[@]} -gt 0 ]; then
    echo "--- Version vs develop ---"
    echo "  (GITLAB_TOKEN not set — skipping develop branch comparison)"
    echo ""
fi

# Finalize state file
mv "$STATE_FILE.tmp" "$STATE_FILE"

echo "--- End of report ---"
