ALTER TABLE transactions ADD COLUMN updated_at TEXT;
ALTER TABLE transactions ADD COLUMN deleted_at TEXT;
ALTER TABLE transactions ADD COLUMN status TEXT NOT NULL DEFAULT 'confirmed'
    CHECK (status IN ('confirmed', 'needs_review'));

CREATE TABLE conversation_sessions (
    id TEXT PRIMARY KEY,
    started_at TEXT NOT NULL,
    last_turn_at TEXT NOT NULL,
    timezone TEXT NOT NULL
);

CREATE TABLE utterances (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES conversation_sessions(id),
    captured_at TEXT NOT NULL,
    timezone TEXT NOT NULL,
    audio_ms INTEGER,
    transcript TEXT NOT NULL,
    asr_model TEXT,
    asr_ms INTEGER,
    llm_model TEXT,
    llm_ms INTEGER,
    prompt_version TEXT,
    llm_raw_output TEXT,
    llm_invoked INTEGER NOT NULL DEFAULT 0,
    resolution_rung INTEGER,
    created_at TEXT NOT NULL
);

CREATE TABLE turns (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES conversation_sessions(id),
    utterance_id TEXT REFERENCES utterances(id),
    turn_kind TEXT NOT NULL,
    user_text TEXT NOT NULL,
    reply_text TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE proposed_actions (
    id TEXT PRIMARY KEY,
    turn_id TEXT NOT NULL REFERENCES turns(id),
    ordinal INTEGER NOT NULL,
    intent TEXT NOT NULL,
    raw_json TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('pending', 'resolved', 'executed', 'rejected', 'expired')),
    validation_error TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE action_log (
    id TEXT PRIMARY KEY,
    turn_id TEXT REFERENCES turns(id),
    proposed_action_id TEXT REFERENCES proposed_actions(id),
    kind TEXT NOT NULL,
    target_table TEXT NOT NULL,
    target_id TEXT NOT NULL,
    before_json TEXT,
    after_json TEXT,
    metadata_json TEXT,
    executed_at TEXT NOT NULL,
    undone_at TEXT,
    undo_of TEXT REFERENCES action_log(id)
);

CREATE INDEX ix_action_log_target_id ON action_log(target_id);
CREATE INDEX ix_action_log_turn_id ON action_log(turn_id);
CREATE INDEX ix_turns_session_id ON turns(session_id);
CREATE INDEX ix_transactions_deleted_at ON transactions(deleted_at);
