#!/bin/bash
#
# HAF Replay Metrics Collector
#
# Periodically collects system and database metrics during replay,
# writing them to a TSV file for later analysis.
#
# Usage:
#   # Collect every 60s, write to metrics.tsv
#   ./replay_metrics_collector.sh --container haf-1 --interval 60 --output metrics.tsv
#
#   # Remote server
#   ./replay_metrics_collector.sh --server steem-20.syncad.com --container haf-irrev-haf-1
#
#   # One-shot (for use with external cron/loop)
#   ./replay_metrics_collector.sh --container haf-1 --once
#
# Output columns (TSV):
#   timestamp, block_num, blocks_since_last, elapsed_since_last, blocks_per_sec,
#   cpu_user_pct, cpu_sys_pct, cpu_iowait_pct, cpu_idle_pct,
#   mem_used_mb, mem_available_mb, swap_used_mb,
#   arc_hit_pct, arc_size_mb, arc_target_mb,
#   pg_shared_buffers_mb, pg_checkpoints, pg_buffers_written_checkpoint,
#   pg_buffers_written_backend, pg_blks_hit, pg_blks_read, pg_cache_hit_pct,
#   disk_read_kbs, disk_write_kbs,
#   pg_total_size_gb

set -euo pipefail

# Defaults
INTERVAL=60
OUTPUT=""
SERVER=""
CONTAINER=""
ONCE=false
PERF=false
PERF_DURATION=10

usage() {
    cat <<'EOF'
Usage: replay_metrics_collector.sh [options]

Options:
  --container <name>    Docker container name (required)
  --server <host>       SSH hostname (omit for local)
  --interval <secs>     Collection interval in seconds (default: 60)
  --output <file>       Output TSV file (default: stdout)
  --once                Collect one sample and exit
  --perf                Collect CPU perf counters (requires sudo, ~zero overhead)
  --perf-duration <s>   perf stat sample window in seconds (default: 10)
  -h, --help            Show this help
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --container)  CONTAINER="$2"; shift 2 ;;
        --server)     SERVER="$2"; shift 2 ;;
        --interval)   INTERVAL="$2"; shift 2 ;;
        --output|-o)  OUTPUT="$2"; shift 2 ;;
        --once)       ONCE=true; shift ;;
        --perf)       PERF=true; shift ;;
        --perf-duration) PERF_DURATION="$2"; shift 2 ;;
        -h|--help)    usage ;;
        *)            echo "Unknown option: $1" >&2; usage ;;
    esac
done

if [[ -z "$CONTAINER" ]]; then
    echo "Error: --container is required" >&2
    usage
fi

# Run a command locally or via SSH
run_cmd() {
    if [[ -n "$SERVER" ]]; then
        ssh -o ConnectTimeout=10 "$SERVER" "$1" 2>/dev/null
    else
        eval "$1" 2>/dev/null
    fi
}

COLUMNS="timestamp\tblock_num\tblks_since_last\telapsed_s\tblk_per_sec\tcpu_user\tcpu_sys\tcpu_iowait\tcpu_idle\tmem_used_mb\tmem_avail_mb\tswap_used_mb\tarc_hit_pct\tarc_size_mb\tarc_target_mb\tpg_checkpoints\tpg_bufs_ckpt\tpg_bufs_backend\tpg_blks_hit\tpg_blks_read\tpg_cache_hit_pct\tdisk_read_kbs\tdisk_write_kbs\tpg_total_size_gb"
if [[ "$PERF" == "true" ]]; then
    COLUMNS="${COLUMNS}\tipc\tstalled_per_insn\tcache_miss_pct\tbranch_miss_pct\tl1d_miss_pct"
fi

# Write header if output file doesn't exist or is empty
write_header() {
    if [[ -n "$OUTPUT" ]]; then
        if [[ ! -f "$OUTPUT" || ! -s "$OUTPUT" ]]; then
            echo -e "$COLUMNS" > "$OUTPUT"
        fi
    else
        echo -e "$COLUMNS"
    fi
}

