CREATE TABLE merchants (
    id TEXT PRIMARY KEY,
    canonical_key TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    category TEXT NOT NULL,
    subcategory TEXT,
    is_user_taught INTEGER NOT NULL DEFAULT 0 CHECK (is_user_taught IN (0, 1)),
    hit_count INTEGER NOT NULL DEFAULT 0,
    last_seen_at TEXT
);

CREATE TABLE merchant_aliases (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    merchant_id TEXT NOT NULL REFERENCES merchants(id) ON DELETE CASCADE,
    alias_key TEXT NOT NULL UNIQUE,
    source TEXT NOT NULL CHECK (source IN ('user', 'seed', 'asr_variant')),
    hit_count INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE merchant_context_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    merchant_id TEXT NOT NULL REFERENCES merchants(id) ON DELETE CASCADE,
    keyword TEXT NOT NULL,
    category TEXT NOT NULL,
    subcategory TEXT,
    priority INTEGER NOT NULL DEFAULT 0,
    UNIQUE (merchant_id, keyword)
);

CREATE TABLE transactions (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL CHECK (type IN ('expense', 'income', 'refund')),
    amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
    currency TEXT NOT NULL DEFAULT 'MYR' CHECK (currency = 'MYR'),
    merchant_id TEXT REFERENCES merchants(id),
    merchant TEXT,
    description TEXT,
    category TEXT NOT NULL,
    subcategory TEXT,
    occurred_at TEXT NOT NULL,
    local_date TEXT NOT NULL,
    raw_transcript TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE INDEX ix_transactions_occurred_at ON transactions(occurred_at DESC);
CREATE INDEX ix_transactions_local_date ON transactions(local_date DESC);
CREATE INDEX ix_transactions_category ON transactions(category, local_date DESC);

INSERT INTO merchants (id, canonical_key, display_name, category, subcategory) VALUES
    ('merchant-zus', 'zus coffee', 'ZUS Coffee', 'Food & Drink', 'Coffee'),
    ('merchant-mcdonalds', 'mcdonalds', 'McDonald''s', 'Food & Drink', NULL),
    ('merchant-grab', 'grab', 'Grab', 'Transport', NULL),
    ('merchant-shell', 'shell', 'Shell', 'Transport', 'Fuel'),
    ('merchant-shopee', 'shopee', 'Shopee', 'Shopping', NULL);

INSERT INTO merchant_aliases (merchant_id, alias_key, source) VALUES
    ('merchant-zus', 'zus', 'seed'),
    ('merchant-zus', 'zus coffee', 'seed'),
    ('merchant-zus', 'zoos coffee', 'seed'),
    ('merchant-zus', 'zoo s coffee', 'seed'),
    ('merchant-zus', 'zeus coffee', 'seed'),
    ('merchant-mcdonalds', 'mcdonalds', 'seed'),
    ('merchant-mcdonalds', 'mcdonald s', 'seed'),
    ('merchant-grab', 'grab', 'seed'),
    ('merchant-shell', 'shell', 'seed'),
    ('merchant-shopee', 'shopee', 'seed');

INSERT INTO merchant_context_rules (merchant_id, keyword, category, subcategory, priority) VALUES
    ('merchant-grab', 'ride', 'Transport', NULL, 100),
    ('merchant-grab', 'car', 'Transport', NULL, 90),
    ('merchant-grab', 'transport', 'Transport', NULL, 80),
    ('merchant-grab', 'food', 'Food & Drink', NULL, 100),
    ('merchant-grab', 'meal', 'Food & Drink', NULL, 90),
    ('merchant-shell', 'petrol', 'Transport', 'Fuel', 100),
    ('merchant-shell', 'fuel', 'Transport', 'Fuel', 100);

