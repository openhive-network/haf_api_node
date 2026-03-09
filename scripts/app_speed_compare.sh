#!/bin/bash
#
# HAF App Processing Speed Comparison
#
# Compares block processing speeds for HAF applications across two servers.
# Extracts timing data from docker logs and compares at overlapping block ranges.
#
# Apps compared: hafbe (block explorer), hivemind, reptracker, nfttracker, hivesense
#
# Usage:
#   ./scripts/app_speed_compare.sh \
#     --server1 steem-19.syncad.com --prefix1 haf10 --label1 "steem-19" \
#     --server2 steem-20.syncad.com --prefix2 haf-irrev --label2 "steem-20" \
#     [--bucket 5000000] [--apps "hafbe hivemind reptracker nfttracker hivesense"]

set -euo pipefail

# Defaults
BUCKET_SIZE=5000000
APPS="hafbe hivemind reptracker nfttracker hivesense"
COMPACT=false

# Server 1
SERVER1=""
PREFIX1=""
LABEL1="server1"

# Server 2
SERVER2=""
PREFIX2=""
LABEL2="server2"

usage() {
    cat <<'EOF'
Usage:
  app_speed_compare.sh \
    --server1 <host> --prefix1 <prefix> --label1 <label> \
    --server2 <host> --prefix2 <prefix> --label2 <label> \
    [--bucket N] [--apps "app1 app2 ..."] [--compact]

Options:
  --server1/2 <host>    SSH hostname for each server
  --prefix1/2 <prefix>  Docker container name prefix (e.g., haf10, haf-irrev)
  --label1/2 <label>    Display label (default: server1/server2)
  --bucket <N>          Block range bucket size (default: 5000000)
  --apps <list>         Space-separated app list (default: all)
                        Available: hafbe hivemind reptracker nfttracker hivesense
  --compact             Machine-readable TSV output

Examples:
  # Compare steem-19 vs steem-20
  app_speed_compare.sh \
    --server1 steem-19.syncad.com --prefix1 haf10 --label1 "steem-19" \
    --server2 steem-20.syncad.com --prefix2 haf-irrev --label2 "steem-20"

  # Only compare hivemind and hafbe with 10M buckets
  app_speed_compare.sh \
    --server1 steem-19.syncad.com --prefix1 haf10 --label1 "steem-19" \
    --server2 steem-20.syncad.com --prefix2 haf-irrev --label2 "steem-20" \
    --bucket 10000000 --apps "hafbe hivemind"
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server1)  SERVER1="$2"; shift 2 ;;
        --prefix1)  PREFIX1="$2"; shift 2 ;;
        --label1)   LABEL1="$2"; shift 2 ;;
        --server2)  SERVER2="$2"; shift 2 ;;
        --prefix2)  PREFIX2="$2"; shift 2 ;;
        --label2)   LABEL2="$2"; shift 2 ;;
        --bucket)   BUCKET_SIZE="$2"; shift 2 ;;
        --apps)     APPS="$2"; shift 2 ;;
        --compact)  COMPACT=true; shift ;;
        -h|--help)  usage ;;
        *)          echo "Unknown option: $1" >&2; usage ;;
    esac
done

if [[ -z "$SERVER1" || -z "$PREFIX1" || -z "$SERVER2" || -z "$PREFIX2" ]]; then
    echo "Error: --server1, --prefix1, --server2, and --prefix2 are required" >&2
    usage
fi

########## Container name mapping ##########

container_name() {
    local prefix="$1" app="$2"
    case "$app" in
        hafbe)      echo "${prefix}-block-explorer-block-processing-1" ;;
        hivemind)   echo "${prefix}-hivemind-block-processing-1" ;;
        reptracker) echo "${prefix}-reputation-tracker-block-processing-1" ;;
        nfttracker) echo "${prefix}-nft-tracker-block-processing-1" ;;
        hivesense)  echo "${prefix}-hivesense-sync-1" ;;
        *)          echo "Unknown app: $app" >&2; return 1 ;;
    esac
}

app_display_name() {
    case "$1" in
        hafbe)      echo "Block Explorer (hafbe)" ;;
        hivemind)   echo "Hivemind" ;;
        reptracker) echo "Reputation Tracker" ;;
        nfttracker) echo "NFT Tracker" ;;
        hivesense)  echo "Hivesense" ;;
    esac
}

