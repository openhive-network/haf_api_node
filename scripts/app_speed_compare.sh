#!/bin/bash
#
# HAF App Processing Speed Comparison
#
# Compares block processing speeds for HAF applications across two servers.
# Extracts timing data from docker logs or saved log files and compares
# at overlapping block ranges.
#
# Apps compared: hafbe (block explorer), hivemind, reptracker, nfttracker, hivesense
#
# Usage:
#   # Compare two live servers
#   ./scripts/app_speed_compare.sh \
#     --server1 steem-19.syncad.com --prefix1 haf10 --label1 "steem-19" \
#     --server2 steem-20.syncad.com --prefix2 haf-irrev --label2 "steem-20"
#
#   # Compare live server against saved logs
#   ./scripts/app_speed_compare.sh \
#     --server1 steem-19.syncad.com --prefix1 haf10 --label1 "steem-19" \
#     --logs2 /path/to/saved/logs --label2 "rc8"
#
#   # Compare two sets of saved logs (remote directories)
#   ./scripts/app_speed_compare.sh \
#     --logs1 steem-20:/haf-pool/syncad/haf_api_node_rc8/logs/20260304T001146Z --label1 "rc8" \
#     --logs2 steem-20:/haf-pool/syncad/haf_api_node_irrev/logs/20260309T000000Z --label2 "irrev"

set -euo pipefail

# Defaults
BUCKET_SIZE=5000000
APPS="hafbe hivemind reptracker nfttracker hivesense"
COMPACT=false

# Server 1 (live docker mode)
SERVER1=""
PREFIX1=""
LABEL1="server1"
LOGS1=""

# Server 2 (live docker mode)
SERVER2=""
PREFIX2=""
LABEL2="server2"
LOGS2=""

usage() {
    cat <<'EOF'
Usage:
  Live docker mode:
    app_speed_compare.sh \
      --server1 <host> --prefix1 <prefix> --label1 <label> \
      --server2 <host> --prefix2 <prefix> --label2 <label> \
      [--bucket N] [--apps "app1 app2 ..."] [--compact]

  Saved log files mode:
    app_speed_compare.sh \
      --logs1 <path> --label1 <label> \
      --logs2 <path> --label2 <label>

  Mixed mode (live vs saved):
    app_speed_compare.sh \
      --server1 <host> --prefix1 <prefix> --label1 <label> \
      --logs2 <path> --label2 <label>

Options:
  --server1/2 <host>    SSH hostname for each server (live docker mode)
  --prefix1/2 <prefix>  Docker container name prefix (e.g., haf10, haf-irrev)
  --logs1/2 <path>      Path to saved log files. Can be:
                         - Local directory containing *.log or *.log.zst files
                         - Remote directory: host:/path/to/logs
                         - A .tar.zst archive (local or remote host:/path/to.tar.zst)
  --label1/2 <label>    Display label (default: server1/server2)
  --bucket <N>          Block range bucket size (default: 5000000)
  --apps <list>         Space-separated app list (default: all)
                        Available: hafbe hivemind reptracker nfttracker hivesense
  --compact             Machine-readable TSV output

Log file naming:
  Log files should be named: block-explorer-block-processing.log[.zst]
  hivemind-block-processing.log[.zst], reputation-tracker-block-processing.log[.zst]
  nft-tracker-block-processing.log[.zst], hivesense-sync.log[.zst]
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
        --logs1)    LOGS1="$2"; shift 2 ;;
        --logs2)    LOGS2="$2"; shift 2 ;;
        --bucket)   BUCKET_SIZE="$2"; shift 2 ;;
        --apps)     APPS="$2"; shift 2 ;;
        --compact)  COMPACT=true; shift ;;
        -h|--help)  usage ;;
        *)          echo "Unknown option: $1" >&2; usage ;;
    esac
done

# Validate: each side needs either (server + prefix) or logs
side1_live=false
side2_live=false

if [[ -n "$SERVER1" && -n "$PREFIX1" ]]; then
    side1_live=true
elif [[ -n "$LOGS1" ]]; then
    side1_live=false
else
    echo "Error: side 1 needs --server1 + --prefix1, or --logs1" >&2
    usage
fi

if [[ -n "$SERVER2" && -n "$PREFIX2" ]]; then
    side2_live=true
elif [[ -n "$LOGS2" ]]; then
    side2_live=false
else
    echo "Error: side 2 needs --server2 + --prefix2, or --logs2" >&2
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

# Log file base name per app (without .log or .log.zst extension)
log_basename() {
    case "$1" in
        hafbe)      echo "block-explorer-block-processing" ;;
        hivemind)   echo "hivemind-block-processing" ;;
        reptracker) echo "reputation-tracker-block-processing" ;;
        nfttracker) echo "nft-tracker-block-processing" ;;
        hivesense)  echo "hivesense-sync" ;;
        *)          echo "Unknown app: $1" >&2; return 1 ;;
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
# Usage: fetch_docker_logs <server> <container> <grep_pattern>
fetch_docker_logs() {
    local server="$1" container="$2" pattern="$3"
    ssh "$server" "docker logs '$container' 2>&1 | grep -E '$pattern'" 2>/dev/null || true
}

