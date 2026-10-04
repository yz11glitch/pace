PRAGMA foreign_keys = OFF;

CREATE TABLE request_idempotency_new (
    request_id TEXT PRIMARY KEY,
    request_fingerprint TEXT NOT NULL,
    action_log_id TEXT NOT NULL UNIQUE REFERENCES action_log(id),
    turn_id TEXT REFERENCES turns(id),
    capture_path TEXT NOT NULL CHECK (
        capture_path IN ('deterministic_fast_path', 'local_understanding', 'manual')
    ),
    committed_at TEXT NOT NULL
);

INSERT INTO request_idempotency_new (
    request_id, request_fingerprint, action_log_id, turn_id, capture_path, committed_at
)
SELECT request_id, request_fingerprint, action_log_id, turn_id, capture_path, committed_at
FROM request_idempotency;

DROP TABLE request_idempotency;
ALTER TABLE request_idempotency_new RENAME TO request_idempotency;
CREATE INDEX ix_request_idempotency_turn_id ON request_idempotency(turn_id);

PRAGMA foreign_keys = ON;
