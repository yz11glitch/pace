CREATE TABLE request_idempotency (
    request_id TEXT PRIMARY KEY,
    request_fingerprint TEXT NOT NULL,
    action_log_id TEXT NOT NULL UNIQUE REFERENCES action_log(id),
    turn_id TEXT NOT NULL REFERENCES turns(id),
    capture_path TEXT NOT NULL CHECK (capture_path IN ('deterministic_fast_path', 'local_understanding')),
    committed_at TEXT NOT NULL
);

CREATE INDEX ix_request_idempotency_turn_id ON request_idempotency(turn_id);
