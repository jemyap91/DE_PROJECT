# Section 2: PostgreSQL sales database.
#
# The official postgres image executes *.sql and *.sh files placed in
# /docker-entrypoint-initdb.d/ (in lexical order) the first time the data
# directory is initialised, so copying the DDL there is all that is needed
# to stand the database up with its schema, the section 1 member load and
# the sample sales data applied.
FROM postgres:16

# 01_schema.sql              tables, constraints, indexes
# 02_load_members.sh         \copy section 1 successful applications into members
# 03_seed_sales_sample.sql   sample catalogue + transactions for the analyst queries
COPY ddl/ /docker-entrypoint-initdb.d/
COPY data/ /docker-entrypoint-initdb.d/data/

# Credentials are supplied at run time (e.g. --env-file or compose), not
# baked into the image. POSTGRES_PASSWORD is mandatory for the official
# image; these names are defaults for local development only.
ENV POSTGRES_DB=ecommerce
ENV POSTGRES_USER=ecommerce
