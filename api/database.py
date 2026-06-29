import sqlite3
from config import DATABASE_PATH


def get_conn() -> sqlite3.Connection:
    conn = sqlite3.connect(DATABASE_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def init_db() -> None:
    with get_conn() as conn:
        conn.executescript("""
        CREATE TABLE IF NOT EXISTS tenants (
            id          TEXT PRIMARY KEY,
            name        TEXT NOT NULL,
            created_at  TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS api_keys (
            key         TEXT PRIMARY KEY,
            name        TEXT NOT NULL,
            type        TEXT NOT NULL,
            tenant_id   TEXT NOT NULL,
            device_id   TEXT,
            created_at  TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS jobs (
            id              TEXT PRIMARY KEY,
            tenant_id       TEXT NOT NULL,
            device_id       TEXT NOT NULL,
            client          TEXT NOT NULL,
            user            TEXT NOT NULL,
            app             TEXT NOT NULL,
            method          TEXT NOT NULL,
            username        TEXT,
            password        TEXT,
            sso_domain      TEXT,
            notes           TEXT,
            slack_webhook   TEXT,
            status          TEXT NOT NULL DEFAULT 'pending',
            result_status   TEXT,
            result_detail   TEXT,
            created_at      TEXT NOT NULL,
            claimed_at      TEXT,
            completed_at    TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_jobs_device_status ON jobs(device_id, status);
        """)
