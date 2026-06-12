-- Section 2: sales transactions database schema.
--
-- Four tables in third normal form:
--   members            successful membership applications (from section 1)
--   items              the product catalogue
--   transactions       one row per purchase, with the stored totals the
--                      brief requires
--   transaction_items  line items resolving the many-to-many between
--                      transactions and items
--
-- membership_id is NOT the members primary key: the section 1 ID scheme
-- (<last_name>_<first 5 hex chars of sha256(birthday)>) collides for
-- applicants sharing a last name and birthday — the provided datasets
-- already contain a real duplicate (Williamson_2b72a). A surrogate key
-- keeps every member addressable; membership_id stays indexed for lookups.

CREATE TABLE members (
    member_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    membership_id TEXT        NOT NULL,
    first_name    TEXT        NOT NULL,
    last_name     TEXT        NOT NULL,
    email         TEXT        NOT NULL,
    date_of_birth DATE        NOT NULL,
    mobile_no     TEXT        NOT NULL CHECK (mobile_no ~ '^[0-9]{8}$'),
    above_18      BOOLEAN     NOT NULL,
    loaded_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_members_membership_id ON members (membership_id);

CREATE TABLE items (
    item_id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_name         TEXT          NOT NULL,
    manufacturer_name TEXT          NOT NULL,
    -- NUMERIC, never FLOAT: money and weights need exact decimal
    -- arithmetic (binary floats cannot represent 0.10).
    cost              NUMERIC(12,2) NOT NULL CHECK (cost >= 0),
    weight_kg         NUMERIC(8,3)  NOT NULL CHECK (weight_kg > 0),
    UNIQUE (item_name, manufacturer_name)
);

CREATE TABLE transactions (
    transaction_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    member_id       BIGINT        NOT NULL REFERENCES members (member_id),
    transaction_ts  TIMESTAMPTZ   NOT NULL DEFAULT now(),
    -- The brief specifies transactions carry their totals, so they are
    -- stored (denormalised for read speed) rather than derived from the
    -- line items on every query. The loader computes both from the line
    -- items so they cannot drift at insert time.
    total_price     NUMERIC(14,2) NOT NULL CHECK (total_price >= 0),
    total_weight_kg NUMERIC(12,3) NOT NULL CHECK (total_weight_kg >= 0)
);

CREATE INDEX idx_transactions_member_id ON transactions (member_id);
CREATE INDEX idx_transactions_ts ON transactions (transaction_ts);

CREATE TABLE transaction_items (
    transaction_id BIGINT        NOT NULL REFERENCES transactions (transaction_id),
    item_id        BIGINT        NOT NULL REFERENCES items (item_id),
    quantity       INTEGER       NOT NULL CHECK (quantity > 0),
    -- Snapshots of the catalogue values at the time of sale: item cost
    -- and weight change over time, but a transaction must keep recording
    -- what was actually paid and shipped.
    unit_price     NUMERIC(12,2) NOT NULL CHECK (unit_price >= 0),
    unit_weight_kg NUMERIC(8,3)  NOT NULL CHECK (unit_weight_kg > 0),
    PRIMARY KEY (transaction_id, item_id)
);

CREATE INDEX idx_transaction_items_item_id ON transaction_items (item_id);
