-- Section 3, Design 1: team access strategy for the section 2 database.
--
-- One NOLOGIN group role per team, granted exactly the privileges the
-- team's duties require. People and services get their own LOGIN roles
-- and inherit a team's access through membership, e.g.:
--
--     CREATE ROLE jsmith LOGIN PASSWORD '...' IN ROLE analytics;
--
-- so access is granted/revoked by managing membership, never by
-- per-user grants, and every connection is attributable to a person in
-- the logs.
--
-- Numbered 04_ so it can be dropped into section 2's ddl/ folder and
-- run by the Docker image's init mechanism after the schema, member
-- load, and seed scripts.

-- The logistics workflow needs somewhere to record completion; the
-- section 2 schema has no such field, so add one rather than letting
-- logistics overwrite financial columns.
ALTER TABLE transactions
    ADD COLUMN status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'completed')),
    ADD COLUMN completed_at TIMESTAMPTZ;

-- Nothing is accessible unless explicitly granted below.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

CREATE ROLE logistics NOLOGIN;
CREATE ROLE analytics NOLOGIN;
CREATE ROLE sales     NOLOGIN;

GRANT USAGE ON SCHEMA public TO logistics, analytics, sales;

-- Logistics: read sales details (weights in particular), mark
-- transactions completed. The UPDATE grant is column-level — logistics
-- can set fulfilment fields but can never touch member_id or the
-- financial totals. No access to members: the schema holds PII
-- (email, mobile, birth date) that fulfilment does not need.
GRANT SELECT ON transactions, transaction_items, items TO logistics;
GRANT UPDATE (status, completed_at) ON transactions TO logistics;

-- Analytics: read everything, write nothing. The default-privileges
-- statement extends read access to tables created in future by the
-- admin role, so analysts never silently lose sight of new data.
GRANT SELECT ON ALL TABLES IN SCHEMA public TO analytics;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO analytics;

-- Sales: full management of the item catalogue, nothing else. DELETE
-- is granted, but the foreign key from transaction_items still blocks
-- removing any item with sales history — old items that were never
-- sold can go, the purchase record stays intact.
GRANT SELECT, INSERT, UPDATE, DELETE ON items TO sales;
GRANT USAGE ON SEQUENCE items_item_id_seq TO sales;
