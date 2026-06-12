#!/bin/bash
# Load the successful membership applications produced by the section 1
# pipeline into the members table. This is the storage leg of the
# application pipeline: processed applications land here for reference.
#
# The official postgres image executes *.sh scripts in
# /docker-entrypoint-initdb.d/ on first start, after the *.sql files.
# \copy streams the CSV through the client, so the data file only needs
# to be readable inside the container.
set -euo pipefail

psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\copy members (membership_id, first_name, last_name, email, date_of_birth, mobile_no, above_18) FROM '/docker-entrypoint-initdb.d/data/applications_successful.csv' WITH (FORMAT csv, HEADER true)"
