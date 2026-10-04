-- A small regression seed. Future trusted aliases are added only through explicit user action.
INSERT OR IGNORE INTO merchant_aliases (merchant_id, alias_key, source) VALUES
    ('merchant-mcdonalds', 'mcd', 'seed'),
    ('merchant-zus', 'zeus', 'seed');
