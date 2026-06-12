-- Analyst query 2: top 3 items most frequently bought by members.
--
-- "Frequently bought" is read as total units sold (a member buying 3 of
-- an item counts 3 times). The alternative reading — the number of
-- distinct transactions containing the item — is shown below.
SELECT
    i.item_name,
    i.manufacturer_name,
    SUM(ti.quantity) AS units_sold
FROM transaction_items ti
JOIN items i ON i.item_id = ti.item_id
GROUP BY i.item_id, i.item_name, i.manufacturer_name
ORDER BY units_sold DESC
LIMIT 3;

-- Variant: frequency as "appears in the most transactions", which
-- ignores quantity within a basket:
--
-- SELECT i.item_name, i.manufacturer_name,
--        COUNT(DISTINCT ti.transaction_id) AS transactions_containing_item
-- FROM transaction_items ti
-- JOIN items i ON i.item_id = ti.item_id
-- GROUP BY i.item_id, i.item_name, i.manufacturer_name
-- ORDER BY transactions_containing_item DESC
-- LIMIT 3;
