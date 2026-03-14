#!/usr/bin/env python3
"""Import block progression from hived log files into the replay monitor database.

Usage:
    python import_replay_log.py --run-id=ID --log-file=PATH --db-url=URL

The script parses hived/HAF log lines to extract (timestamp, block_number) pairs
and inserts them as samples for the given run.

Recognized log patterns:
    "Dump whole block 12345678"
    "Got 14 transactions on block 12345678"
    "PROFILE: Entered P2P sync from start state: 3600 s 12345678 blk"
"""

import argparse
import re
import sys
from datetime import datetime

import psycopg2


# Patterns that contain block numbers
BLOCK_PATTERNS = [
    re.compile(r"(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}).*?Dump whole block (\d+)"),
    re.compile(r"(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}).*?on block (\d+)"),
    re.compile(r"(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}).*?PROFILE:.*?(\d+) blk"),
]

# Minimum block gap between samples to avoid flooding (every ~50k blocks)
MIN_BLOCK_GAP = 50000


def parse_timestamp(ts_str):
    """Parse a timestamp string from hived logs."""
    for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(ts_str, fmt)
        except ValueError:
            continue
    return None


def parse_log(path):
    """Yield (timestamp, block_num) from a hived log file."""
    last_block = 0
    with open(path) as f:
        for line in f:
            for pattern in BLOCK_PATTERNS:
                m = pattern.search(line)
                if m:
                    ts = parse_timestamp(m.group(1))
                    block = int(m.group(2))
                    if ts and block > last_block + MIN_BLOCK_GAP:
                        yield ts, block
                        last_block = block
                    break


def main():
    parser = argparse.ArgumentParser(description="Import hived replay log into monitor DB")
    parser.add_argument("--run-id", type=int, required=True)
    parser.add_argument("--log-file", required=True)
    parser.add_argument("--db-url", default="postgresql://bench:bench@192.168.50.109:5433/benchdb")
    args = parser.parse_args()

    samples = list(parse_log(args.log_file))
    if not samples:
        print("No block progression found in log file")
        sys.exit(1)

    print(f"Found {len(samples)} samples (block {samples[0][1]:,} to {samples[-1][1]:,})")

    conn = psycopg2.connect(args.db_url)
    cur = conn.cursor()

    # Compute blocks_per_sec between consecutive samples
    prev_ts, prev_block = None, None
    inserted = 0
    for ts, block in samples:
        bps = None
        if prev_ts is not None:
            dt = (ts - prev_ts).total_seconds()
            if dt > 0:
                bps = (block - prev_block) / dt
        cur.execute(
            """INSERT INTO samples (run_id, ts, block_num, blocks_per_sec)
               VALUES (%s, %s, %s, %s)""",
            (args.run_id, ts, block, bps),
        )
        prev_ts, prev_block = ts, block
        inserted += 1

    conn.commit()
    cur.close()
    conn.close()
    print(f"Inserted {inserted} samples for run {args.run_id}")


if __name__ == "__main__":
    main()
