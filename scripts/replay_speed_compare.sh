#!/bin/bash
#
# HAF Replay Speed Analysis & Comparison
#
# Extracts block processing speed from hived docker logs ("Dump whole block N" lines)
# and computes blocks/second statistics over configurable block ranges.
# Can compare two servers/containers side-by-side.
#
# Usage:
#   # Single server analysis (run on the server or via SSH)
#   ./replay_speed_compare.sh --container haf10-haf-1
#
#   # Compare two servers via SSH
#   ./replay_speed_compare.sh \
#     --server1 steem-19.syncad.com --container1 haf10-haf-1 --label1 "rc11" \
#     --server2 steem-20.syncad.com --container2 haf-irrev-haf-1 --label2 "irrev"
#
#   # Adjust block range bucket size (default 5M)
#   ./replay_speed_compare.sh ... --bucket 1000000
#
#   # Show only overlapping block ranges (for fair comparison)
#   ./replay_speed_compare.sh ... --overlap-only

set -euo pipefail

# Defaults
BUCKET_SIZE=5000000
OVERLAP_ONLY=false
COMPACT=false

# Server 1
SERVER1=""
CONTAINER1=""
LABEL1="server1"

# Server 2
SERVER2=""
CONTAINER2=""
LABEL2="server2"

# Single-server mode
CONTAINER=""

usage() {
    cat <<'EOF'
Usage:
  Single server:
    replay_speed_compare.sh --container <name> [--bucket N]

  Two-server comparison:
    replay_speed_compare.sh \
      --server1 <host> --container1 <name> --label1 <label> \
      --server2 <host> --container2 <name> --label2 <label> \
      [--bucket N] [--overlap-only] [--compact]

Options:
  --container <name>    Container name (single-server mode, runs locally)
  --server1/2 <host>    SSH hostname (omit for local)
  --container1/2 <name> Container name on each server
  --label1/2 <label>    Display label (default: server1/server2)
  --bucket <N>          Block range bucket size (default: 5000000)
  --overlap-only        Only show block ranges present in both datasets
  --compact             Machine-readable TSV output
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --container)   CONTAINER="$2"; shift 2 ;;
        --server1)     SERVER1="$2"; shift 2 ;;
        --container1)  CONTAINER1="$2"; shift 2 ;;
        --label1)      LABEL1="$2"; shift 2 ;;
        --server2)     SERVER2="$2"; shift 2 ;;
        --container2)  CONTAINER2="$2"; shift 2 ;;
        --label2)      LABEL2="$2"; shift 2 ;;
        --bucket)      BUCKET_SIZE="$2"; shift 2 ;;
        --overlap-only) OVERLAP_ONLY=true; shift ;;
        --compact)     COMPACT=true; shift ;;
        -h|--help)     usage ;;
        *)             echo "Unknown option: $1" >&2; usage ;;
    esac
done

# Determine mode
if [[ -n "$CONTAINER" ]]; then
    # Single-server mode
    CONTAINER1="$CONTAINER"
    LABEL1="local"
    MODE="single"
elif [[ -n "$CONTAINER1" && -n "$CONTAINER2" ]]; then
    MODE="compare"
else
    echo "Error: specify --container for single mode, or --container1/--container2 for comparison" >&2
    usage
fi

# Extract "Dump whole block" lines from a container, return "timestamp block_num" pairs
# Filters to only the log lines we need, avoiding pulling full logs into memory
extract_block_times() {
    local server="$1"
    local container="$2"

    local cmd="docker logs $container 2>&1 | grep -F 'Dump whole block' | sed -E 's/^([0-9T:.:-]+) .* Dump whole block ([0-9]+)/\1 \2/'"

    if [[ -n "$server" ]]; then
        ssh "$server" "$cmd" 2>/dev/null
    else
        eval "$cmd" 2>/dev/null
    fi
}

# Compute blocks/sec per bucket from "timestamp block_num" input
# Output: bucket_start bucket_end elapsed_sec blocks_in_bucket blocks_per_sec
compute_speed() {
    local bucket_size="$1"
    awk -v bucket_size="$bucket_size" '
    BEGIN {
        prev_ts = ""; prev_block = 0
    }
    {
        ts = $1; block = $2 + 0

        # Parse ISO timestamp to epoch seconds
        # Format: 2026-03-07T19:08:53.912972
        gsub(/[-T:]/, " ", ts)
        split(ts, parts, ".")
        split(parts[1], dt, " ")
        epoch = mktime(dt[1] " " dt[2] " " dt[3] " " dt[4] " " dt[5] " " dt[6])

        bucket = int(block / bucket_size) * bucket_size

        if (!(bucket in first_ts)) {
            first_ts[bucket] = epoch
            first_block[bucket] = block
        }
        last_ts[bucket] = epoch
        last_block[bucket] = block

        # Track ordered bucket list
        if (!(bucket in seen)) {
            seen[bucket] = 1
            buckets[++nbuckets] = bucket
        }
    }
    END {
        for (i = 1; i <= nbuckets; i++) {
            b = buckets[i]
            elapsed = last_ts[b] - first_ts[b]
            blocks = last_block[b] - first_block[b]
            if (elapsed > 0 && blocks > 0) {
                bps = blocks / elapsed
                printf "%d\t%d\t%d\t%d\t%.0f\n", b, b + bucket_size, elapsed, blocks, bps
            }
        }
    }'
}

