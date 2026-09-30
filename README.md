# Temporal (system-versioned) tables for PostgreSQL
Some scripts and database triggers for PostgreSQL to add Temporal characteristics to database tables

The base table and its history table have **exactly the same definition**,
including the system period columns `sys_period_begin` / `sys_period_end`
and the user column `sys_changed_by`. Those three columns are populated only
by the versioning: `sys_changed_by` is set to the acting role on every
`INSERT` and `UPDATE`, so every version says who made it. Because the tables
match, the history is created `LIKE` the base table, and the two can be
`UNION ALL`-ed to query the full timeline.

| Statement on the base table | Base table | History table |
|---|---|---|
| `INSERT` | new row, `begin = now`, `end = 9999-12-30 00:00:00`, `sys_changed_by = user` | nothing |
| `UPDATE` | current row gets `begin = now`, `sys_changed_by = user` | before-image inserted with `end = now` |
| `DELETE` | row removed | before-image inserted with `end = now`, **plus a delete image**: a copy with `begin = end = now` and `sys_changed_by` = the user who deleted it |
| `TRUNCATE` | all rows removed | every row versioned as if deleted |

Rows are only ever **inserted** into the history, never updated or deleted, so
the history is immutable: it only grows. A guard trigger on the history table
enforces this: direct `INSERT` is rejected, and `UPDATE` / `DELETE` /
`TRUNCATE` are rejected unconditionally.

Requires PostgreSQL 13+. No extensions.

## Install

```sh
psql -v ON_ERROR_STOP=1 -f sql/00_install.sql        # schema + trigger functions + API
psql -v ON_ERROR_STOP=1 -f sql/05_example.sql        # optional: demo table
psql -v ON_ERROR_STOP=1 -f sql/06_test.sql           # optional: self-checking test suite
```

| File | Contents |
|---|---|
| `sql/01_schema.sql` | `temporal` schema, registry table, helpers (`end_of_time()`, ...) |
| `sql/02_versioning_trigger.sql` | `temporal.stamp_period()`, `temporal.versioning()`, `temporal.versioning_truncate()` |
| `sql/03_history_guard.sql` | `temporal.protect_history()`, `temporal.protect_history_truncate()` — keep history insert-only |
| `sql/04_api.sql` | `temporal.enable()` / `temporal.disable()` — add the period, create history, attach triggers, create `_all` view and `_as_of()` function |
| `sql/05_example.sql` | `employee` table under versioning |
| `sql/06_test.sql` | Asserts insert/update/delete/truncate/guard/re-enable behaviour |

## Use

```sql
SELECT temporal.enable('employee');            -- adds the period and user columns if missing,
                                               -- creates employee_history + triggers,
                                               -- employee_all and employee_as_of()
SELECT temporal.enable('employee', p_user_column => 'changed_by');  -- your own user column
SELECT temporal.enable('employee', 'employee_audit', 'archive');  -- custom name/schema
SELECT temporal.disable('employee');           -- detach; add true to drop the history
```

The base table needs a primary key: it is what identifies "the same row"
across time. If the period columns are missing, `enable()` adds them and gives
existing rows `begin = now()`. If they already exist, they must be
`timestamptz`. A missing user column is added as `name`; existing rows get
`NULL` there, because who made them is not known. Enabling writes nothing to
the history.

`enable()` also creates two query helpers next to the base table:

| Object | What it is |
|---|---|
| `<table>_all` | view: `SELECT * FROM <table> UNION ALL SELECT * FROM <table>_history` |
| `<table>_as_of(p_at timestamptz)` | `SETOF <table>`: the rows of the table as they were at `p_at` |

`disable()` drops both again.

## Table layout

Base and history have the same columns in the same order. The **only**
difference is the primary key:

| Table | Primary key |
|---|---|
| base | `(<pk cols>)` |
| history | `(<pk cols>, sys_period_begin)` |

Both carry `CHECK (sys_period_begin <= sys_period_end)`. The history also gets
an index on `(sys_period_end, sys_period_begin)` for as-of scans. Defaults,
identity and generated expressions are not copied to the history: it stores
the values the base table had and never generates its own.

Periods are half-open, `[begin, end)`, and abut exactly: a before-image's
`end` equals the next version's `begin`. A row in the base table always has
`end = temporal.end_of_time()` (`9999-12-30 00:00:00+00`).

```sql
-- full timeline of one row
SELECT * FROM employee_all WHERE employee_id = 1 ORDER BY sys_period_begin;

-- the table as it was at a point in time
SELECT * FROM employee_as_of('2026-01-01 12:00+02');
-- which is
SELECT * FROM employee_all
 WHERE sys_period_begin <= '2026-01-01 12:00+02'
   AND sys_period_end   >  '2026-01-01 12:00+02';

-- what was deleted, when, and by whom
SELECT sys_changed_by AS deleted_by, sys_period_end AS deleted_at, *
  FROM employee_history
 WHERE sys_period_begin = sys_period_end;
```

Every `DELETE` leaves two rows in the history. The before-image keeps who last
changed the row. The delete image has the same values but `begin = end` = the
delete time, and `sys_changed_by` = who deleted it. Because it is zero-length,
it never matches an as-of query; it exists only to preserve who deleted the
row.

## How the guard lets the trigger through

`temporal.versioning()` sets the session variable `temporal.history_write` to
`on` with `is_local => true` for the duration of its own statements, and back to
`off` immediately after. The guard trigger lets an `INSERT` through only while
that flag is set; `UPDATE` and `DELETE` are never let through. Because the
setting is transaction-local it cannot leak out of the statement, and it is
rolled back with the (sub)transaction on any error.

A trigger keeps honest sessions honest — it stops application bugs, ad-hoc
`UPDATE`s and mistyped `DELETE`s. It is not a wall against a determined role,
which is why two more things are done:

* The versioning functions are `SECURITY DEFINER` and `temporal.enable()` runs
  `REVOKE INSERT, UPDATE, DELETE, TRUNCATE ... FROM PUBLIC` on the history
  table. Grant your application role DML on the *base* table and `SELECT` only
  on the history; it then physically cannot write history except through the
  trigger.
* The guard triggers are created `ENABLE ALWAYS`, so they also fire during
  logical replication apply, not just in ordinary sessions.

What still gets past it: the table owner and superusers, who can
`ALTER TABLE ... DISABLE TRIGGER` or `DROP TRIGGER`. Own the tables with a role
your application does not log in as.

## Notes and limits

* **Schema changes.** Base and history must keep the same columns. Apply the
  same `ALTER TABLE` to both. `temporal.enable()` refuses to reuse a history
  table whose columns differ, and the versioning trigger fails loudly if they
  drift apart. The `_all` view keeps the column list it was created with, so
  after a schema change run `temporal.disable(t)` / `temporal.enable(t)` to
  recreate it (the history is kept).
* **Re-enabling.** `temporal.disable(t)` keeps the history table. A later
  `temporal.enable(t)` reuses it if the layout still matches. Changes made
  while versioning was off are not in the history.
* **Timestamps** come from `clock_timestamp()`, not `now()`, so several changes
  to the same row inside one transaction get distinct, ordered versions. A new
  `begin` is always at least 1 µs after the previous one, so the history key
  `(pk, begin)` never collides.
* **The period and user columns are owned by the versioning.** Values supplied
  in `INSERT` / `UPDATE` are overwritten.
