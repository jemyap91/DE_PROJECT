# Section 3, Design 1: Database Access Strategy

A role-based access strategy for the section 2 sales database, implemented
as PostgreSQL roles and grants in `04_access_control.sql` and verified by
an integration test.

## Strategy

**One group role per team, least privilege, attributable logins.**

PostgreSQL's native role system is the access mechanism — no application
middleware required, and the rules hold no matter which client connects
(psql, a BI tool, a service). Three NOLOGIN group roles carry the
privileges; humans and services get individual LOGIN roles that inherit a
team's access through membership:

```sql
CREATE ROLE jsmith LOGIN PASSWORD '...' IN ROLE analytics;
```

Joiners/movers/leavers are handled with `GRANT analytics TO jsmith` /
`REVOKE analytics FROM jsmith` — privileges are never granted to
individuals directly, and every connection in the logs maps to a person
or service, not a shared account.

The baseline is deny-by-default: all privileges are revoked from
`PUBLIC`, so a role with no team membership can read nothing (tested).

## What each team gets

| | members | items | transactions | transaction_items |
|---|---|---|---|---|
| **logistics** | — | SELECT | SELECT + UPDATE of `status`, `completed_at` only | SELECT |
| **analytics** | SELECT | SELECT | SELECT | SELECT |
| **sales** | — | SELECT, INSERT, UPDATE, DELETE | — | — |

### Logistics — read sales details, mark transactions completed

- `SELECT` on `transactions`, `transaction_items`, `items` covers "get
  the sales details, in particular the weight of the total items bought"
  (`transactions.total_weight_kg`, with per-item weights one join away).
- The section 2 schema had nowhere to record completion, so the script
  adds `status` (`pending`/`completed`, CHECK-constrained) and
  `completed_at` to `transactions`.
- The `UPDATE` grant is **column-level**: logistics can set the two
  fulfilment columns and nothing else. Even a buggy or compromised
  logistics client cannot alter `total_price`, `total_weight_kg`, or
  re-point a transaction at another member.
- No access to `members`: fulfilment does not need email, mobile, or
  birth date, so the PII is simply not visible to this team.

### Analytics — analyse everything, update nothing

- `SELECT` on all tables ("sales and membership status" analysis needs
  the full joinable picture), and **no write grants of any kind** — the
  brief's "should not be able to perform updates" falls out of
  deny-by-default rather than needing explicit revokes.
- `ALTER DEFAULT PRIVILEGES ... GRANT SELECT` extends read access to
  tables the admin role creates in future, so the analytics grant
  doesn't rot as the schema grows (tested by creating a table after the
  grants ran).
- In production, PII exposure to analysts would be narrowed further with
  a masking view or column-level SELECT grants on `members`; kept out of
  scope here as the brief asks for analysis access to membership status.

### Sales — manage the item catalogue

- Full DML on `items` only: "update database with new items" (INSERT,
  plus UPDATE for price/weight corrections) and "remove old items"
  (DELETE).
- The foreign key from `transaction_items` is deliberately left strict
  (no `ON DELETE CASCADE`): an item that has ever been sold cannot be
  deleted, because removing it would orphan or destroy purchase history
  that logistics and analytics depend on. Old items that were never sold
  delete cleanly. If the catalogue needs to hide discontinued items that
  *have* sold, the path is a soft-delete flag (`discontinued_at`) — a
  one-line schema addition that doesn't change this access model.

## Files

```
design1/
├── 04_access_control.sql    # roles, grants, fulfilment columns
├── test_access_control.sh   # integration test (20 assertions)
└── README.md
```

`04_access_control.sql` is numbered so it can be dropped into section 2's
`ddl/` folder, where the Docker image's init mechanism runs it after the
schema, member load, and seed scripts. It can equally be applied to a
running instance with `psql -f`.

## Testing

```bash
./test_access_control.sh
```

Reuses the section 2 harness: stands up a throwaway local PostgreSQL (no
Docker needed), applies the section 2 DDL + data and then the access
controls, and asserts every allow *and* every deny per team — including
that logistics' column-level UPDATE cannot touch totals, that analytics
can read tables created after the grants ran, that the FK blocks sales
from deleting sold items, and that a fresh role with no membership can
read nothing.

Current result: **20 passed, 0 failed** (PostgreSQL 16).

## Assumptions

- The admin/owner role (the Docker image's `ecommerce` superuser locally;
  a managed master user in production) applies migrations and is not used
  for day-to-day team access.
- "Completed transactions" is a fulfilment state, modelled as a status
  column on `transactions`; a fuller order-lifecycle (shipped, returned,
  …) would extend the CHECK constraint without changing the grants.
- Credential hygiene (password policy, TLS enforcement in `pg_hba.conf`,
  secret storage) is deployment configuration, out of scope of the SQL.