# Rate unit per app (hivesense processes ops, others process blocks)
app_unit() {
    case "$1" in
        hivesense) echo "op" ;;
        *)         echo "blk" ;;
    esac
}

# Throughput label per app
app_rate_label() {
    case "$1" in
        hivesense) echo "ops/s" ;;
        *)         echo "blk/s" ;;
    esac
}

########## Log fetching ##########

# Fetch filtered docker logs from a remote server
# Usage: fetch_logs <server> <container> <grep_pattern>
fetch_logs() {
    local server="$1" container="$2" pattern="$3"
    ssh "$server" "docker logs '$container' 2>&1 | grep -E '$pattern'" 2>/dev/null || true
}

########## Per-app log parsers ##########
# Each outputs: block_end\tblocks_processed\tseconds

# Block Explorer: pairs "Attempting to process <START, END>" with "Processed blocks in X seconds"
parse_hafbe() {
    awk '
    /\[MASSIVE\] Attempting/ {
        gsub(/[<>,]/, " ")
        n = split($0, f, " ")
        for (i = 1; i <= n; i++) {
            if (f[i] == "range:") {
                pending_start = f[i+1] + 0
                pending_end = f[i+2] + 0
                break
            }
        }
    }
    /Processed blocks in/ {
        secs = 0
        for (i = 1; i <= NF; i++) {
            if ($i == "in" && $(i+2) == "seconds") {
                secs = $(i+1) + 0
                break
            }
        }
        if (pending_end > 0 && secs > 0) {
            printf "%d\t%d\t%.3f\n", pending_end, pending_end - pending_start, secs
        }
        pending_start = 0; pending_end = 0
    }'
}

# Hivemind: [PHASE-SUMMARY] blocks=START-END total=X.XXXs
parse_hivemind() {
    awk '
    /\[PHASE-SUMMARY\]/ {
        start = 0; end_b = 0; secs = 0
        for (i = 1; i <= NF; i++) {
            if (index($i, "blocks=") == 1) {
                val = $i
                sub(/blocks=/, "", val)
                split(val, range, "-")
                start = range[1] + 0
                end_b = range[2] + 0
            }
            if (index($i, "total=") == 1) {
                val = $i
                sub(/total=/, "", val)
                sub(/s$/, "", val)
                secs = val + 0
            }
        }
        if (end_b > 0 && secs > 0) {
            printf "%d\t%d\t%.3f\n", end_b, end_b - start, secs
        }
    }'
}

# Reptracker: "processed block range: <START, END> successfully in X.XXXXXX s"
parse_reptracker() {
    awk '
    /processed block range:.*successfully in/ {
        gsub(/[<>,]/, " ")
        start = 0; end_b = 0; secs = 0
        for (i = 1; i <= NF; i++) {
            if ($i == "range:") {
                start = $(i+1) + 0
                end_b = $(i+2) + 0
            }
            if ($i == "in" && $(i+2) == "s") {
                secs = $(i+1) + 0
            }
        }
        if (end_b > 0 && secs > 0) {
            printf "%d\t%d\t%.3f\n", end_b, end_b - start, secs
        }
    }'
}

# NFT Tracker: same format as reptracker
parse_nfttracker() {
    parse_reptracker
}

# Hivesense: "Applied N ops ... in X.Xs ... block=N"
# Outputs ops count and time, bucketed by block position
parse_hivesense() {
    awk '
    /Applied.*ops.*block=/ {
        ops = 0; secs = 0; block = 0
        for (i = 1; i <= NF; i++) {
            if ($i == "Applied") {
                ops = $(i+1) + 0
            }
            if ($i == "in") {
                val = $(i+1)
                sub(/s$/, "", val)
                secs = val + 0
            }
            if (index($i, "block=") == 1) {
                val = $i
                sub(/block=/, "", val)
                block = val + 0
            }
        }
        if (block > 0 && ops > 0 && secs > 0) {
            printf "%d\t%d\t%.3f\n", block, ops, secs
        }
    }'
}

########## Grep patterns per app (for remote filtering) ##########

grep_pattern() {
    case "$1" in
        hafbe)      echo '\[MASSIVE\] Attempting|Processed blocks in' ;;
        hivemind)   echo '\[PHASE-SUMMARY\]' ;;
        reptracker) echo 'processed block range:.*successfully in' ;;
        nfttracker) echo 'processed block range:.*successfully in' ;;
        hivesense)  echo 'Applied.*ops.*block=' ;;
    esac
}

