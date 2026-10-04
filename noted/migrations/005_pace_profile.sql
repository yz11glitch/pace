CREATE TABLE pace_profile (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    income_amount_minor INTEGER NOT NULL
        CHECK (income_amount_minor > 0 AND income_amount_minor <= 10000000000),
    income_frequency TEXT NOT NULL CHECK (income_frequency = 'monthly'),
    next_income_date TEXT NOT NULL
        CHECK (next_income_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
    fixed_commitments_minor INTEGER NOT NULL
        CHECK (fixed_commitments_minor >= 0 AND fixed_commitments_minor <= 10000000000),
    savings_target_minor INTEGER NOT NULL
        CHECK (savings_target_minor >= 0 AND savings_target_minor <= 10000000000),
    currency TEXT NOT NULL DEFAULT 'MYR' CHECK (currency = 'MYR'),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    CHECK (fixed_commitments_minor + savings_target_minor <= income_amount_minor)
);
