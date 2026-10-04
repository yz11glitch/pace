BEGIN IMMEDIATE;

CREATE TABLE pace_profile_new (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    income_amount_minor INTEGER NOT NULL CHECK (income_amount_minor >= 0 AND income_amount_minor <= 10000000000),
    income_frequency TEXT NOT NULL CHECK (income_frequency = 'monthly'),
    next_income_date TEXT NOT NULL CHECK (next_income_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
    fixed_commitments_minor INTEGER NOT NULL CHECK (fixed_commitments_minor >= 0 AND fixed_commitments_minor <= 10000000000),
    savings_target_minor INTEGER NOT NULL CHECK (savings_target_minor >= 0 AND savings_target_minor <= 10000000000),
    savings_mode TEXT NOT NULL DEFAULT 'fixed' CHECK (savings_mode IN ('fixed', 'percentage')),
    savings_percentage_basis_points INTEGER NOT NULL DEFAULT 0 CHECK (savings_percentage_basis_points BETWEEN 0 AND 10000),
    currency TEXT NOT NULL DEFAULT 'MYR' CHECK (currency = 'MYR'),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    CHECK (savings_mode != 'fixed' OR fixed_commitments_minor + savings_target_minor <= income_amount_minor)
);

INSERT INTO pace_profile_new (
    id, income_amount_minor, income_frequency, next_income_date,
    fixed_commitments_minor, savings_target_minor, currency, created_at, updated_at
)
SELECT id, income_amount_minor, income_frequency, next_income_date,
       fixed_commitments_minor, savings_target_minor, currency, created_at, updated_at
FROM pace_profile;

DROP TABLE pace_profile;
ALTER TABLE pace_profile_new RENAME TO pace_profile;

COMMIT;