########## Bucketing ##########

# Input: block_end\tblocks\tseconds
# Output: bucket_start\tbucket_end\ttotal_blocks\ttotal_seconds\tblocks_per_sec
compute_buckets() {
    local bucket_size="$1"
    awk -v bs="$bucket_size" '
    {
        block = $1 + 0
        blocks = $2 + 0
        secs = $3 + 0
        bucket = int((block - 1) / bs) * bs
        total_b[bucket] += blocks
        total_s[bucket] += secs
        if (!(bucket in seen)) {
            seen[bucket] = 1
            order[++n] = bucket
        }
    }
    END {
        for (i = 1; i <= n; i++) {
            b = order[i]
            if (total_s[b] > 0) {
                bps = total_b[b] / total_s[b]
                printf "%d\t%d\t%d\t%.1f\t%.0f\n", b, b + bs, total_b[b], total_s[b], bps
            }
        }
    }'
}

########## Formatting helpers ##########

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
    local secs="${1%.*}"  # truncate decimals
    local hours=$((secs / 3600))
    local mins=$(((secs % 3600) / 60))
    if [[ $hours -gt 0 ]]; then
        printf "%dh%02dm" "$hours" "$mins"
    elif [[ $mins -gt 0 ]]; then
        printf "%dm%02ds" "$mins" "$((secs % 60))"
    else
        printf "%ds" "$secs"
    fi
}

########## Extract & bucket data for one server+app ##########

extract_app_data() {
    local server="$1" prefix="$2" app="$3" bucket_size="$4"
    local container pattern

    container=$(container_name "$prefix" "$app")
    pattern=$(grep_pattern "$app")

    fetch_logs "$server" "$container" "$pattern" | "parse_${app}" | compute_buckets "$bucket_size"
}

########## Main ##########

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

if [[ "$COMPACT" != "true" ]]; then
    echo "HAF App Processing Speed Comparison"
    echo "  $LABEL1: $SERVER1 (prefix: $PREFIX1)"
    echo "  $LABEL2: $SERVER2 (prefix: $PREFIX2)"
    echo "  Bucket size: $(format_bucket "$BUCKET_SIZE") blocks"
    echo ""
fi

ANY_DATA=false