format_bucket() {
    local n="$1"
    if [[ $n -ge 1000000 ]]; then
        echo "$((n / 1000000))M"
    elif [[ $n -ge 1000 ]]; then
        echo "$((n / 1000))K"
    else
        echo "$n"
    fi
}

format_elapsed() {
    local secs="$1"
    local hours=$((secs / 3600))
    local mins=$(((secs % 3600) / 60))
    if [[ $hours -gt 0 ]]; then
        printf "%dh%02dm" "$hours" "$mins"
    else
        printf "%dm%02ds" "$mins" "$((secs % 60))"
    fi
}

# --- Main ---

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Extracting block times..." >&2

if [[ "$MODE" == "single" ]]; then
    extract_block_times "$SERVER1" "$CONTAINER1" | compute_speed "$BUCKET_SIZE" > "$TMPDIR/data1.tsv"

    if [[ ! -s "$TMPDIR/data1.tsv" ]]; then
        echo "Error: no block data found in $CONTAINER1" >&2
        exit 1
    fi

    if [[ "$COMPACT" == "true" ]]; then
        printf "range_start\trange_end\telapsed_s\tblocks\tblocks_per_sec\n"
        cat "$TMPDIR/data1.tsv"
    else
        echo ""
        echo "Replay Speed Report: $LABEL1 ($CONTAINER1)"
        echo "Bucket size: $(format_bucket "$BUCKET_SIZE") blocks"
        echo ""
        printf "%-16s %10s %10s %10s\n" "Block Range" "Elapsed" "Blocks" "Blk/sec"
        printf "%-16s %10s %10s %10s\n" "───────────────" "──────────" "──────────" "──────────"

        while IFS=$'\t' read -r bstart bend elapsed blocks bps; do
            printf "%-16s %10s %10s %10s\n" \
                "$(format_bucket "$bstart")-$(format_bucket "$bend")" \
                "$(format_elapsed "$elapsed")" \
                "$blocks" \
                "$bps"
        done < "$TMPDIR/data1.tsv"

        # Overall average
        awk -F'\t' '{te+=$3; tb+=$4} END {if(te>0) printf "\n%-16s %10s %10s %10.0f\n", "OVERALL", "", tb, tb/te}' "$TMPDIR/data1.tsv"
    fi

