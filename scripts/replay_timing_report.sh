#!/bin/bash
#
# HAF API Node Replay Timing Report Generator
#
# This script analyzes docker logs to generate a timing report for HAF and app replays.
# It extracts timing information from container logs and presents it in a formatted report.
#
# Usage: ./replay_timing_report.sh [COMPOSE_PROJECT_DIR]
#
# If COMPOSE_PROJECT_DIR is not specified, defaults to the directory containing this script's parent.

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Determine compose directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${1:-$(dirname "$SCRIPT_DIR")}"
COMPOSE_FILE="${COMPOSE_DIR}/compose.yml"

if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo -e "${RED}Error: compose.yml not found at ${COMPOSE_FILE}${NC}" >&2
    exit 1
fi

# Get project name from .env file or use default
ENV_FILE="${COMPOSE_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
    PROJECT_NAME=$(grep -E "^PROJECT_NAME=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '"' | tr -d "'" || echo "haf")
else
    PROJECT_NAME="haf"
fi

# Container name prefix
CONTAINER_PREFIX="${PROJECT_NAME}"

# Function to convert seconds to human-readable format
format_duration() {
    local seconds="$1"
    if [[ -z "$seconds" || "$seconds" == "null" || "$seconds" == "N/A" ]]; then
        echo "N/A"
        return
    fi

    # Remove any non-numeric characters
    seconds="${seconds//[^0-9]/}"
    if [[ -z "$seconds" ]]; then
        echo "N/A"
        return
    fi

    local days=$((seconds / 86400))
    local hours=$(((seconds % 86400) / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))

    if [[ $days -gt 0 ]]; then
        printf "%dd %02dh %02dm %02ds" $days $hours $minutes $secs
    elif [[ $hours -gt 0 ]]; then
        printf "%dh %02dm %02ds" $hours $minutes $secs
    elif [[ $minutes -gt 0 ]]; then
        printf "%dm %02ds" $minutes $secs
    else
        printf "%ds" $secs
    fi
}

# Function to parse HH:MM:SS or similar duration format to seconds
parse_duration_to_seconds() {
    local duration="$1"

    # Handle N/A
    if [[ "$duration" == "N/A" || -z "$duration" ]]; then
        echo ""
        return
    fi

    # Handle format like "02d 15h 16m 57s" from hivemind
    if [[ "$duration" =~ ([0-9]+)d\ *([0-9]+)h\ *([0-9]+)m\ *([0-9]+)s ]]; then
        # Use 10# prefix to force base-10 interpretation (avoids octal issues with leading zeros)
        local days=$((10#${BASH_REMATCH[1]}))
        local hours=$((10#${BASH_REMATCH[2]}))
        local mins=$((10#${BASH_REMATCH[3]}))
        local secs=$((10#${BASH_REMATCH[4]}))
        echo $((days * 86400 + hours * 3600 + mins * 60 + secs))
        return
    fi

    # Handle format like "13:15:35" (HH:MM:SS)
    if [[ "$duration" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
        local hours=$((10#${BASH_REMATCH[1]}))
        local mins=$((10#${BASH_REMATCH[2]}))
        local secs=$((10#${BASH_REMATCH[3]}))
        echo $((hours * 3600 + mins * 60 + secs))
        return
    fi

    # Handle format like "01m 18s"
    if [[ "$duration" =~ ([0-9]+)m\ *([0-9]+)s ]]; then
        local mins=$((10#${BASH_REMATCH[1]}))
        local secs=$((10#${BASH_REMATCH[2]}))
        echo $((mins * 60 + secs))
        return
    fi

    # Handle plain seconds
    if [[ "$duration" =~ ^[0-9]+$ ]]; then
        echo "$duration"
        return
    fi

    echo ""
}

# Function to get container logs
get_logs() {
    local container="$1"
    docker logs "$container" 2>&1
}

# Function to check if container exists
container_exists() {
    local container="$1"
    docker ps -a --format '{{.Names}}' | grep -q "^${container}$"
}

# Print header
print_header() {
    echo ""
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}              HAF API Node Replay Timing Report${NC}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}Generated:${NC} $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo -e "${CYAN}Compose Dir:${NC} ${COMPOSE_DIR}"
    echo -e "${CYAN}Project Name:${NC} ${PROJECT_NAME}"
    echo ""
}

# Parse HAF timing
parse_haf_timing() {
    local container="${CONTAINER_PREFIX}-haf-1"

    if ! container_exists "$container"; then
        echo -e "${YELLOW}Warning: HAF container not found${NC}" >&2
        return
    fi

    echo -e "${BOLD}${GREEN}1. HAF (Core Blockchain Sync)${NC}"
    echo -e "${GREEN}───────────────────────────────────────────────────────────────────${NC}"

    local logs
    logs=$(get_logs "$container")

    # Extract timing information
    local reindex_start reindex_entered p2p_entered live_entered live_block

    reindex_start=$(echo "$logs" | grep -E "PROFILE: Entered REINDEX sync from start state:" | head -1 | grep -oP '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}' || echo "")
    p2p_entered=$(echo "$logs" | grep -E "PROFILE: Entered P2P sync from start state:" | head -1)
    live_entered=$(echo "$logs" | grep -E "PROFILE: Entered LIVE sync from start state:" | head -1)

    # Parse P2P timing
    local p2p_timestamp p2p_seconds
    if [[ -n "$p2p_entered" ]]; then
        p2p_timestamp=$(echo "$p2p_entered" | grep -oP '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}' || echo "")
        p2p_seconds=$(echo "$p2p_entered" | grep -oP 'start state: \K\d+' || echo "")
    fi

    # Parse LIVE timing
    local live_timestamp live_seconds live_block
    if [[ -n "$live_entered" ]]; then
        live_timestamp=$(echo "$live_entered" | grep -oP '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}' || echo "")
        live_seconds=$(echo "$live_entered" | grep -oP 'start state: \K\d+' || echo "")
        live_block=$(echo "$live_entered" | grep -oP 'start state: \d+ s \K\d+' || echo "")
    fi

    # Calculate durations
    local reindex_duration=""
    if [[ -n "$p2p_seconds" ]]; then
        reindex_duration=$(format_duration "$p2p_seconds")
    fi

    local p2p_to_live_seconds=""
    local p2p_to_live_duration=""
    if [[ -n "$live_seconds" && -n "$p2p_seconds" ]]; then
        p2p_to_live_seconds=$((live_seconds - p2p_seconds))
        p2p_to_live_duration=$(format_duration "$p2p_to_live_seconds")
    fi

    local total_duration=""
    if [[ -n "$live_seconds" ]]; then
        total_duration=$(format_duration "$live_seconds")
    fi

    # Print table
    printf "%-35s %-25s %-20s\n" "Phase" "Timestamp" "Duration"
    printf "%-35s %-25s %-20s\n" "─────────────────────────────────" "─────────────────────────" "────────────────────"

    if [[ -n "$reindex_start" ]]; then
        printf "%-35s %-25s %-20s\n" "REINDEX started" "$reindex_start" "-"
    fi

    if [[ -n "$p2p_timestamp" ]]; then
        printf "%-35s %-25s %-20s\n" "P2P sync entered" "$p2p_timestamp" "${reindex_duration:-N/A}"
    fi

    if [[ -n "$live_timestamp" ]]; then
        printf "%-35s %-25s %-20s\n" "LIVE sync entered" "$live_timestamp" "${p2p_to_live_duration:-N/A} (P2P→LIVE)"
    fi

    echo ""
    if [[ -n "$total_duration" ]]; then
        echo -e "${BOLD}Total HAF Replay Time:${NC} ${total_duration}"
    fi
    if [[ -n "$live_block" ]]; then
        echo -e "${BOLD}Block at LIVE entry:${NC} ${live_block}"
    fi

    # Calculate blocks per second
    if [[ -n "$live_block" && -n "$p2p_seconds" && "$p2p_seconds" -gt 0 ]]; then
        local bps=$((live_block / p2p_seconds))
        echo -e "${BOLD}Average replay speed:${NC} ~${bps} blocks/second"
    fi

    echo ""
}

# Parse HAF app timing (PostgreSQL-based apps)
parse_haf_app_timing() {
    local container="$1"
    local app_name="$2"

    if ! container_exists "$container"; then
        echo -e "  ${YELLOW}${app_name}: Container not found${NC}"
        return
    fi

    local logs
    logs=$(get_logs "$container")

    # Look for STAGE_CHANGED messages
    local stage_changes
    stage_changes=$(echo "$logs" | grep -E "PROFILE:.*STAGE_CHANGED" || echo "")

    if [[ -z "$stage_changes" ]]; then
        # Check if still waiting
        local waiting
        waiting=$(echo "$logs" | grep -E "Waiting for next block|wait_for_haf" | tail -1 || echo "")
        if [[ -n "$waiting" ]]; then
            echo -e "  ${YELLOW}${app_name}: Still waiting for HAF${NC}"
        else
            echo -e "  ${YELLOW}${app_name}: No timing data found${NC}"
        fi
        return
    fi

    # Parse stage changes - get the first occurrence of each transition
    local wait_to_massive massive_to_live

    wait_to_massive=$(echo "$stage_changes" | grep -E "wait_for_haf.*to.*MASSIVE" | head -1 || echo "")
    massive_to_live=$(echo "$stage_changes" | grep -E "MASSIVE.*to.*live" | head -1 || echo "")

    local wait_duration="" massive_duration="" live_block=""

    if [[ -n "$wait_to_massive" ]]; then
        # Extract duration like "13:15:35" or "N/A"
        wait_duration=$(echo "$wait_to_massive" | grep -oP "after \K[0-9:]+(?= block)" || echo "N/A")
    fi

    if [[ -n "$massive_to_live" ]]; then
        massive_duration=$(echo "$massive_to_live" | grep -oP "after \K[0-9:]+(?= block)" || echo "N/A")
        live_block=$(echo "$massive_to_live" | grep -oP "after [0-9:]+ block: \K[0-9]+" || echo "")
    fi

    # Convert to seconds for total calculation
    local wait_secs massive_secs total_secs
    wait_secs=$(parse_duration_to_seconds "$wait_duration")
    massive_secs=$(parse_duration_to_seconds "$massive_duration")

    local total_duration="N/A"
    if [[ -n "$wait_secs" && -n "$massive_secs" ]]; then
        total_secs=$((wait_secs + massive_secs))
        total_duration=$(format_duration "$total_secs")
    elif [[ -n "$wait_secs" ]]; then
        # Still in massive processing
        total_duration="$(format_duration "$wait_secs") + (still processing)"
    fi

    # Determine status
    local status
    if [[ -n "$massive_to_live" ]]; then
        status="${GREEN}LIVE${NC}"
    elif [[ -n "$wait_to_massive" ]]; then
        status="${YELLOW}PROCESSING${NC}"
    else
        status="${YELLOW}WAITING${NC}"
    fi

    printf "  %-25s %-15s %-15s %-20s %-12s %s\n" \
        "$app_name" \
        "${wait_duration:-N/A}" \
        "${massive_duration:-N/A}" \
        "${total_duration}" \
        "${live_block:-N/A}" \
        "$(echo -e $status)"
}

# Parse Hivemind timing (Python-based)
parse_hivemind_timing() {
    local container="${CONTAINER_PREFIX}-hivemind-block-processing-1"
    local app_name="Hivemind"

    if ! container_exists "$container"; then
        echo -e "  ${YELLOW}${app_name}: Container not found${NC}"
        return
    fi

    local logs
    logs=$(get_logs "$container")

    # Look for "Switched to" messages
    local wait_mode massive_mode live_mode

    wait_mode=$(echo "$logs" | grep -E "Switched to.*wait_for_haf.*mode" | head -1 || echo "")
    massive_mode=$(echo "$logs" | grep -E "Switched to.*MASSIVE" | head -1 || echo "")
    live_mode=$(echo "$logs" | grep -E "Switched to.*live.*mode" | tail -1 || echo "")

    local wait_duration="" massive_duration="" live_block=""

    if [[ -n "$massive_mode" ]]; then
        # Format: "processing time: 13h 15m 23s"
        wait_duration=$(echo "$massive_mode" | grep -oP "processing time: \K[0-9dhms ]+" || echo "N/A")
    fi

    if [[ -n "$live_mode" ]]; then
        # Format: "block: 101659044 | processing time: 02d 15h 16m 57s"
        massive_duration=$(echo "$live_mode" | grep -oP "processing time: \K[0-9dhms ]+" || echo "N/A")
        live_block=$(echo "$live_mode" | grep -oP "block: \K[0-9]+" || echo "")
    fi

    # Convert to seconds for total calculation
    local wait_secs massive_secs total_secs
    wait_secs=$(parse_duration_to_seconds "$wait_duration")
    massive_secs=$(parse_duration_to_seconds "$massive_duration")

    local total_duration="N/A"
    if [[ -n "$massive_secs" ]]; then
        total_duration=$(format_duration "$massive_secs")
    elif [[ -n "$wait_secs" ]]; then
        total_duration="$(format_duration "$wait_secs") + (still processing)"
    fi

    # Determine status
    local status
    if [[ -n "$live_mode" ]]; then
        status="${GREEN}LIVE${NC}"
    elif [[ -n "$massive_mode" ]]; then
        status="${YELLOW}PROCESSING${NC}"
    else
        status="${YELLOW}WAITING${NC}"
    fi

    printf "  %-25s %-15s %-15s %-20s %-12s %s\n" \
        "$app_name" \
        "${wait_duration:-N/A}" \
        "${massive_duration:-N/A}" \
        "${total_duration}" \
        "${live_block:-N/A}" \
        "$(echo -e $status)"
}

# Parse Hivesense timing
parse_hivesense_timing() {
    local container="${CONTAINER_PREFIX}-hivesense-sync-1"
    local app_name="Hivesense"

    if ! container_exists "$container"; then
        echo -e "  ${YELLOW}${app_name}: Container not found${NC}"
        return
    fi

    # Get first log timestamp (just first few lines)
    local start_time
    start_time=$(docker logs "$container" 2>&1 | head -5 | grep -oP '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' | head -1 || echo "")

    # Check if still waiting for hivemind (check first 100 lines)
    local still_waiting
    still_waiting=$(docker logs "$container" 2>&1 | head -100 | grep -E "Waiting for hivemind head block" | tail -1 || echo "")

    # Get last seq number processed (from last few lines)
    local last_seq
    last_seq=$(docker logs "$container" 2>&1 | tail -20 | grep -oP 'seq \K[0-9]+' | tail -1 || echo "")

    # Look for HNSW index creation info - use a single grep with multiple patterns to avoid multiple full scans
    # The logs containing HNSW info are near each other, so we can extract them together
    local hnsw_info hnsw_start="" hnsw_complete="" hnsw_duration="" hnsw_size=""
    hnsw_info=$(docker logs "$container" 2>&1 | grep -E "(Starting HNSW index creation|HNSW Index Creation Results|Total creation time:|Index size:)" 2>/dev/null || echo "")

    if [[ -n "$hnsw_info" ]]; then
        # Extract just the first timestamp from each line (the log prefix timestamp)
        hnsw_start=$(echo "$hnsw_info" | grep -E "Starting HNSW index creation" | tail -1 | grep -oP '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' || echo "")
        hnsw_complete=$(echo "$hnsw_info" | grep -E "HNSW Index Creation Results" | tail -1 | grep -oP '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' || echo "")
        hnsw_duration=$(echo "$hnsw_info" | grep -E "Total creation time:" | tail -1 | grep -oP 'Total creation time: \K[0-9:.]+' || echo "")
        hnsw_size=$(echo "$hnsw_info" | grep -E "Index size:" | tail -1 | grep -oP 'Index size: \K[0-9]+ GB' || echo "")
    fi

    local status
    if [[ -n "$still_waiting" && -z "$last_seq" ]]; then
        status="${YELLOW}WAITING FOR HIVEMIND${NC}"
    elif [[ -n "$hnsw_complete" ]]; then
        status="${GREEN}HNSW INDEX READY${NC}"
    elif [[ -n "$hnsw_start" && -z "$hnsw_complete" ]]; then
        status="${YELLOW}BUILDING HNSW INDEX${NC}"
    elif [[ -n "$last_seq" ]]; then
        status="${YELLOW}SYNCING (seq: ${last_seq})${NC}"
    else
        status="${GREEN}SYNCED${NC}"
    fi

    printf "  %-25s %-15s %-15s %-20s %-12s %s\n" \
        "$app_name" \
        "${start_time:-N/A}" \
        "N/A" \
        "N/A" \
        "N/A" \
        "$(echo -e $status)"

    # Print HNSW details if available
    if [[ -n "$hnsw_start" || -n "$hnsw_complete" ]]; then
        echo ""
        echo -e "  ${CYAN}Hivesense HNSW Index Details:${NC}"
        if [[ -n "$hnsw_start" ]]; then
            echo -e "    Index creation started:  ${hnsw_start}"
        fi
        if [[ -n "$hnsw_complete" ]]; then
            echo -e "    Index creation finished: ${hnsw_complete}"
        fi
        if [[ -n "$hnsw_duration" ]]; then
            echo -e "    Creation duration:       ${hnsw_duration}"
        fi
        if [[ -n "$hnsw_size" ]]; then
            echo -e "    Index size:              ${hnsw_size}"
        fi
    fi
}

# Main app timing section
parse_app_timing() {
    echo -e "${BOLD}${GREEN}2. Application Replay Times${NC}"
    echo -e "${GREEN}───────────────────────────────────────────────────────────────────${NC}"
    echo ""

    printf "  ${BOLD}%-25s %-15s %-15s %-20s %-12s %s${NC}\n" \
        "Application" "Wait for HAF" "Replay Time" "Total Time" "Live Block" "Status"
    printf "  %-25s %-15s %-15s %-20s %-12s %s\n" \
        "─────────────────────────" "───────────────" "───────────────" "────────────────────" "────────────" "──────────"

    # Parse each app
    parse_haf_app_timing "${CONTAINER_PREFIX}-reputation-tracker-block-processing-1" "Reputation Tracker"
    parse_haf_app_timing "${CONTAINER_PREFIX}-nft-tracker-block-processing-1" "NFT Tracker"
    parse_haf_app_timing "${CONTAINER_PREFIX}-block-explorer-block-processing-1" "Block Explorer"
    parse_hivemind_timing
    parse_hivesense_timing

    echo ""
}

# Get current block from a block processor's logs
# Returns the most recent block number found in logs, or empty if not found
get_current_block() {
    local container="$1"
    local app_type="$2"  # haf, hivemind, haf_app, nft, reputation

    if ! container_exists "$container"; then
        echo ""
        return
    fi

    local logs block
    case "$app_type" in
        haf)
            # HAF: "Dump whole block 101791010" or "Got 14 transactions on block 101791010"
            block=$(docker logs "$container" 2>&1 | tail -100 | grep -oP '(?:Dump whole block|on block) \K[0-9]+' | tail -1)
            ;;
        hivemind)
            # Hivemind: "Last imported block is: 101790997" or block numbers in SQL calls
            block=$(docker logs "$container" 2>&1 | tail -100 | grep -oP 'Last imported block is: \K[0-9]+' | tail -1)
            if [[ -z "$block" ]]; then
                # Try extracting from update_last_completed_block calls
                block=$(docker logs "$container" 2>&1 | tail -100 | grep -oP 'update_last_completed_block\(\K[0-9]+' | tail -1)
            fi
            ;;
        haf_app)
            # HAF apps (block explorer): "[SINGLE]  Attempting to process block: <101791004>" or "Processed blocks"
            block=$(docker logs "$container" 2>&1 | tail -100 | grep -oP 'process block: <\K[0-9]+' | tail -1)
            if [[ -z "$block" ]]; then
                # Try MASSIVE sync pattern: "Processing block range: X to Y"
                block=$(docker logs "$container" 2>&1 | tail -100 | grep -oP 'Processing block range: [0-9]+ to \K[0-9]+' | tail -1)
            fi
            ;;
        nft|reputation)
            # NFT/Reputation: "nfttracker processed block 101791001" or "Reptracker processed block 101791002"
            block=$(docker logs "$container" 2>&1 | tail -100 | grep -oP '(?:nfttracker|Reptracker) process(?:ed|ing) block[: ]+\K[0-9]+' | tail -1)
            ;;
    esac

    echo "$block"
}

# Check if a block processor is in live mode
is_in_live_mode() {
    local container="$1"
    local app_type="$2"

    if ! container_exists "$container"; then
        echo "false"
        return
    fi

    local logs
    case "$app_type" in
        haf)
            # HAF is live if we see P2P blocks being processed
            if docker logs "$container" 2>&1 | tail -50 | grep -qE "PROFILE: Entered LIVE sync|type.*p2p"; then
                echo "true"
            else
                echo "false"
            fi
            ;;
        hivemind)
            # Hivemind: "Switched to live mode" or "Tables updating in live synchronization"
            if docker logs "$container" 2>&1 | tail -100 | grep -qE "Switched to.*live.*mode|Tables updating in live synchronization"; then
                echo "true"
            else
                echo "false"
            fi
            ;;
        haf_app|nft|reputation)
            # HAF apps: "[SINGLE]" processing indicates live mode, or "Waiting for next block"
            if docker logs "$container" 2>&1 | tail -50 | grep -qE "\[SINGLE\]|Waiting for next block"; then
                echo "true"
            else
                echo "false"
            fi
            ;;
    esac
}

# Print current sync progress for non-live block processors
print_sync_progress() {
    echo -e "${BOLD}${GREEN}3. Current Sync Progress (Non-Live Processors)${NC}"
    echo -e "${GREEN}───────────────────────────────────────────────────────────────────${NC}"
    echo ""

    local found_syncing=false

    # Define block processors to check: container_suffix:app_type:display_name
    local processors=(
        "haf-1:haf:HAF"
        "hivemind-block-processing-1:hivemind:Hivemind"
        "block-explorer-block-processing-1:haf_app:Block Explorer"
        "nft-tracker-block-processing-1:nft:NFT Tracker"
        "reputation-tracker-block-processing-1:reputation:Reputation Tracker"
    )

    printf "  ${BOLD}%-25s %-15s %-15s${NC}\n" "Processor" "Current Block" "Status"
    printf "  %-25s %-15s %-15s\n" "─────────────────────────" "───────────────" "───────────────"

    for processor in "${processors[@]}"; do
        IFS=':' read -r suffix app_type display_name <<< "$processor"
        local container="${CONTAINER_PREFIX}-${suffix}"

        if ! container_exists "$container"; then
            continue
        fi

        local is_live current_block status
        is_live=$(is_in_live_mode "$container" "$app_type")

        if [[ "$is_live" == "true" ]]; then
            status="${GREEN}LIVE${NC}"
            current_block="-"
        else
            current_block=$(get_current_block "$container" "$app_type")
            if [[ -n "$current_block" ]]; then
                status="${YELLOW}SYNCING${NC}"
                found_syncing=true
            else
                status="${YELLOW}WAITING${NC}"
                current_block="-"
            fi
        fi

        printf "  %-25s %-15s %b\n" "$display_name" "${current_block}" "$status"
    done

    echo ""

    if ! $found_syncing; then
        echo -e "  ${GREEN}All block processors are in live mode or waiting.${NC}"
        echo ""
    fi
}

# Summary section
print_summary() {
    echo -e "${BOLD}${GREEN}4. Summary${NC}"
    echo -e "${GREEN}───────────────────────────────────────────────────────────────────${NC}"
    echo ""

    # Get container creation time as proxy for startup time
    local haf_created
    haf_created=$(docker inspect --format='{{.Created}}' "${CONTAINER_PREFIX}-haf-1" 2>/dev/null | cut -d'.' -f1 | tr 'T' ' ' || echo "Unknown")

    echo -e "${BOLD}Stack Started:${NC} ${haf_created}"

    # Check overall health
    local all_healthy=true
    local containers=("${CONTAINER_PREFIX}-haf-1" "${CONTAINER_PREFIX}-hivemind-block-processing-1" "${CONTAINER_PREFIX}-reputation-tracker-block-processing-1" "${CONTAINER_PREFIX}-nft-tracker-block-processing-1" "${CONTAINER_PREFIX}-block-explorer-block-processing-1")

    for container in "${containers[@]}"; do
        if container_exists "$container"; then
            local health
            health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "unknown")
            if [[ "$health" != "healthy" ]]; then
                all_healthy=false
            fi
        fi
    done

    if $all_healthy; then
        echo -e "${BOLD}Overall Status:${NC} ${GREEN}All core services healthy${NC}"
    else
        echo -e "${BOLD}Overall Status:${NC} ${YELLOW}Some services may still be syncing${NC}"
    fi

    echo ""
}

# Main execution
main() {
    print_header
    parse_haf_timing
    parse_app_timing
    print_sync_progress
    print_summary

    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

main "$@"
