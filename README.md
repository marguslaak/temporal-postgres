# Temporal (system-versioned) tables for PostgreSQL
Some scripts and database triggers for PostgreSQL to add Temporal characteristics to database tables

Two triggers per table:

1. **Versioning trigger** on the *main* table — every `INSERT`, `UPDATE`,
   `DELETE` (and `TRUNCATE`) is written into a *history* table automatically.
2. **Guard trigger** on the *history* table — direct `INSERT` / `UPDATE` /
   `DELETE` / `TRUNCATE` against the history is rejected. Only the versioning
   trigger may write there.

Requires PostgreSQL 13+ (`pg_current_xact_id`). No extensions.

## Install

```sh
psql -v ON_ERROR_STOP=1 -f sql/00_install.sql        # schema + both triggers' functions + API
psql -v ON_ERROR_STOP=1 -f sql/05_example.sql        # optional: demo table
psql -v ON_ERROR_STOP=1 -f sql/06_test.sql           # optional: self-checking test suite
```

| File | Contents |
|---|---|
| `sql/01_schema.sql` | `temporal` schema, registry table, helpers |
| `sql/02_versioning_trigger.sql` | `temporal.versioning()`, `temporal.versioning_truncate()` — populate history |
| `sql/03_history_guard.sql` | `temporal.protect_history()`, `temporal.protect_history_truncate()` — block direct DML |
| `sql/04_api.sql` | `temporal.enable()` / `temporal.disable()` — create history table, attach triggers |
| `sql/05_example.sql` | `employee` table + `employee_as_of(timestamptz)` |
| `sql/06_test.sql` | Asserts insert/update/delete/truncate/back-fill/guard behaviour |

## Use

```sql
SELECT temporal.enable('employee');            -- creates employee_history + 4 triggers
SELECT temporal.enable('employee', 'employee_audit', 'archive');  -- custom name/schema
SELECT temporal.disable('employee');           -- detach; add true to drop the history
```

The main table needs a primary key: it is what identifies "the same row" across
time. Existing rows are back-filled as open versions when versioning is enabled.

## History layout

The history table is `LIKE` the main table (same columns, no defaults, no
identity, no generated expressions) plus:

| Column | Meaning |
|---|---|
| `valid_from` | when this version became current |
| `valid_to` | when it stopped being current; `NULL` = this is the live row |
| `operation` | what created it: `INSERT`, `UPDATE`, `BACKFILL` |
| `ended_by` | what closed it: `UPDATE`, `DELETE`, `TRUNCATE`, `NULL` if still open |
| `changed_at` | timestamp of the change (`clock_timestamp()`) |
| `changed_by` | `session_user` — the logged-in role |
| `changed_role` | the role the caller was acting as (`SET ROLE`-aware) |
| `txid` | transaction id of the change |

Constraints created for you: `PRIMARY KEY (<pk cols>, valid_from)`,
`CHECK (valid_to >= valid_from)`, a **partial unique index on the key where
`valid_to IS NULL`** (at most one open version per row — the core invariant),
and an index on `(valid_from, valid_to)` for as-of scans.

Every version of a row is in the history, including the one currently live in
the main table. Periods abut exactly: a closed version's `valid_to` equals the
next version's `valid_from`, so there are no gaps and no overlaps.

```sql
-- full timeline of one row
SELECT * FROM employee_history WHERE employee_id = 1 ORDER BY valid_from;

-- the table as it was at a point in time
SELECT * FROM employee_history
 WHERE valid_from <= '2026-01-01 12:00+02'
   AND (valid_to IS NULL OR valid_to > '2026-01-01 12:00+02');

-- what was deleted, and by whom
SELECT changed_by, valid_to, * FROM employee_history WHERE ended_by = 'DELETE';
```

## How the guard lets the trigger through

`temporal.versioning()` sets the session variable `temporal.history_write` to
`on` with `is_local => true` for the duration of its own statements, and back to
`off` immediately after. The guard trigger passes a write only while that flag
is set. Because the setting is transaction-local it cannot leak out of the
statement, and it is rolled back with the (sub)transaction on any error.

A trigger keeps honest sessions honest — it stops application bugs, ad-hoc
`UPDATE`s and mistyped `DELETE`s. It is not a wall against a determined role,
which is why two more things are done:

* The versioning functions are `SECURITY DEFINER` and `temporal.enable()` runs
  `REVOKE INSERT, UPDATE, DELETE, TRUNCATE ... FROM PUBLIC` on the history
  table. Grant your application role DML on the *main* table and `SELECT` only
  on the history; it then physically cannot write history except through the
  trigger.
* The guard triggers are created `ENABLE ALWAYS`, so they also fire during
  logical replication apply, not just in ordinary sessions.

What still gets past it: the table owner and superusers, who can
`ALTER TABLE ... DISABLE TRIGGER` or `DROP TRIGGER`. Own the tables with a role
your application does not log in as.

## Notes and limits

* **Schema changes.** Adding a column to the main table does not add it to the
  history. Apply the same `ALTER TABLE` to both (the history column must be
  nullable), or `temporal.disable(t)` / `ALTER` / `temporal.enable(t)` if you do
  not need to keep the old history.
* **Timestamps** come from `clock_timestamp()`, not `now()`, so several changes
  to the same row inside one transaction get distinct, ordered versions.
* **`TRUNCATE` of the main table** closes every open version (`ended_by =
  'TRUNCATE'`) rather than losing them silently.
* A row changed while versioning was off gets a `BACKFILL` version with
  `valid_from = -infinity` when it is next updated, so the timeline is never
  silently torn.
