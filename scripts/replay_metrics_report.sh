#!/bin/bash
#
# HAF Replay Metrics Report
#
# Analyzes TSV files produced by replay_metrics_collector.sh
# Can compare two metric files side-by-side to identify performance differences.
#
# Usage:
#   # Single file analysis
#   ./replay_metrics_report.sh metrics.tsv
#
#   # Compare two replays
#   ./replay_metrics_report.sh --file1 rc11.tsv --label1 "rc11" \
#                              --file2 irrev.tsv --label2 "irrev"
#
#   # Focus on a block range
#   ./replay_metrics_report.sh metrics.tsv --from 20000000 --to 30000000

set -euo pipefail

FILE1=""
FILE2=""
LABEL1="server1"
LABEL2="server2"
FROM_BLOCK=0
TO_BLOCK=999999999

usage() {
    cat <<'EOF'
Usage:
  Single:   replay_metrics_report.sh <file.tsv> [--from N] [--to N]
  Compare:  replay_metrics_report.sh --file1 <f1> --label1 <l1> \
                                     --file2 <f2> --label2 <l2> \
                                     [--from N] [--to N]
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --file1)  FILE1="$2"; shift 2 ;;
        --file2)  FILE2="$2"; shift 2 ;;
        --label1) LABEL1="$2"; shift 2 ;;
        --label2) LABEL2="$2"; shift 2 ;;
        --from)   FROM_BLOCK="$2"; shift 2 ;;
        --to)     TO_BLOCK="$2"; shift 2 ;;
        -h|--help) usage ;;
        *)
            if [[ -z "$FILE1" ]]; then
                FILE1="$1"; shift
            else
                echo "Unknown option: $1" >&2; usage
            fi
            ;;
    esac
done

if [[ -z "$FILE1" ]]; then
    echo "Error: no input file specified" >&2
    usage
fi

analyze_file() {
    local file="$1"
    local label="$2"
    local from="$3"
    local to="$4"

    awk -F'\t' -v from="$from" -v to="$to" -v label="$label" '
    NR == 1 { next }  # skip header
    {
        block = $2 + 0
        if (block < from || block > to) next
        if (block == 0) next

        n++
        bps = $5 + 0
        if (bps > 0) { bps_sum += bps; bps_n++ }
        if (bps > bps_max) bps_max = bps
        if (bps_min == 0 || (bps > 0 && bps < bps_min)) bps_min = bps

        cpu_us += $6; cpu_sy += $7; cpu_wa += $8; cpu_id += $9
        mem_used += $10; mem_avail += $11; swap_used += $12
        arc_hit += $13; arc_size += $14; arc_target += $15
        pg_cache += $21; pg_size += $24

        # Perf counters (columns 25-29, may not exist)
        if (NF >= 25 && $25 + 0 > 0) { ipc_sum += $25; ipc_n++ }
        if (NF >= 26) stall_sum += $26
        if (NF >= 27) cmiss_sum += $27
        if (NF >= 28) bmiss_sum += $28
        if (NF >= 29) l1d_sum += $29

        if (n == 1) { first_block = block; first_ts = $1 }
        last_block = block; last_ts = $1
    }
    END {
        if (n == 0) { print "  No data in range"; exit }

        printf "\n"
        printf "  %s: %s → %s (%d samples)\n", label, first_ts, last_ts, n
        printf "  Block range: %d → %d\n", first_block, last_block
        printf "\n"
        printf "  %-25s %10s %10s %10s\n", "Metric", "Avg", "Min", "Max"
        printf "  %-25s %10s %10s %10s\n", "─────────────────────────", "──────────", "──────────", "──────────"

        if (bps_n > 0)
            printf "  %-25s %10.0f %10.0f %10.0f\n", "Blocks/sec", bps_sum/bps_n, bps_min, bps_max

        printf "  %-25s %9.1f%%\n", "CPU user", cpu_us/n
        printf "  %-25s %9.1f%%\n", "CPU system", cpu_sy/n
        printf "  %-25s %9.1f%%\n", "CPU iowait", cpu_wa/n
        printf "  %-25s %9.1f%%\n", "CPU idle", cpu_id/n
        printf "  %-25s %9.0f MB\n", "Memory used", mem_used/n
        printf "  %-25s %9.0f MB\n", "Memory available", mem_avail/n
        printf "  %-25s %9.0f MB\n", "Swap used", swap_used/n
        printf "  %-25s %9.1f%%\n", "ZFS ARC hit rate", arc_hit/n
        printf "  %-25s %9.0f MB\n", "ZFS ARC size", arc_size/n
        printf "  %-25s %9.0f MB\n", "ZFS ARC target", arc_target/n
        printf "  %-25s %9.1f%%\n", "PG cache hit rate", pg_cache/n
        printf "  %-25s %9.1f GB\n", "PG database size", pg_size/n

        if (ipc_n > 0) {
            printf "\n"
            printf "  %-25s %10s\n", "── perf counters ──", "──────────"
            printf "  %-25s %9.2f\n", "IPC (insn/cycle)", ipc_sum/ipc_n
            printf "  %-25s %9.2f\n", "Stalled cycles/insn", stall_sum/n
            printf "  %-25s %9.1f%%\n", "Cache miss rate", cmiss_sum/n
            printf "  %-25s %9.2f%%\n", "Branch miss rate", bmiss_sum/n
            printf "  %-25s %9.2f%%\n", "L1-dcache miss rate", l1d_sum/n
        }
        printf "\n"
    }' "$file"
}

