"""HAF Replay Monitor — API and web dashboard."""

import os
from flask import Flask, request, jsonify, render_template
import psycopg2
import psycopg2.extras

app = Flask(__name__)
DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://bench:bench@localhost:5433/benchdb")


def get_db():
    conn = psycopg2.connect(DATABASE_URL)
    conn.autocommit = False
    return conn


# ── API: Runs ────────────────────────────────────────────────────────────────

@app.route("/api/runs", methods=["GET"])
def list_runs():
    server = request.args.get("server")
    active = request.args.get("active")
    with get_db() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        clauses, params = [], []
        if server:
            clauses.append("server = %s")
            params.append(server)
        if active is not None:
            clauses.append("is_active = %s")
            params.append(active.lower() == "true")
        where = ("WHERE " + " AND ".join(clauses)) if clauses else ""
        cur.execute(f"SELECT * FROM runs {where} ORDER BY start_time DESC", params)
        return jsonify(cur.fetchall())


@app.route("/api/runs", methods=["POST"])
def create_run():
    d = request.json
    with get_db() as conn, conn.cursor() as cur:
        cur.execute(
            """INSERT INTO runs (server, branch, haf_commit, config_desc, notes)
               VALUES (%s, %s, %s, %s, %s) RETURNING id""",
            (d["server"], d.get("branch"), d.get("haf_commit"),
             d.get("config_desc"), d.get("notes")),
        )
        conn.commit()
        return jsonify({"id": cur.fetchone()[0]}), 201


@app.route("/api/runs/<int:rid>", methods=["DELETE"])
def delete_run(rid):
    with get_db() as conn, conn.cursor() as cur:
        cur.execute("DELETE FROM runs WHERE id = %s", (rid,))
        conn.commit()
        return jsonify({"deleted": cur.rowcount})


@app.route("/api/runs/<int:rid>", methods=["PUT"])
def update_run(rid):
    d = request.json
    sets, params = [], []
    for col in ("is_active", "end_time", "notes", "branch", "haf_commit", "config_desc"):
        if col in d:
            sets.append(f"{col} = %s")
            params.append(d[col])
    if not sets:
        return jsonify({"error": "nothing to update"}), 400
    params.append(rid)
    with get_db() as conn, conn.cursor() as cur:
        cur.execute(f"UPDATE runs SET {', '.join(sets)} WHERE id = %s", params)
        conn.commit()
        return jsonify({"updated": cur.rowcount})


# ── API: Samples ─────────────────────────────────────────────────────────────

@app.route("/api/runs/<int:rid>/samples", methods=["POST"])
def push_sample(rid):
    d = request.json
    block_num = d["block_num"]
    lib = d.get("lib")
    ts = d.get("ts")  # optional, defaults to now()

    with get_db() as conn, conn.cursor() as cur:
        # Compute blocks_per_sec from previous sample
        cur.execute(
            "SELECT block_num, ts FROM samples WHERE run_id = %s ORDER BY ts DESC LIMIT 1",
            (rid,),
        )
        prev = cur.fetchone()
        bps = None
        if prev:
            prev_block, prev_ts = prev
            delta_blocks = block_num - prev_block
            if ts:
                from datetime import datetime, timezone
                if isinstance(ts, str):
                    cur_ts = datetime.fromisoformat(ts)
                else:
                    cur_ts = ts
                delta_secs = (cur_ts - prev_ts).total_seconds()
            else:
                # Will use DB now() — estimate with a query
                cur.execute("SELECT extract(epoch from now() - %s)", (prev_ts,))
                delta_secs = cur.fetchone()[0]
            if delta_secs > 0 and delta_blocks >= 0:
                bps = delta_blocks / delta_secs

        if ts:
            cur.execute(
                """INSERT INTO samples (run_id, ts, block_num, lib, blocks_per_sec, memory_rss, pg_size)
                   VALUES (%s, %s, %s, %s, %s, %s, %s)""",
                (rid, ts, block_num, lib, bps, d.get("memory_rss"), d.get("pg_size")),
            )
        else:
            cur.execute(
                """INSERT INTO samples (run_id, block_num, lib, blocks_per_sec, memory_rss, pg_size)
                   VALUES (%s, %s, %s, %s, %s, %s)""",
                (rid, block_num, lib, bps, d.get("memory_rss"), d.get("pg_size")),
            )

        # App progress
        for ap in d.get("app_progress", []):
            if ts:
                cur.execute(
                    "INSERT INTO app_progress (run_id, ts, app_name, current_block_num) VALUES (%s, %s, %s, %s)",
                    (rid, ts, ap["app_name"], ap["current_block_num"]),
                )
            else:
                cur.execute(
                    "INSERT INTO app_progress (run_id, app_name, current_block_num) VALUES (%s, %s, %s)",
                    (rid, ap["app_name"], ap["current_block_num"]),
                )

        # Container status
        for cs in d.get("containers", []):
            if ts:
                cur.execute(
                    "INSERT INTO container_status (run_id, ts, container_name, status, health) VALUES (%s, %s, %s, %s, %s)",
                    (rid, ts, cs["name"], cs.get("status"), cs.get("health")),
                )
            else:
                cur.execute(
                    "INSERT INTO container_status (run_id, container_name, status, health) VALUES (%s, %s, %s, %s)",
                    (rid, cs["name"], cs.get("status"), cs.get("health")),
                )

        conn.commit()
        return jsonify({"blocks_per_sec": bps}), 201