else
    # Compare mode — extract both in parallel
    extract_block_times "$SERVER1" "$CONTAINER1" | compute_speed "$BUCKET_SIZE" > "$TMPDIR/data1.tsv" &
    extract_block_times "$SERVER2" "$CONTAINER2" | compute_speed "$BUCKET_SIZE" > "$TMPDIR/data2.tsv" &
    wait

    if [[ ! -s "$TMPDIR/data1.tsv" ]]; then
        echo "Error: no block data from $LABEL1 ($CONTAINER1)" >&2
        exit 1
    fi
    if [[ ! -s "$TMPDIR/data2.tsv" ]]; then
        echo "Error: no block data from $LABEL2 ($CONTAINER2)" >&2
        exit 1
    fi

    # Join on bucket_start, compute diff
    # Create keyed files for joining
    sort -t$'\t' -k1,1n "$TMPDIR/data1.tsv" > "$TMPDIR/s1.tsv"
    sort -t$'\t' -k1,1n "$TMPDIR/data2.tsv" > "$TMPDIR/s2.tsv"

    if [[ "$COMPACT" == "true" ]]; then
        printf "range\t%s_bps\t%s_bps\tdiff_pct\n" "$LABEL1" "$LABEL2"
        join -t$'\t' -j1 -o '1.1,1.5,2.5' "$TMPDIR/s1.tsv" "$TMPDIR/s2.tsv" | \
            awk -F'\t' '{if($3>0) printf "%s\t%s\t%s\t%.1f\n", $1, $2, $3, ($2-$3)*100/$3}'
    else
        echo ""
        echo "Replay Speed Comparison"
        echo "  $LABEL1: ${SERVER1:-(local)} / $CONTAINER1"
        echo "  $LABEL2: ${SERVER2:-(local)} / $CONTAINER2"
        echo "Bucket size: $(format_bucket "$BUCKET_SIZE") blocks"
        echo ""

        # Header
        printf "%-16s │ %8s %8s │ %8s %8s │ %7s\n" \
            "Block Range" "$LABEL1" "elapsed" "$LABEL2" "elapsed" "diff"
        printf "%-16s─┼─%8s─%8s─┼─%8s─%8s─┼─%7s\n" \
            "────────────────" "────────" "────────" "────────" "────────" "───────"

        # Build associative data from file2
        declare -A BPS2 ELAPSED2
        while IFS=$'\t' read -r bstart bend elapsed blocks bps; do
            BPS2[$bstart]="$bps"
            ELAPSED2[$bstart]="$elapsed"
        done < "$TMPDIR/s2.tsv"

        TOTAL_E1=0 TOTAL_B1=0 TOTAL_E2=0 TOTAL_B2=0
        OVERLAP_E1=0 OVERLAP_B1=0 OVERLAP_E2=0 OVERLAP_B2=0

        while IFS=$'\t' read -r bstart bend elapsed blocks bps; do
            range="$(format_bucket "$bstart")-$(format_bucket "$bend")"
            e1_fmt=$(format_elapsed "$elapsed")
            TOTAL_E1=$((TOTAL_E1 + elapsed))
            TOTAL_B1=$((TOTAL_B1 + blocks))

            if [[ -n "${BPS2[$bstart]:-}" ]]; then
                bps2="${BPS2[$bstart]}"
                e2="${ELAPSED2[$bstart]}"
                e2_fmt=$(format_elapsed "$e2")
                TOTAL_E2=$((TOTAL_E2 + e2))
                TOTAL_B2=$((TOTAL_B2 + blocks))
                OVERLAP_E1=$((OVERLAP_E1 + elapsed))
                OVERLAP_B1=$((OVERLAP_B1 + blocks))
                OVERLAP_E2=$((OVERLAP_E2 + e2))
                OVERLAP_B2=$((OVERLAP_B2 + blocks))

                if [[ "$bps2" -gt 0 ]]; then
                    diff_pct=$(awk "BEGIN {printf \"%.1f\", ($bps - $bps2) * 100 / $bps2}")
                    if [[ "${diff_pct:0:1}" != "-" ]]; then
                        diff_pct="+${diff_pct}"
                    fi
                else
                    diff_pct="N/A"
                fi
                printf "%-16s │ %7s/s %8s │ %7s/s %8s │ %6s%%\n" \
                    "$range" "$bps" "$e1_fmt" "$bps2" "$e2_fmt" "$diff_pct"
            elif [[ "$OVERLAP_ONLY" == "false" ]]; then
                printf "%-16s │ %7s/s %8s │ %8s %8s │ %7s\n" \
                    "$range" "$bps" "$e1_fmt" "—" "—" "—"
            fi
        done < "$TMPDIR/s1.tsv"

        # Print ranges only in server2
        if [[ "$OVERLAP_ONLY" == "false" ]]; then
            while IFS=$'\t' read -r bstart bend elapsed blocks bps; do
                if ! grep -q "^${bstart}	" "$TMPDIR/s1.tsv" 2>/dev/null; then
                    range="$(format_bucket "$bstart")-$(format_bucket "$bend")"
                    e2_fmt=$(format_elapsed "$elapsed")
                    printf "%-16s │ %8s %8s │ %7s/s %8s │ %7s\n" \
                        "$range" "—" "—" "$bps" "$e2_fmt" "—"
                fi
            done < "$TMPDIR/s2.tsv"
        fi

        # Summary
        echo ""
        echo "Summary (overlapping ranges only):"
        if [[ $OVERLAP_E1 -gt 0 && $OVERLAP_E2 -gt 0 ]]; then
            avg1=$((OVERLAP_B1 / OVERLAP_E1))
            avg2=$((OVERLAP_B2 / OVERLAP_E2))
            diff_pct=$(awk "BEGIN {printf \"%.1f\", ($avg1 - $avg2) * 100 / $avg2}")
            if [[ "${diff_pct:0:1}" != "-" ]]; then
                diff_pct="+${diff_pct}"
            fi
            printf "  %-12s avg %s blk/s over %s (%s blocks)\n" "$LABEL1:" "$avg1" "$(format_elapsed $OVERLAP_E1)" "$OVERLAP_B1"
            printf "  %-12s avg %s blk/s over %s (%s blocks)\n" "$LABEL2:" "$avg2" "$(format_elapsed $OVERLAP_E2)" "$OVERLAP_B2"
            echo "  Difference: ${diff_pct}% ($LABEL1 vs $LABEL2)"
        else
            echo "  No overlapping block ranges found."
        fi
        echo ""
    fi
fi
