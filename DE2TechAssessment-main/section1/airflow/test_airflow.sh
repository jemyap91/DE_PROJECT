#!/bin/bash
# Integration test for the section 1 Airflow deployment.
#
# Stands up the Docker Compose stack, waits for Airflow to become healthy,
# asserts the DAG parses cleanly, triggers one real DAG run through the
# scheduler (the same path as the UI's "Trigger" button), waits for the
# pipeline outputs to land, and asserts their contents. Tears the stack
# down (including volumes) afterwards and removes any output files the
# test created, leaving the repo as it found it.
#
# Note: runs with an explicit historical --logical-date are backfill
# territory in Airflow 3 (`airflow backfill create`); a plain trigger is
# the representative manual-run path, so that is what this test exercises.
#
# Requires Docker. Usage: ./test_airflow.sh
set -euo pipefail
cd "$(dirname "$0")"

DAG_ID=process_membership_applications
OK_DIR=../output/successful
KO_DIR=../output/unsuccessful

# Snapshot the output folders so everything this test produces (including
# the scheduled run Airflow creates on unpause) can be removed afterwards.
BEFORE=$(mktemp)
ls "$OK_DIR" "$KO_DIR" > "$BEFORE"

cleanup() {
    AFTER=$(mktemp)
    ls "$OK_DIR" "$KO_DIR" > "$AFTER" 2>/dev/null || true
    while IFS= read -r f; do
        rm -f "$OK_DIR/$f" "$KO_DIR/$f"
    done < <(comm -13 "$BEFORE" "$AFTER" | grep -v ':$' | grep . || true)
    rm -f "$BEFORE" "$AFTER"
    docker compose down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

new_success_file() { # newest successful output created since the snapshot
    comm -13 "$BEFORE" <(ls "$OK_DIR" "$KO_DIR") 2>/dev/null \
        | grep '^applications_successful_' | sort | tail -1 || true
}

docker compose up -d --quiet-pull 2>/dev/null

echo -n "waiting for airflow to become healthy "
status=starting
for i in $(seq 1 60); do
    status=$(docker inspect --format '{{.State.Health.Status}}' section1-airflow 2>/dev/null || echo starting)
    [ "$status" = healthy ] && break
    echo -n "."
    sleep 5
done
echo
[ "$status" = healthy ] || { echo "airflow never became healthy"; exit 1; }

PASS=0; FAIL=0
assert_eq() { # description, expected, actual
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); echo "ok   - $1"
    else
        FAIL=$((FAIL + 1)); echo "FAIL - $1 (expected: $2, got: $3)"
    fi
}

assert_eq "DAG file parses with no import errors" \
    "0" "$(docker compose exec -T airflow \
        airflow dags list-import-errors -o plain 2>/dev/null | grep -c py || true)"

assert_eq "DAG is registered under its dag_id" \
    "1" "$(docker compose exec -T airflow \
        airflow dags list -o plain 2>/dev/null | grep -c "^$DAG_ID " || true)"

docker compose exec -T airflow airflow dags unpause "$DAG_ID" >/dev/null 2>&1
docker compose exec -T airflow airflow dags trigger "$DAG_ID" >/dev/null 2>&1

echo -n "waiting for the triggered run to write its outputs "
OK_FILE=""
for i in $(seq 1 36); do
    f=$(new_success_file)
    # The file exists and is complete once the full row count is present.
    if [ -n "$f" ] && [ "$(wc -l < "$OK_DIR/$f" | tr -d ' ')" = "527" ]; then
        OK_FILE=$f
        break
    fi
    echo -n "."
    sleep 5
done
echo

assert_eq "triggered run wrote a stamped successful output" \
    "yes" "$([ -n "$OK_FILE" ] && echo yes || echo no)"
[ -n "$OK_FILE" ] || { echo "$PASS passed, $((FAIL)) failed"; exit 1; }

KO_FILE=${OK_FILE/successful/unsuccessful}

assert_eq "successful output holds 526 applications (+ header)" \
    "527" "$(wc -l < "$OK_DIR/$OK_FILE" | tr -d ' ')"

assert_eq "matching unsuccessful output holds 4473 applications (+ header)" \
    "4474" "$(wc -l < "$KO_DIR/$KO_FILE" | tr -d ' ')"

assert_eq "known colliding membership ID appears twice in successful output" \
    "2" "$(grep -c 'Williamson_2b72a' "$OK_DIR/$OK_FILE")"

# The outputs land when the process task finishes; give the quality-gate
# task and the run-state update a moment to reach a terminal state.
run_state=running
for i in $(seq 1 24); do
    run_state=$(docker compose exec -T airflow \
        airflow dags list-runs "$DAG_ID" -o plain 2>/dev/null \
        | grep manual__ | head -1 | awk '{print $3}' || echo unknown)
    case "$run_state" in success|failed) break ;; esac
    sleep 5
done

assert_eq "run state recorded as success in the metadata database" \
    "success" "$run_state"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
