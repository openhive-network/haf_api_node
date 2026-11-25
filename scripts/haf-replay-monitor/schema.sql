CREATE TABLE IF NOT EXISTS runs (
    id          SERIAL PRIMARY KEY,
    server      TEXT NOT NULL,
    branch      TEXT,
    haf_commit  TEXT,
    config_desc TEXT,
    start_time  TIMESTAMPTZ NOT NULL DEFAULT now(),
    end_time    TIMESTAMPTZ,
    notes       TEXT,
    is_active   BOOLEAN NOT NULL DEFAULT true,
    haf_started_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS samples (
    id          SERIAL PRIMARY KEY,
    run_id      INTEGER NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
    ts          TIMESTAMPTZ NOT NULL DEFAULT now(),
    block_num   INTEGER NOT NULL,
    lib         INTEGER,
    blocks_per_sec REAL,
    memory_rss  BIGINT,
    pg_size     BIGINT
);
CREATE INDEX IF NOT EXISTS idx_samples_run ON samples(run_id, block_num);

CREATE TABLE IF NOT EXISTS app_progress (
    id          SERIAL PRIMARY KEY,
    run_id      INTEGER NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
    ts          TIMESTAMPTZ NOT NULL DEFAULT now(),
    app_name    TEXT NOT NULL,
    current_block_num INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_app_progress_run ON app_progress(run_id, ts);

CREATE TABLE IF NOT EXISTS container_status (
    id          SERIAL PRIMARY KEY,
    run_id      INTEGER NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
    ts          TIMESTAMPTZ NOT NULL DEFAULT now(),
    container_name TEXT NOT NULL,
    status      TEXT,
    health      TEXT
);
CREATE INDEX IF NOT EXISTS idx_container_status_run ON container_status(run_id, ts);
