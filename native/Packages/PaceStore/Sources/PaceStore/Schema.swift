import GRDB
import PaceCore

/// The consolidated v1 schema. Tables for goals, intentions,
/// signals and the coach arrive with their phases as new migrations.
enum Schema {
    static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE categories (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL UNIQUE,
                    nature TEXT NOT NULL CHECK (nature IN ('essential', 'discretionary', 'income')),
                    sort INTEGER NOT NULL,
                    archived INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1))
                );

                CREATE TABLE merchants (
                    id TEXT PRIMARY KEY,
                    canonical_key TEXT NOT NULL UNIQUE,
                    display_name TEXT NOT NULL,
                    category_id TEXT REFERENCES categories(id),
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
                    category_id TEXT NOT NULL REFERENCES categories(id),
                    subcategory TEXT,
                    priority INTEGER NOT NULL DEFAULT 0,
                    UNIQUE (merchant_id, keyword)
                );

                CREATE TABLE recurring_rules (
                    id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL CHECK (kind IN ('income', 'expense', 'contribution')),
                    label TEXT NOT NULL,
                    amount_minor INTEGER NOT NULL CHECK (amount_minor >= 0 AND amount_minor <= 10000000000),
                    amount_mode TEXT NOT NULL DEFAULT 'fixed' CHECK (amount_mode IN ('fixed', 'estimate')),
                    schedule TEXT NOT NULL DEFAULT 'monthly' CHECK (schedule IN ('monthly')),
                    day_of_month INTEGER NOT NULL CHECK (day_of_month BETWEEN 1 AND 31),
                    start_date TEXT NOT NULL,
                    end_date TEXT,
                    merchant_id TEXT REFERENCES merchants(id),
                    category_id TEXT REFERENCES categories(id),
                    mode TEXT NOT NULL DEFAULT 'draft' CHECK (mode IN ('auto_commit', 'draft', 'remind_only')),
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY,
                    type TEXT NOT NULL CHECK (type IN ('expense', 'income', 'refund', 'contribution')),
                    amount_minor INTEGER NOT NULL CHECK (amount_minor > 0 AND amount_minor <= 10000000000),
                    currency TEXT NOT NULL DEFAULT 'MYR' CHECK (currency = 'MYR'),
                    occurred_at TEXT NOT NULL,
                    tz_identifier TEXT NOT NULL,
                    local_date TEXT NOT NULL CHECK (local_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
                    merchant_id TEXT REFERENCES merchants(id),
                    merchant_text TEXT,
                    category_id TEXT REFERENCES categories(id),
                    goal_id TEXT,
                    note TEXT,
                    source TEXT NOT NULL CHECK (source IN
                        ('keypad', 'text', 'dictation', 'receipt', 'screenshot', 'wallet', 'recurring', 'import')),
                    status TEXT NOT NULL DEFAULT 'confirmed' CHECK (status IN ('confirmed', 'draft')),
                    recurring_rule_id TEXT REFERENCES recurring_rules(id),
                    occurrence_date TEXT,
                    origin_text TEXT,
                    one_off INTEGER NOT NULL DEFAULT 0 CHECK (one_off IN (0, 1)),
                    request_id TEXT UNIQUE,
                    created_at TEXT NOT NULL,
                    updated_at TEXT,
                    deleted_at TEXT,
                    CHECK ((type = 'contribution') = (category_id IS NULL)),
                    CHECK (goal_id IS NULL OR type = 'contribution'),
                    CHECK ((recurring_rule_id IS NULL) = (occurrence_date IS NULL)),
                    UNIQUE (recurring_rule_id, occurrence_date)
                );
                CREATE INDEX ix_transactions_local_date ON transactions(local_date DESC);
                CREATE INDEX ix_transactions_occurred_at ON transactions(occurred_at DESC);
                CREATE INDEX ix_transactions_category ON transactions(category_id, local_date DESC);

                -- Append-only profile settings. Salary timing lives in the
                -- start/end dates of immutable salary rule values.
                CREATE TABLE profile_versions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    payday_anchor INTEGER CHECK (payday_anchor IS NULL OR payday_anchor BETWEEN 1 AND 31),
                    salary_rule_id TEXT REFERENCES recurring_rules(id),
                    savings_mode TEXT NOT NULL CHECK (savings_mode IN ('fixed', 'percentage')),
                    savings_target_minor INTEGER NOT NULL CHECK (savings_target_minor BETWEEN 0 AND 10000000000),
                    savings_basis_points INTEGER NOT NULL CHECK (savings_basis_points BETWEEN 0 AND 10000),
                    fixed_commitments_minor INTEGER NOT NULL CHECK (fixed_commitments_minor BETWEEN 0 AND 10000000000),
                    financial_locale TEXT NOT NULL DEFAULT 'MY',
                    created_at TEXT NOT NULL
                );

                CREATE TABLE preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL);

                CREATE TABLE action_log (
                    id TEXT PRIMARY KEY,
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

                CREATE TABLE request_idempotency (
                    request_id TEXT PRIMARY KEY,
                    request_fingerprint TEXT NOT NULL,
                    action_log_id TEXT NOT NULL UNIQUE REFERENCES action_log(id),
                    committed_at TEXT NOT NULL
                );
                """)
            try Seeds.insert(db)
        }
        migrator.registerMigration("v2_capture") { db in
            // Rebuild only transactions: SQLite cannot alter its v1 amount CHECK.
            // Existing rows and their IDs stay intact for action_log snapshots and undo.
            let original = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'transactions'")!
            let replacement = original
                .replacingOccurrences(of: #"^CREATE TABLE\s+"?transactions"?"#,
                                      with: "CREATE TABLE transactions_v2", options: .regularExpression)
                .replacingOccurrences(of: "amount_minor INTEGER NOT NULL CHECK (amount_minor > 0 AND amount_minor <= 10000000000)",
                                      with: "amount_minor INTEGER CHECK ((status = 'draft' AND (amount_minor IS NULL OR amount_minor BETWEEN 1 AND 10000000000)) OR (status = 'confirmed' AND amount_minor BETWEEN 1 AND 10000000000))")
                .replacingOccurrences(of: "CHECK ((type = 'contribution') = (category_id IS NULL))",
                                      with: "CHECK (status = 'draft' OR ((type = 'contribution') = (category_id IS NULL)))")
                .replacingOccurrences(of: "created_at TEXT NOT NULL,", with: """
                    field_confidence TEXT,
                    amount_candidates TEXT,
                    captured_at TEXT,
                    source_detail TEXT,
                    dedupe_key TEXT,
                    capture_fingerprint TEXT,
                    seen_at TEXT,
                    status_flag TEXT,
                    category_pending INTEGER NOT NULL DEFAULT 0 CHECK (category_pending IN (0, 1)),
                    capture_path TEXT,
                    trust_stage_at_capture TEXT,
                    external_reference TEXT,
                    created_at TEXT NOT NULL,
                    """)
            try db.execute(sql: replacement)
            let columns = try db.columns(in: "transactions").map(\.name).joined(separator: ", ")
            try db.execute(sql: "INSERT INTO transactions_v2 (\(columns)) SELECT \(columns) FROM transactions")
            try db.execute(sql: "DROP TABLE transactions")
            try db.execute(sql: "ALTER TABLE transactions_v2 RENAME TO transactions")
            try db.execute(sql: "CREATE INDEX ix_transactions_local_date ON transactions(local_date DESC)")
            try db.execute(sql: "CREATE INDEX ix_transactions_occurred_at ON transactions(occurred_at DESC)")
            try db.execute(sql: "CREATE INDEX ix_transactions_category ON transactions(category_id, local_date DESC)")
            try db.execute(sql: "CREATE UNIQUE INDEX ux_transactions_dedupe_key ON transactions(dedupe_key) WHERE dedupe_key IS NOT NULL")
            try db.execute(sql: "CREATE INDEX ix_transactions_external_reference ON transactions(external_reference) WHERE external_reference IS NOT NULL")
            try db.execute(sql: """
                CREATE TABLE capture_outcomes (
                    id TEXT PRIMARY KEY, recorded_at TEXT NOT NULL, source TEXT NOT NULL,
                    capture_path TEXT NOT NULL, outcome TEXT NOT NULL, reason TEXT NOT NULL,
                    transaction_id TEXT, action_id TEXT, fields_json TEXT NOT NULL,
                    raw_fields_json TEXT, merchant_resolution TEXT, duplicate_match_id TEXT,
                    anomaly_json TEXT, policy_version INTEGER NOT NULL, trust_stage TEXT NOT NULL,
                    execution_context TEXT, elapsed_ms INTEGER,
                    intent_started_at TEXT, database_open_ms INTEGER,
                    notification_scheduled_at TEXT, notification_status TEXT
                )
                """)
            try db.execute(sql: "CREATE INDEX ix_capture_outcomes_time ON capture_outcomes(recorded_at DESC)")
            try db.execute(sql: """
                CREATE TABLE capture_path_state (
                    path TEXT PRIMARY KEY, stage TEXT NOT NULL CHECK (stage IN ('observe', 'assisted', 'automatic')),
                    captures INTEGER NOT NULL DEFAULT 0, reviewed INTEGER NOT NULL DEFAULT 0,
                    amount_errors INTEGER NOT NULL DEFAULT 0, merchant_errors INTEGER NOT NULL DEFAULT 0,
                    last_change_reason TEXT, updated_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE capture_feedback (
                    action_id TEXT PRIMARY KEY REFERENCES action_log(id), path TEXT NOT NULL,
                    amount_error INTEGER NOT NULL, merchant_error INTEGER NOT NULL,
                    soft_error INTEGER NOT NULL, recorded_at TEXT NOT NULL
                )
                """)
        }
        return migrator
    }()
}

/// Seed categories and the regression merchant pack carried from Noted
/// (migrations 001 and 008). The MY merchant pack follows the financial locale.
enum Seeds {
    static let categories: [(name: String, nature: String)] = [
        ("Food & Drink", "discretionary"), ("Groceries", "essential"), ("Transport", "essential"),
        ("Shopping", "discretionary"), ("Bills & Utilities", "essential"), ("Health", "essential"),
        ("Entertainment", "discretionary"), ("Education", "essential"), ("Services", "discretionary"),
        ("Travel", "discretionary"), ("Gifts & Donations", "discretionary"), ("Income", "income"),
        ("Other", "discretionary"),
    ]

    static func categoryID(_ name: String) -> String {
        merchantKey(name).replacingOccurrences(of: " ", with: "-")
    }

    static func insert(_ db: Database) throws {
        for (index, category) in categories.enumerated() {
            try db.execute(sql: "INSERT INTO categories (id, name, nature, sort) VALUES (?, ?, ?, ?)",
                           arguments: [categoryID(category.name), category.name, category.nature, index])
        }
        let merchants: [(String, String, String, String, String?)] = [
            ("merchant-zus", "zus coffee", "ZUS Coffee", "Food & Drink", "Coffee"),
            ("merchant-mcdonalds", "mcdonalds", "McDonald's", "Food & Drink", nil),
            ("merchant-grab", "grab", "Grab", "Transport", nil),
            ("merchant-shell", "shell", "Shell", "Transport", "Fuel"),
            ("merchant-shopee", "shopee", "Shopee", "Shopping", nil),
        ]
        for (id, key, name, category, subcategory) in merchants {
            try db.execute(sql: """
                INSERT INTO merchants (id, canonical_key, display_name, category_id, subcategory)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [id, key, name, categoryID(category), subcategory])
        }
        let aliases = [
            ("merchant-zus", "zus"), ("merchant-zus", "zus coffee"), ("merchant-zus", "zoos coffee"),
            ("merchant-zus", "zoo s coffee"), ("merchant-zus", "zeus coffee"), ("merchant-mcdonalds", "mcdonalds"),
            ("merchant-mcdonalds", "mcdonald s"), ("merchant-grab", "grab"), ("merchant-shell", "shell"),
            ("merchant-shopee", "shopee"), ("merchant-mcdonalds", "mcd"), ("merchant-zus", "zeus"),
        ]
        for (merchant, alias) in aliases {
            try db.execute(sql: "INSERT INTO merchant_aliases (merchant_id, alias_key, source) VALUES (?, ?, 'seed')",
                           arguments: [merchant, alias])
        }
        let rules: [(String, String, String, String?, Int)] = [
            ("merchant-grab", "ride", "Transport", nil, 100), ("merchant-grab", "car", "Transport", nil, 90),
            ("merchant-grab", "transport", "Transport", nil, 80), ("merchant-grab", "food", "Food & Drink", nil, 100),
            ("merchant-grab", "meal", "Food & Drink", nil, 90), ("merchant-shell", "petrol", "Transport", "Fuel", 100),
            ("merchant-shell", "fuel", "Transport", "Fuel", 100),
        ]
        for (merchant, keyword, category, subcategory, priority) in rules {
            try db.execute(sql: """
                INSERT INTO merchant_context_rules (merchant_id, keyword, category_id, subcategory, priority)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [merchant, keyword, categoryID(category), subcategory, priority])
        }
        try db.execute(sql: "INSERT INTO preferences (key, value) VALUES ('financial_locale', 'MY')")
    }
}
