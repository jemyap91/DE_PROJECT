-- Sample sales data so the database demonstrates the analyst queries
-- end-to-end. The catalogue and baskets are illustrative; membership IDs
-- are real IDs produced by the section 1 pipeline.
--
-- Transaction totals are computed FROM the line items below (not typed in
-- by hand), so the stored totals always agree with the basket contents.

INSERT INTO items (item_name, manufacturer_name, cost, weight_kg) VALUES
    ('Wireless Mouse',        'Logitek',      25.90, 0.120),
    ('Mechanical Keyboard',   'Logitek',      89.00, 0.950),
    ('27in Monitor',          'ViewMaster',  249.50, 4.800),
    ('USB-C Hub',             'Ankora',       45.00, 0.180),
    ('Noise-Cancel Headset',  'AudioPhile',  179.90, 0.310),
    ('Laptop Stand',          'Ankora',       39.90, 1.250),
    ('Webcam 1080p',          'ViewMaster',   69.00, 0.220),
    ('Portable SSD 1TB',      'DataVault',   129.00, 0.058);

-- One row per (basket, item). basket_ts doubles as the basket identifier:
-- every basket gets a distinct timestamp so the line items can be joined
-- back to the transaction row created for it.
CREATE TEMPORARY TABLE seed_baskets (
    membership_id TEXT,
    basket_ts     TIMESTAMPTZ,
    item_name     TEXT,
    quantity      INTEGER
);

INSERT INTO seed_baskets VALUES
    ('Smith_c7677',      '2026-06-01 09:15:00+08', 'Wireless Mouse',       1),
    ('Smith_c7677',      '2026-06-01 09:15:00+08', '27in Monitor',         2),
    ('Smith_c7677',      '2026-06-08 18:02:00+08', 'Portable SSD 1TB',     1),
    ('Wang_04168',       '2026-06-01 10:30:00+08', 'Mechanical Keyboard',  1),
    ('Wang_04168',       '2026-06-01 10:30:00+08', 'Wireless Mouse',       1),
    ('Estrada_0bf5b',    '2026-06-02 11:05:00+08', 'Noise-Cancel Headset', 1),
    ('Estrada_0bf5b',    '2026-06-02 11:05:00+08', 'Webcam 1080p',         1),
    ('Cline_825fb',      '2026-06-02 14:40:00+08', 'USB-C Hub',            2),
    ('Williams_3e726',   '2026-06-03 08:55:00+08', '27in Monitor',         1),
    ('Williams_3e726',   '2026-06-03 08:55:00+08', 'Laptop Stand',         1),
    ('Flores_8a42c',     '2026-06-03 16:20:00+08', 'Wireless Mouse',       3),
    ('Richardson_ef158', '2026-06-04 12:00:00+08', 'Portable SSD 1TB',     2),
    ('Gomez_876bf',      '2026-06-04 19:45:00+08', 'Mechanical Keyboard',  1),
    ('Gomez_876bf',      '2026-06-04 19:45:00+08', 'Noise-Cancel Headset', 1),
    ('Gomez_876bf',      '2026-06-04 19:45:00+08', 'USB-C Hub',            1),
    ('Rodriguez_93ac7',  '2026-06-05 09:10:00+08', 'Webcam 1080p',         1),
    ('Garcia_26b55',     '2026-06-05 13:25:00+08', 'Laptop Stand',         2),
    ('Garza_40199',      '2026-06-06 10:00:00+08', '27in Monitor',         1),
    ('Garza_40199',      '2026-06-06 10:00:00+08', 'Wireless Mouse',       1),
    ('Sanchez_364a7',    '2026-06-06 15:35:00+08', 'Portable SSD 1TB',     1),
    ('Armstrong_e2fb8',  '2026-06-07 11:50:00+08', 'USB-C Hub',            1),
    ('Armstrong_e2fb8',  '2026-06-07 11:50:00+08', 'Webcam 1080p',         1);

-- Create one transaction per basket with totals aggregated from its line
-- items. min(member_id) resolves a membership_id to a single member even
-- where the section 1 ID scheme produced duplicates.
INSERT INTO transactions (member_id, transaction_ts, total_price, total_weight_kg)
SELECT
    (SELECT min(m.member_id) FROM members m
      WHERE m.membership_id = b.membership_id),
    b.basket_ts,
    SUM(i.cost * b.quantity),
    SUM(i.weight_kg * b.quantity)
FROM seed_baskets b
JOIN items i ON i.item_name = b.item_name
GROUP BY b.membership_id, b.basket_ts;

-- Attach the line items, snapshotting today's catalogue cost and weight
-- as the price paid and weight shipped.
INSERT INTO transaction_items (transaction_id, item_id, quantity, unit_price, unit_weight_kg)
SELECT t.transaction_id, i.item_id, b.quantity, i.cost, i.weight_kg
FROM seed_baskets b
JOIN transactions t ON t.transaction_ts = b.basket_ts
JOIN items i ON i.item_name = b.item_name;

DROP TABLE seed_baskets;