PREV_BLOCK=""
PREV_TS=""

collect_sample() {
    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%S')
    local now_epoch
    now_epoch=$(date +%s)

    # Collect all metrics in one SSH session to minimize overhead
    local raw
    raw=$(run_cmd "
        echo '=== BLOCK ==='
        docker exec $CONTAINER psql -U haf_admin -d haf_block_log -t -A -c 'SELECT consistent_block FROM hafd.hive_state' 2>/dev/null || echo 0

        echo '=== CPU ==='
        grep '^cpu ' /proc/stat

        echo '=== MEM ==='
        free -m | grep -E '^Mem:|^Swap:'

        echo '=== ARC ==='
        cat /proc/spl/kstat/zfs/arcstats 2>/dev/null | grep -E '^(hits|misses|size|c) '

        echo '=== PG_STAT ==='
        docker exec $CONTAINER psql -U haf_admin -d haf_block_log -t -A -c \"
            SELECT
                COALESCE((SELECT num_timed + num_requested FROM pg_stat_checkpointer), 0),
                COALESCE((SELECT buffers_written FROM pg_stat_checkpointer), 0),
                COALESCE((SELECT buffers_alloc FROM pg_stat_bgwriter), 0),
                COALESCE(sum(blks_hit), 0),
                COALESCE(sum(blks_read), 0)
            FROM pg_stat_database WHERE datname = 'haf_block_log'
        \" 2>/dev/null || echo '0|0|0|0|0'

        echo '=== DISKIO ==='
        cat /proc/diskstats | grep -E 'nvme[0-9]+n[0-9]+ ' | head -4

        echo '=== PGSIZE ==='
        docker exec $CONTAINER psql -U haf_admin -d haf_block_log -t -A -c \"SELECT pg_database_size('haf_block_log')\" 2>/dev/null || echo 0
    " || echo "ERROR")

    if [[ "$raw" == "ERROR" || -z "$raw" ]]; then
        echo "Warning: failed to collect metrics at $now" >&2
        return
    fi

    # Parse block number
    local block_num
    block_num=$(echo "$raw" | sed -n '/=== BLOCK ===/,/=== CPU ===/p' | grep -E '^[0-9]+$' | head -1)
    block_num=${block_num:-0}

    # Compute blocks/sec since last sample
    local blks_since_last=0 elapsed_since_last=0 bps=0
    if [[ -n "$PREV_BLOCK" && -n "$PREV_TS" ]]; then
        blks_since_last=$((block_num - PREV_BLOCK))
        elapsed_since_last=$((now_epoch - PREV_TS))
        if [[ $elapsed_since_last -gt 0 ]]; then
            bps=$((blks_since_last / elapsed_since_last))
        fi
    fi
    PREV_BLOCK=$block_num
    PREV_TS=$now_epoch

    # Parse CPU from /proc/stat (cumulative, but we report instantaneous via percentages)
    local cpu_line
    cpu_line=$(echo "$raw" | sed -n '/=== CPU ===/,/=== MEM ===/p' | grep '^cpu ')
    local cpu_user cpu_nice cpu_sys cpu_idle cpu_iowait cpu_total
    if [[ -n "$cpu_line" ]]; then
        read -r _ cpu_user cpu_nice cpu_sys cpu_idle cpu_iowait _ <<< "$cpu_line"
        # We'll report the raw jiffies - delta computation would need state
        # Instead, use the simple approach: report from /proc/stat deltas
        cpu_total=$((cpu_user + cpu_nice + cpu_sys + cpu_idle + cpu_iowait))
    fi

    # For instantaneous CPU, use a 1-second sample
    local cpu_pct
    cpu_pct=$(run_cmd "top -bn1 | grep '%Cpu' | head -1" || echo "")
    local cpu_us=0 cpu_sy=0 cpu_wa=0 cpu_id=100
    if [[ -n "$cpu_pct" ]]; then
        cpu_us=$(echo "$cpu_pct" | grep -oP '[\d.]+(?= us)' || echo "0")
        cpu_sy=$(echo "$cpu_pct" | grep -oP '[\d.]+(?= sy)' || echo "0")
        cpu_wa=$(echo "$cpu_pct" | grep -oP '[\d.]+(?= wa)' || echo "0")
        cpu_id=$(echo "$cpu_pct" | grep -oP '[\d.]+(?= id)' || echo "100")
    fi

    # Parse memory
    local mem_line swap_line
    mem_line=$(echo "$raw" | sed -n '/=== MEM ===/,/=== ARC ===/p' | grep '^Mem:')
    swap_line=$(echo "$raw" | sed -n '/=== MEM ===/,/=== ARC ===/p' | grep '^Swap:')
    local mem_used=0 mem_avail=0 swap_used=0
    if [[ -n "$mem_line" ]]; then
        mem_used=$(echo "$mem_line" | awk '{print $3}')
        mem_avail=$(echo "$mem_line" | awk '{print $7}')
    fi
    if [[ -n "$swap_line" ]]; then
        swap_used=$(echo "$swap_line" | awk '{print $3}')
    fi

    # Parse ARC
    local arc_section
    arc_section=$(echo "$raw" | sed -n '/=== ARC ===/,/=== PG_STAT ===/p')
    local arc_hits=0 arc_misses=0 arc_size=0 arc_target=0 arc_hit_pct=0
    arc_hits=$(echo "$arc_section" | grep '^hits ' | awk '{print $3}')
    arc_misses=$(echo "$arc_section" | grep '^misses ' | awk '{print $3}')
    arc_size=$(echo "$arc_section" | grep '^size ' | awk '{print $3}')
    arc_target=$(echo "$arc_section" | grep '^c ' | awk '{print $3}')
    arc_hits=${arc_hits:-0}
    arc_misses=${arc_misses:-0}
    arc_size=${arc_size:-0}
    arc_target=${arc_target:-0}
    local arc_size_mb=$((arc_size / 1048576))
    local arc_target_mb=$((arc_target / 1048576))
    if [[ $((arc_hits + arc_misses)) -gt 0 ]]; then
        arc_hit_pct=$(awk "BEGIN {printf \"%.1f\", $arc_hits * 100 / ($arc_hits + $arc_misses)}")
    fi

    # Parse PG stats
    local pg_stats
    pg_stats=$(echo "$raw" | sed -n '/=== PG_STAT ===/,/=== DISKIO ===/p' | grep -E '^[0-9]' | head -1)
    local pg_ckpt=0 pg_bufs_ckpt=0 pg_bufs_backend=0 pg_blks_hit=0 pg_blks_read=0 pg_cache_hit_pct=0
    if [[ -n "$pg_stats" ]]; then
        IFS='|' read -r pg_ckpt pg_bufs_ckpt pg_bufs_backend pg_blks_hit pg_blks_read <<< "$pg_stats"
        if [[ $((pg_blks_hit + pg_blks_read)) -gt 0 ]]; then
            pg_cache_hit_pct=$(awk "BEGIN {printf \"%.1f\", $pg_blks_hit * 100 / ($pg_blks_hit + $pg_blks_read)}")
        fi
    fi

    # Parse disk I/O (aggregate across NVMe devices)
    local disk_section
    disk_section=$(echo "$raw" | sed -n '/=== DISKIO ===/,/=== PGSIZE ===/p' | grep -E 'nvme')
    local disk_read_sectors=0 disk_write_sectors=0
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            local rs ws
            rs=$(echo "$line" | awk '{print $6}')
            ws=$(echo "$line" | awk '{print $10}')
            disk_read_sectors=$((disk_read_sectors + rs))
            disk_write_sectors=$((disk_write_sectors + ws))
        fi
    done <<< "$disk_section"
    # Sectors are 512 bytes; convert to KB (cumulative, but useful for delta between samples)
    local disk_read_kb=$((disk_read_sectors / 2))
    local disk_write_kb=$((disk_write_sectors / 2))

    # Parse PG database size
    local pg_size_bytes
    pg_size_bytes=$(echo "$raw" | sed -n '/=== PGSIZE ===/,//p' | grep -E '^[0-9]+$' | head -1)
    pg_size_bytes=${pg_size_bytes:-0}
    local pg_size_gb
    pg_size_gb=$(awk "BEGIN {printf \"%.1f\", $pg_size_bytes / 1073741824}")

    # Collect perf counters if enabled
    local perf_suffix=""
    if [[ "$PERF" == "true" ]]; then
        local perf_raw
        perf_raw=$(run_cmd "
            HPID=\$(docker top $CONTAINER -o pid,comm 2>/dev/null | grep hived | head -1 | awk '{print \$1}')
            if [ -n \"\$HPID\" ]; then
                sudo perf stat -p \$HPID -e cycles,instructions,cache-misses,cache-references,L1-dcache-load-misses,L1-dcache-loads,branch-misses,branches,stalled-cycles-frontend sleep $PERF_DURATION 2>&1
            fi
        " || echo "")

        local ipc=0 stalled_per_insn=0 cache_miss_pct=0 branch_miss_pct=0 l1d_miss_pct=0
        if [[ -n "$perf_raw" ]]; then
            # Extract IPC (e.g., "1.60  insn per cycle")
            ipc=$(echo "$perf_raw" | grep -oP '[\d.]+(?=\s+insn per cycle)' || echo "0")
            # Extract stalled cycles per insn (e.g., "0.09  stalled cycles per insn")
            stalled_per_insn=$(echo "$perf_raw" | grep -oP '[\d.]+(?=\s+stalled cycles per insn)' || echo "0")
            # Extract cache miss % (e.g., "16.39% of all cache refs")
            cache_miss_pct=$(echo "$perf_raw" | grep -oP '[\d.]+(?=%\s+of all cache refs)' || echo "0")
            # Extract branch miss % (e.g., "1.41% of all branches")
            branch_miss_pct=$(echo "$perf_raw" | grep -oP '[\d.]+(?=%\s+of all branches)' || echo "0")
            # Extract L1-dcache miss % (e.g., "3.05% of all L1-dcache accesses")
            l1d_miss_pct=$(echo "$perf_raw" | grep -oP '[\d.]+(?=%\s+of all L1-dcache)' || echo "0")
        fi
        perf_suffix=$(printf "\t%s\t%s\t%s\t%s\t%s" "$ipc" "$stalled_per_insn" "$cache_miss_pct" "$branch_miss_pct" "$l1d_miss_pct")
    fi

    # Format output line
    local line
    line=$(printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s%s" \
        "$now" "$block_num" "$blks_since_last" "$elapsed_since_last" "$bps" \
        "$cpu_us" "$cpu_sy" "$cpu_wa" "$cpu_id" \
        "$mem_used" "$mem_avail" "$swap_used" \
        "$arc_hit_pct" "$arc_size_mb" "$arc_target_mb" \
        "$pg_ckpt" "$pg_bufs_ckpt" "$pg_bufs_backend" \
        "$pg_blks_hit" "$pg_blks_read" "$pg_cache_hit_pct" \
        "$disk_read_kb" "$disk_write_kb" "$pg_size_gb" "$perf_suffix")

    if [[ -n "$OUTPUT" ]]; then
        echo -e "$line" >> "$OUTPUT"
    else
        echo -e "$line"
    fi
}

# Main
write_header

if [[ "$ONCE" == "true" ]]; then
    collect_sample
else
    echo "Collecting metrics every ${INTERVAL}s. Ctrl+C to stop." >&2
    if [[ -n "$OUTPUT" ]]; then
        echo "Writing to: $OUTPUT" >&2
    fi
    while true; do
        collect_sample
        sleep "$INTERVAL"
    done
fi