# Read a log file (local or remote), handling .zst compression
# Usage: read_log_file <path>
# <path> can be local or host:/remote/path
read_log_file() {
    local path="$1"
    local remote_host="" remote_path=""

    # Check for host:/path pattern
    if [[ "$path" == *:/* ]]; then
        remote_host="${path%%:*}"
        remote_path="${path#*:}"
        if [[ "$remote_path" == *.zst ]]; then
            ssh "$remote_host" "zstdcat '$remote_path'" 2>/dev/null || true
        else
            ssh "$remote_host" "cat '$remote_path'" 2>/dev/null || true
        fi
    else
        if [[ "$path" == *.zst ]]; then
            zstdcat "$path" 2>/dev/null || true
        else
            cat "$path" 2>/dev/null || true
        fi
    fi
}

# Find and read the log file for a given app from a logs path
# Usage: fetch_file_logs <logs_path> <app> <grep_pattern>
fetch_file_logs() {
    local logs_path="$1" app="$2" pattern="$3"
    local basename
    basename=$(log_basename "$app")

    local remote_host="" dir_path=""

    # Parse host:/path
    if [[ "$logs_path" == *:/* ]]; then
        remote_host="${logs_path%%:*}"
        dir_path="${logs_path#*:}"
    else
        dir_path="$logs_path"
    fi

    # Check if it's an archive (.tar.zst) - decompress to temp dir
    if [[ "$dir_path" == *.tar.zst ]]; then
        local extract_dir="$TMPDIR/logs_${app}_$$"
        mkdir -p "$extract_dir"
        if [[ -n "$remote_host" ]]; then
            ssh "$remote_host" "cat '$dir_path'" 2>/dev/null | zstd -d | tar xf - -C "$extract_dir" 2>/dev/null
        else
            zstdcat "$dir_path" 2>/dev/null | tar xf - -C "$extract_dir" 2>/dev/null
        fi
        # Find the log file in extracted content
        local found
        found=$(find "$extract_dir" -name "${basename}.log*" -print -quit 2>/dev/null)
        if [[ -n "$found" ]]; then
            read_log_file "$found" | grep -E "$pattern" || true
        fi
        return
    fi

    # Directory mode: try .log.zst first, then .log
    if [[ -n "$remote_host" ]]; then
        # Remote directory
        local file
        file=$(ssh "$remote_host" "ls '$dir_path/${basename}.log.zst' '$dir_path/${basename}.log' 2>/dev/null | head -1" 2>/dev/null)
        if [[ -n "$file" ]]; then
            read_log_file "${remote_host}:${file}" | grep -E "$pattern" || true
        fi
    else
        # Local directory
        if [[ -f "$dir_path/${basename}.log.zst" ]]; then
            read_log_file "$dir_path/${basename}.log.zst" | grep -E "$pattern" || true
        elif [[ -f "$dir_path/${basename}.log" ]]; then
            read_log_file "$dir_path/${basename}.log" | grep -E "$pattern" || true
        fi
    fi
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

########## Extract & bucket data for one side+app ##########

# Unified extraction: works with live docker or log files
# Usage: extract_app_data <side> <app> <bucket_size>
# <side> is 1 or 2
extract_app_data() {
    local side="$1" app="$2" bucket_size="$3"
    local pattern
    pattern=$(grep_pattern "$app")

    if [[ "$side" == "1" ]]; then
        if [[ "$side1_live" == "true" ]]; then
            local container
            container=$(container_name "$PREFIX1" "$app")
            fetch_docker_logs "$SERVER1" "$container" "$pattern"
        else
            fetch_file_logs "$LOGS1" "$app" "$pattern"
        fi
    else
        if [[ "$side2_live" == "true" ]]; then
            local container
            container=$(container_name "$PREFIX2" "$app")
            fetch_docker_logs "$SERVER2" "$container" "$pattern"
        else
            fetch_file_logs "$LOGS2" "$app" "$pattern"
        fi
    fi | "parse_${app}" | compute_buckets "$bucket_size"
}

########## Format source description ##########

source_desc() {
    local side="$1"
    if [[ "$side" == "1" ]]; then
        if [[ "$side1_live" == "true" ]]; then
            echo "$SERVER1 (prefix: $PREFIX1)"
        else
            echo "logs: $LOGS1"
        fi
    else
        if [[ "$side2_live" == "true" ]]; then
            echo "$SERVER2 (prefix: $PREFIX2)"
        else
            echo "logs: $LOGS2"
        fi
    fi
}

########## Main ##########

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

if [[ "$COMPACT" != "true" ]]; then
    echo "HAF App Processing Speed Comparison"
    echo "  $LABEL1: $(source_desc 1)"
    echo "  $LABEL2: $(source_desc 2)"
    echo "  Bucket size: $(format_bucket "$BUCKET_SIZE") blocks"
    echo ""
fi

ANY_DATA=false

for app in $APPS; do
    display_name=$(app_display_name "$app")

    if [[ "$COMPACT" != "true" ]]; then
        echo "Extracting $display_name logs..." >&2
    fi

    # Extract data from both sides in parallel
    extract_app_data 1 "$app" "$BUCKET_SIZE" > "$TMPDIR/${app}_1.tsv" &
    extract_app_data 2 "$app" "$BUCKET_SIZE" > "$TMPDIR/${app}_2.tsv" &
    wait

    # Skip if no data from either side
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
