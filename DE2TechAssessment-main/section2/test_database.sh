#!/bin/bash
# Integration test for the section 2 database.
#
# Stands up a throwaway PostgreSQL instance (initdb/pg_ctl must be on
# PATH — no Docker required), applies the same DDL the Docker image
# applies, loads the section 1 successful applications, seeds the sample
# sales data, and asserts the schema and the two analyst queries behave
# as documented.
#
# Usage: ./test_database.sh
set -euo pipefail
cd "$(dirname "$0")"

TMP=$(mktemp -d)
PORT=54329
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

# Apply the init scripts exactly as the Docker entrypoint would: schema,
# then the member load (local path instead of the in-container path),
# then the sample sales seed.
"${PSQL[@]}" -f ddl/01_schema.sql >/dev/null
"${PSQL[@]}" -c "\copy members (membership_id, first_name, last_name, email, date_of_birth, mobile_no, above_18) FROM 'data/applications_successful.csv' WITH (FORMAT csv, HEADER true)"
"${PSQL[@]}" -f ddl/03_seed_sales_sample.sql >/dev/null

PASS=0; FAIL=0
assert_eq() { # description, expected, actual
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); echo "ok   - $1"
    else
        FAIL=$((FAIL + 1)); echo "FAIL - $1 (expected: $2, got: $3)"
    fi
}

assert_eq "all 526 successful applications loaded into members" \
    "526" "$("${PSQL[@]}" -c 'SELECT count(*) FROM members')"

assert_eq "colliding membership IDs stored as distinct members" \
    "2" "$("${PSQL[@]}" -c "SELECT count(*) FROM members WHERE membership_id = 'Williamson_2b72a'")"

assert_eq "one transaction per seeded basket" \
    "14" "$("${PSQL[@]}" -c 'SELECT count(*) FROM transactions')"

assert_eq "one line item per seeded basket row" \
    "22" "$("${PSQL[@]}" -c 'SELECT count(*) FROM transaction_items')"

assert_eq "stored totals agree with line items on every transaction" \
    "0" "$("${PSQL[@]}" -c "
        SELECT count(*) FROM transactions t
        JOIN (SELECT transaction_id,
                     SUM(quantity * unit_price)     AS price,
                     SUM(quantity * unit_weight_kg) AS weight
              FROM transaction_items GROUP BY transaction_id) li
          USING (transaction_id)
        WHERE t.total_price <> li.price OR t.total_weight_kg <> li.weight")"

assert_eq "rejects a 7-digit mobile number" \
    "rejected" "$("${PSQL[@]}" -c "
        INSERT INTO members (membership_id, first_name, last_name, email,
                             date_of_birth, mobile_no, above_18)
        VALUES ('X_00000','A','B','a@b.com','2000-01-01','1234567',true)" \
        2>/dev/null && echo "accepted" || echo "rejected")"

assert_eq "rejects a line item for a nonexistent transaction" \
    "rejected" "$("${PSQL[@]}" -c "
        INSERT INTO transaction_items VALUES (999999, 1, 1, 1.00, 0.100)" \
        2>/dev/null && echo "accepted" || echo "rejected")"

assert_eq "top-10-spenders query returns 10 rows" \
    "10" "$("${PSQL[@]}" -f queries/01_top_10_members_by_spending.sql | wc -l | tr -d ' ')"

assert_eq "top spender is Smith_c7677 with 653.90" \
    "Smith_c7677|653.90" "$("${PSQL[@]}" -f queries/01_top_10_members_by_spending.sql | head -1 | cut -d'|' -f1,4)"

assert_eq "top-3-items query returns 3 rows" \
    "3" "$("${PSQL[@]}" -f queries/02_top_3_frequent_items.sql | wc -l | tr -d ' ')"

assert_eq "most frequent item is Wireless Mouse with 6 units" \
    "Wireless Mouse|6" "$("${PSQL[@]}" -f queries/02_top_3_frequent_items.sql | head -1 | cut -d'|' -f1,3)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