for app in $APPS; do
    display_name=$(app_display_name "$app")

    if [[ "$COMPACT" != "true" ]]; then
        echo "Extracting $display_name logs..." >&2
    fi

    # Extract data from both servers in parallel
    extract_app_data "$SERVER1" "$PREFIX1" "$app" "$BUCKET_SIZE" > "$TMPDIR/${app}_1.tsv" &
    extract_app_data "$SERVER2" "$PREFIX2" "$app" "$BUCKET_SIZE" > "$TMPDIR/${app}_2.tsv" &
    wait

    # Skip if no data from either server
    if [[ ! -s "$TMPDIR/${app}_1.tsv" && ! -s "$TMPDIR/${app}_2.tsv" ]]; then
        if [[ "$COMPACT" != "true" ]]; then
            echo "  No data found, skipping."
            echo ""
        fi
        continue
    fi

    if [[ ! -s "$TMPDIR/${app}_1.tsv" ]]; then
        if [[ "$COMPACT" != "true" ]]; then
            echo "  No data from $LABEL1, skipping."
            echo ""
        fi
        continue
    fi

    if [[ ! -s "$TMPDIR/${app}_2.tsv" ]]; then
        if [[ "$COMPACT" != "true" ]]; then
            echo "  No data from $LABEL2, skipping."
            echo ""
        fi
        continue
    fi

    ANY_DATA=true

    # Sort by bucket start
    sort -t$'\t' -k1,1n "$TMPDIR/${app}_1.tsv" > "$TMPDIR/${app}_s1.tsv"
    sort -t$'\t' -k1,1n "$TMPDIR/${app}_2.tsv" > "$TMPDIR/${app}_s2.tsv"

    if [[ "$COMPACT" == "true" ]]; then
        printf "# %s\n" "$app"
        printf "range\t%s_bps\t%s_elapsed\t%s_bps\t%s_elapsed\tdiff_pct\n" "$LABEL1" "$LABEL1" "$LABEL2" "$LABEL2"
        join -t$'\t' -j1 -o '1.1,1.5,1.4,2.5,2.4' "$TMPDIR/${app}_s1.tsv" "$TMPDIR/${app}_s2.tsv" | \
            awk -F'\t' '{if($4>0) printf "%s\t%s\t%s\t%s\t%s\t%.1f\n", $1, $2, $3, $4, $5, ($2-$4)*100/$4}'
        echo ""
        continue
    fi

    # Pretty output
    unit=$(app_unit "$app")
    rate_label=$(app_rate_label "$app")

    echo "━━━ $display_name ━━━"
    echo ""

    printf "%-16s │ %10s %8s │ %10s %8s │ %7s\n" \
        "Block Range" "$LABEL1" "elapsed" "$LABEL2" "elapsed" "diff"
    printf "%-16s─┼─%10s─%8s─┼─%10s─%8s─┼─%7s\n" \
        "────────────────" "──────────" "────────" "──────────" "────────" "───────"

    # Load server2 data into temp lookup file
    # (can't use bash associative arrays portably with subshells)
    declare -A BPS2 ELAPSED2
    while IFS=$'\t' read -r bstart bend blocks secs bps; do
        BPS2[$bstart]="$bps"
        ELAPSED2[$bstart]="$secs"
    done < "$TMPDIR/${app}_s2.tsv"

    OVERLAP_E1=0 OVERLAP_B1=0 OVERLAP_E2=0 OVERLAP_B2=0
    SHOWN=0

    while IFS=$'\t' read -r bstart bend blocks secs bps; do
        range="$(format_bucket "$bstart")-$(format_bucket "$bend")"
        e1_fmt=$(format_elapsed "$secs")

        if [[ -n "${BPS2[$bstart]:-}" ]]; then
            bps2="${BPS2[$bstart]}"
            e2="${ELAPSED2[$bstart]}"
            e2_fmt=$(format_elapsed "$e2")

            OVERLAP_B1=$((OVERLAP_B1 + blocks))
            OVERLAP_E1=$(awk "BEGIN {printf \"%.1f\", $OVERLAP_E1 + $secs}")
            OVERLAP_B2=$((OVERLAP_B2 + blocks))
            OVERLAP_E2=$(awk "BEGIN {printf \"%.1f\", $OVERLAP_E2 + $e2}")

            if [[ "$bps2" -gt 0 ]] 2>/dev/null; then
                diff_pct=$(awk "BEGIN {printf \"%.1f\", ($bps - $bps2) * 100 / $bps2}")
                if [[ "${diff_pct:0:1}" != "-" ]]; then
                    diff_pct="+${diff_pct}"
                fi
            else
                diff_pct="N/A"
            fi

            printf "%-16s │ %9s/s %8s │ %9s/s %8s │ %6s%%\n" \
                "$range" "$bps" "$e1_fmt" "$bps2" "$e2_fmt" "$diff_pct"
            SHOWN=$((SHOWN + 1))
        fi
    done < "$TMPDIR/${app}_s1.tsv"

    # Clean up associative arrays
    unset BPS2 ELAPSED2

    if [[ $SHOWN -eq 0 ]]; then
        echo "  No overlapping block ranges found."
    else
        # Summary for this app
        echo ""
        if [[ $(awk "BEGIN {print ($OVERLAP_E1 > 0 && $OVERLAP_E2 > 0)}") -eq 1 ]]; then
            avg1=$(awk "BEGIN {printf \"%.0f\", $OVERLAP_B1 / $OVERLAP_E1}")
            avg2=$(awk "BEGIN {printf \"%.0f\", $OVERLAP_B2 / $OVERLAP_E2}")
            diff_pct=$(awk "BEGIN {printf \"%.1f\", ($avg1 - $avg2) * 100 / $avg2}")
            if [[ "${diff_pct:0:1}" != "-" ]]; then
                diff_pct="+${diff_pct}"
            fi
            printf "  %-12s avg %s %s\n" "$LABEL1:" "$avg1" "$rate_label"
            printf "  %-12s avg %s %s\n" "$LABEL2:" "$avg2" "$rate_label"
            echo "  Difference: ${diff_pct}%"
        fi
    fi

    echo ""
done

if [[ "$ANY_DATA" == "false" ]]; then
    echo "No app data found on either server." >&2
    exit 1
fi