@app.route("/api/runs/<int:rid>/samples", methods=["GET"])
def get_samples(rid):
    with get_db() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            """SELECT ts, block_num, lib, blocks_per_sec, memory_rss, pg_size
               FROM samples WHERE run_id = %s ORDER BY block_num""",
            (rid,),
        )
        return jsonify(cur.fetchall())


@app.route("/api/runs/<int:rid>/app_progress", methods=["GET"])
def get_app_progress(rid):
    with get_db() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            """SELECT ts, app_name, current_block_num
               FROM app_progress WHERE run_id = %s ORDER BY ts""",
            (rid,),
        )
        return jsonify(cur.fetchall())


# ── API: Live State ──────────────────────────────────────────────────────────

@app.route("/api/state", methods=["GET"])
def get_state():
    """Current state of all active runs: latest sample + containers + app progress."""
    with get_db() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("SELECT * FROM runs WHERE is_active = true ORDER BY server")
        runs = cur.fetchall()
        result = []
        for run in runs:
            rid = run["id"]
            # Latest sample
            cur.execute(
                """SELECT ts, block_num, lib, blocks_per_sec, memory_rss, pg_size
                   FROM samples WHERE run_id = %s ORDER BY ts DESC LIMIT 1""",
                (rid,),
            )
            sample = cur.fetchone()
            # Latest container status (most recent per container)
            cur.execute(
                """SELECT DISTINCT ON (container_name) container_name, status, health, ts
                   FROM container_status WHERE run_id = %s
                   ORDER BY container_name, ts DESC""",
                (rid,),
            )
            containers = cur.fetchall()
            # Latest app progress with rate (two most recent per app)
            cur.execute(
                """WITH ranked AS (
                     SELECT app_name, current_block_num, ts,
                            ROW_NUMBER() OVER (PARTITION BY app_name ORDER BY ts DESC) AS rn
                     FROM app_progress WHERE run_id = %s
                   )
                   SELECT r1.app_name, r1.current_block_num, r1.ts,
                          CASE WHEN r2.ts IS NOT NULL
                               AND EXTRACT(EPOCH FROM r1.ts - r2.ts) > 0
                               AND r1.current_block_num > r2.current_block_num
                          THEN (r1.current_block_num - r2.current_block_num)
                               / EXTRACT(EPOCH FROM r1.ts - r2.ts)
                          ELSE NULL END AS blocks_per_sec
                   FROM ranked r1
                   LEFT JOIN ranked r2 ON r1.app_name = r2.app_name AND r2.rn = 2
                   WHERE r1.rn = 1
                   ORDER BY r1.app_name""",
                (rid,),
            )
            apps = cur.fetchall()
            result.append({
                "run": run,
                "sample": sample,
                "containers": containers,
                "apps": apps,
            })
        return jsonify(result)


# ── Pages ────────────────────────────────────────────────────────────────────

@app.route("/")
@app.route("/state")
def page_state():
    return render_template("state.html")


@app.route("/compare")
def page_compare():
    return render_template("compare.html")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8082, debug=os.environ.get("DEBUG", "0") == "1")
