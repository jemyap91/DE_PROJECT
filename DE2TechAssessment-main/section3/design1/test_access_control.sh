#!/bin/bash
# Integration test for the section 3 design 1 access strategy.
#
# Stands up a throwaway PostgreSQL instance (initdb/pg_ctl must be on
# PATH — no Docker required), applies the section 2 DDL and seed data,
# then applies the access-control script and asserts each team role can
# do exactly what its brief allows — and nothing more.
#
# Usage: ./test_access_control.sh
set -euo pipefail
cd "$(dirname "$0")"
SECTION2=../../section2

TMP=$(mktemp -d)
PORT=54331
PGUSER=postgres
PSQL=(psql -h "$TMP" -p "$PORT" -U "$PGUSER" -d ecommerce -v ON_ERROR_STOP=1 -qtA)

cleanup() {
    pg_ctl -D "$TMP/data" stop -m immediate -s 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

initdb -D "$TMP/data" -U "$PGUSER" --auth=trust >/dev/null
pg_ctl -D "$TMP/data" -l "$TMP/pg.log" -s \
    -o "-p $PORT -k $TMP -c listen_addresses=''" start
createdb -h "$TMP" -p "$PORT" -U "$PGUSER" ecommerce

# Stand the database up exactly as section 2 does, then layer on the
# access controls under test.
"${PSQL[@]}" -f "$SECTION2/ddl/01_schema.sql" >/dev/null
"${PSQL[@]}" -c "\copy members (membership_id, first_name, last_name, email, date_of_birth, mobile_no, above_18) FROM '$SECTION2/data/applications_successful.csv' WITH (FORMAT csv, HEADER true)"
"${PSQL[@]}" -f "$SECTION2/ddl/03_seed_sales_sample.sql" >/dev/null
"${PSQL[@]}" -f 04_access_control.sql >/dev/null

PASS=0; FAIL=0
assert_eq() { # description, expected, actual
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); echo "ok   - $1"
    else
        FAIL=$((FAIL + 1)); echo "FAIL - $1 (expected: $2, got: $3)"
    fi
}

# as_role runs SQL with the given role's privileges (SET ROLE drops the
# superuser's rights for the statement that follows). Prints "allowed"
# or "denied" so assertions read naturally.
as_role() { # role, sql
    "${PSQL[@]}" -c "SET ROLE $1; $2" >/dev/null 2>&1 \
        && echo "allowed" || echo "denied"
}

# --- logistics: read sales details, mark transactions completed --------

assert_eq "logistics can read transaction weights" \
    "allowed" "$(as_role logistics \
        "SELECT total_weight_kg FROM transactions WHERE transaction_id = 1")"

assert_eq "logistics can read line items and the item catalogue" \
    "allowed" "$(as_role logistics \
        "SELECT i.item_name, ti.quantity FROM transaction_items ti
         JOIN items i USING (item_id) LIMIT 1")"

assert_eq "logistics can mark a transaction completed" \
    "allowed" "$(as_role logistics \
        "UPDATE transactions SET status = 'completed', completed_at = now()
         WHERE transaction_id = 1")"

assert_eq "completed status is persisted" \
    "completed" "$("${PSQL[@]}" -c \
        "SELECT status FROM transactions WHERE transaction_id = 1")"

assert_eq "logistics cannot change transaction totals" \
    "denied" "$(as_role logistics \
        "UPDATE transactions SET total_price = 0 WHERE transaction_id = 1")"

assert_eq "logistics cannot read member PII" \
    "denied" "$(as_role logistics "SELECT email FROM members LIMIT 1")"

assert_eq "logistics cannot modify the item catalogue" \
    "denied" "$(as_role logistics \
        "INSERT INTO items (item_name, manufacturer_name, cost, weight_kg)
         VALUES ('x', 'y', 1, 1)")"

# --- analytics: read everything, write nothing -------------------------

assert_eq "analytics can read members (526 rows)" \
    "526" "$("${PSQL[@]}" -c "SET ROLE analytics; SELECT count(*) FROM members")"

assert_eq "analytics can join sales to membership data" \
    "allowed" "$(as_role analytics \
        "SELECT m.membership_id, t.total_price FROM transactions t
         JOIN members m USING (member_id) LIMIT 1")"

assert_eq "analytics cannot update transactions" \
    "denied" "$(as_role analytics \
        "UPDATE transactions SET status = 'completed' WHERE transaction_id = 2")"

assert_eq "analytics cannot update members" \
    "denied" "$(as_role analytics \
        "UPDATE members SET above_18 = false WHERE member_id = 1")"

assert_eq "analytics cannot insert items" \
    "denied" "$(as_role analytics \
        "INSERT INTO items (item_name, manufacturer_name, cost, weight_kg)
         VALUES ('x', 'y', 1, 1)")"

assert_eq "analytics cannot delete from any table" \
    "denied" "$(as_role analytics "DELETE FROM transaction_items")"

# Future-proofing: tables created later by the admin role must be
# readable by analytics without a fresh GRANT.
"${PSQL[@]}" -c "CREATE TABLE returns (return_id int)" >/dev/null
assert_eq "analytics can read tables created after the grants ran" \
    "allowed" "$(as_role analytics "SELECT count(*) FROM returns")"

# --- sales: manage the item catalogue, nothing else --------------------

assert_eq "sales can add a new item" \
    "allowed" "$(as_role sales \
        "INSERT INTO items (item_name, manufacturer_name, cost, weight_kg)
         VALUES ('New Gadget', 'Acme', 9.99, 0.250)")"

assert_eq "sales can remove an item never sold" \
    "allowed" "$(as_role sales \
        "DELETE FROM items WHERE item_name = 'New Gadget'")"

assert_eq "sales cannot remove an item with sales history (FK protects it)" \
    "denied" "$(as_role sales \
        "DELETE FROM items WHERE item_id IN
         (SELECT item_id FROM transaction_items LIMIT 1)")"

assert_eq "sales cannot read member PII" \
    "denied" "$(as_role sales "SELECT mobile_no FROM members LIMIT 1")"

assert_eq "sales cannot touch transactions" \
    "denied" "$(as_role sales \
        "UPDATE transactions SET status = 'completed' WHERE transaction_id = 3")"

# --- no access by default ----------------------------------------------

"${PSQL[@]}" -c "CREATE ROLE intern LOGIN" >/dev/null
assert_eq "a role with no team membership can read nothing" \
    "denied" "$(as_role intern "SELECT count(*) FROM items")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
