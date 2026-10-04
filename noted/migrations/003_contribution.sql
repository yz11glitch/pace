PRAGMA foreign_keys = OFF;
BEGIN IMMEDIATE;

CREATE TABLE transactions_new (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL CHECK (type IN ('expense', 'income', 'refund', 'contribution')),
    amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
    currency TEXT NOT NULL DEFAULT 'MYR' CHECK (currency = 'MYR'),
    merchant_id TEXT REFERENCES merchants(id),
    merchant TEXT,
    description TEXT,
    category TEXT,
    subcategory TEXT,
    occurred_at TEXT NOT NULL,
    local_date TEXT NOT NULL,
    raw_transcript TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT,
    deleted_at TEXT,
    status TEXT NOT NULL DEFAULT 'confirmed'
        CHECK (status IN ('confirmed', 'needs_review')),
    CHECK ((type = 'contribution' AND category IS NULL)
        OR (type <> 'contribution' AND category IS NOT NULL))
);

INSERT INTO transactions_new (
    id, type, amount_minor, currency, merchant_id, merchant, description,
    category, subcategory, occurred_at, local_date, raw_transcript, created_at,
    updated_at, deleted_at, status
)
SELECT
    id, type, amount_minor, currency, merchant_id, merchant, description,
    category, subcategory, occurred_at, local_date, raw_transcript, created_at,
    updated_at, deleted_at, status
FROM transactions;

DROP TABLE transactions;
ALTER TABLE transactions_new RENAME TO transactions;

CREATE INDEX ix_transactions_occurred_at ON transactions(occurred_at DESC);
CREATE INDEX ix_transactions_local_date ON transactions(local_date DESC);
CREATE INDEX ix_transactions_category ON transactions(category, local_date DESC);
CREATE INDEX ix_transactions_deleted_at ON transactions(deleted_at);

COMMIT;
PRAGMA foreign_keys = ON;
PRAGMA foreign_key_check;