# Produce a side-by-side comparison bucketed by block range
compare_files() {
    local f1="$1" l1="$2" f2="$3" l2="$4" from="$5" to="$6"

    echo ""
    echo "Side-by-side comparison (5M block buckets, overlapping ranges only)"
    echo ""
    printf "%-12s │ %8s %6s %6s %7s %5s %5s │ %8s %6s %6s %7s %5s %5s │ %7s\n" \
        "Block Range" "${l1}_bps" "cpu_u" "iowt" "arc%" "swap" "IPC" \
                      "${l2}_bps" "cpu_u" "iowt" "arc%" "swap" "IPC" "bps_diff"
    printf "%-12s─┼─%8s─%6s─%6s─%7s─%5s─%5s─┼─%8s─%6s─%6s─%7s─%5s─%5s─┼─%7s\n" \
        "────────────" "────────" "──────" "──────" "───────" "─────" "─────" \
                       "────────" "──────" "──────" "───────" "─────" "─────" "───────"

    # Bucket both files by 5M blocks
    local bucket_size=5000000

    # Process file1
    awk -F'\t' -v bs="$bucket_size" -v from="$from" -v to="$to" '
    NR==1{next}
    {
        b=$2+0; if(b<from||b>to||b==0)next
        bk=int(b/bs)*bs
        bps=$5+0; if(bps>0){s[bk]+=bps; n[bk]++}
        cu[bk]+=$6; cw[bk]+=$8; ah[bk]+=$13; sw[bk]+=$12; cnt[bk]++
        if(NF>=25 && $25+0>0){ipc[bk]+=$25; ipc_n[bk]++}
    }
    END{
        for(bk in cnt) printf "%d\t%.0f\t%.1f\t%.1f\t%.1f\t%.0f\t%.2f\n", bk, (n[bk]>0?s[bk]/n[bk]:0), cu[bk]/cnt[bk], cw[bk]/cnt[bk], ah[bk]/cnt[bk], sw[bk]/cnt[bk], (ipc_n[bk]>0?ipc[bk]/ipc_n[bk]:0)
    }' "$f1" | sort -t$'\t' -k1,1n > /tmp/rmc_b1.tsv

    awk -F'\t' -v bs="$bucket_size" -v from="$from" -v to="$to" '
    NR==1{next}
    {
        b=$2+0; if(b<from||b>to||b==0)next
        bk=int(b/bs)*bs
        bps=$5+0; if(bps>0){s[bk]+=bps; n[bk]++}
        cu[bk]+=$6; cw[bk]+=$8; ah[bk]+=$13; sw[bk]+=$12; cnt[bk]++
        if(NF>=25 && $25+0>0){ipc[bk]+=$25; ipc_n[bk]++}
    }
    END{
        for(bk in cnt) printf "%d\t%.0f\t%.1f\t%.1f\t%.1f\t%.0f\t%.2f\n", bk, (n[bk]>0?s[bk]/n[bk]:0), cu[bk]/cnt[bk], cw[bk]/cnt[bk], ah[bk]/cnt[bk], sw[bk]/cnt[bk], (ipc_n[bk]>0?ipc[bk]/ipc_n[bk]:0)
    }' "$f2" | sort -t$'\t' -k1,1n > /tmp/rmc_b2.tsv

    # Join and print
    join -t$'\t' -j1 /tmp/rmc_b1.tsv /tmp/rmc_b2.tsv | while IFS=$'\t' read -r bk bps1 cu1 cw1 ah1 sw1 ipc1 bps2 cu2 cw2 ah2 sw2 ipc2; do
        local bend=$((bk + bucket_size))
        local range
        if [[ $bk -ge 1000000 ]]; then
            range="$((bk/1000000))M-$((bend/1000000))M"
        else
            range="${bk}-${bend}"
        fi

        local diff="—"
        if [[ "$bps2" -gt 0 ]]; then
            diff=$(awk "BEGIN {d=($bps1-$bps2)*100/$bps2; if(d>=0) printf \"+%.1f%%\",d; else printf \"%.1f%%\",d}")
        fi

        local ipc1_fmt="—"
        local ipc2_fmt="—"
        if [[ "$ipc1" != "0.00" && -n "$ipc1" ]]; then ipc1_fmt="$ipc1"; fi
        if [[ "$ipc2" != "0.00" && -n "$ipc2" ]]; then ipc2_fmt="$ipc2"; fi

        printf "%-12s │ %8s %5.1f%% %5.1f%% %6.1f%% %4sMB %5s │ %8s %5.1f%% %5.1f%% %6.1f%% %4sMB %5s │ %7s\n" \
            "$range" "$bps1" "$cu1" "$cw1" "$ah1" "$sw1" "$ipc1_fmt" "$bps2" "$cu2" "$cw2" "$ah2" "$sw2" "$ipc2_fmt" "$diff"
    done

    rm -f /tmp/rmc_b1.tsv /tmp/rmc_b2.tsv
    echo ""
}

# Main
echo ""
echo "HAF Replay Metrics Report"
echo "════════════════════════════════════════════"

if [[ -n "$FILE2" ]]; then
    analyze_file "$FILE1" "$LABEL1" "$FROM_BLOCK" "$TO_BLOCK"
    analyze_file "$FILE2" "$LABEL2" "$FROM_BLOCK" "$TO_BLOCK"
    compare_files "$FILE1" "$LABEL1" "$FILE2" "$LABEL2" "$FROM_BLOCK" "$TO_BLOCK"
else
    analyze_file "$FILE1" "$LABEL1" "$FROM_BLOCK" "$TO_BLOCK"
fi
