-- Analyst query 1: top 10 members by spending.
--
-- Spending is the sum of the stored transaction totals. Grouping is by
-- member_id (the surrogate key), not membership_id, so two members who
-- collide on the same membership_id are not merged into one spender.
SELECT
    m.membership_id,
    m.first_name,
    m.last_name,
    SUM(t.total_price) AS total_spent
FROM transactions t
JOIN members m ON m.member_id = t.member_id
GROUP BY m.member_id, m.membership_id, m.first_name, m.last_name
ORDER BY total_spent DESC
LIMIT 10;

-- Variant: LIMIT 10 cuts arbitrarily when members tie at the boundary.
-- If analysts want ties included, rank instead:
--
-- SELECT * FROM (
--     SELECT m.membership_id, m.first_name, m.last_name,
--            SUM(t.total_price) AS total_spent,
--            DENSE_RANK() OVER (ORDER BY SUM(t.total_price) DESC) AS spend_rank
--     FROM transactions t
--     JOIN members m ON m.member_id = t.member_id
--     GROUP BY m.member_id, m.membership_id, m.first_name, m.last_name
-- ) ranked
-- WHERE spend_rank <= 10;
