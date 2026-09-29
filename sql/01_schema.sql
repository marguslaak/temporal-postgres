-- ============================================================================
-- 01_schema.sql
--   Namespace and shared helpers for the temporal (system-versioned) tables.
--
--   Load order: 01_schema -> 02_versioning_trigger -> 03_history_guard
--               -> 04_api -> (optional) 05_example
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS temporal;

COMMENT ON SCHEMA temporal IS
  'System-versioned (temporal) table support: history population triggers and '
  'write protection for history tables.';

-- ----------------------------------------------------------------------------
-- Registry of the tables that are under system versioning.
-- Purely informational, but it makes disable/re-enable and auditing easy.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS temporal.versioned_table (
    main_table      regclass PRIMARY KEY,
    history_table   regclass NOT NULL UNIQUE,
    key_columns     text[]   NOT NULL,
    begin_column    name     NOT NULL,
    end_column      name     NOT NULL,
    user_column     name,
    delete_image    boolean  NOT NULL,
    all_view        text     NOT NULL,   -- base UNION ALL history
    as_of_function  text     NOT NULL,   -- signature, for DROP FUNCTION
    enabled_at      timestamptz NOT NULL DEFAULT now(),
    enabled_by      name        NOT NULL DEFAULT session_user
);

COMMENT ON TABLE temporal.versioned_table IS
  'One row per table that has system versioning enabled via temporal.enable().';

-- ----------------------------------------------------------------------------
-- system-period-end of a row that is current, i.e. still in the base table.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temporal.end_of_time()
RETURNS timestamptz
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT '9999-12-30 00:00:00+00'::timestamptz $$;

-- ----------------------------------------------------------------------------
-- The name of the session variable that the versioning trigger flips on while
-- it writes to a history table. The guard trigger on the history table lets an
-- INSERT through only while it is set. It is always set with is_local => true,
-- so it disappears at the end of the (sub)transaction, even on rollback.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temporal.write_flag_name()
RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT 'temporal.history_write'::text $$;

-- ----------------------------------------------------------------------------
-- Primary key columns of a table, in index order. Those columns identify the
-- "same row over time" and therefore form the temporal key of the history.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temporal.primary_key_columns(p_table regclass)
RETURNS text[]
LANGUAGE sql STABLE
AS $$
    SELECT array_agg(a.attname::text ORDER BY k.ord)
    FROM   pg_index i
    CROSS  JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
    JOIN   pg_attribute a
           ON a.attrelid = i.indrelid
          AND a.attnum   = k.attnum
    WHERE  i.indrelid = p_table
      AND  i.indisprimary;
$$;

-- ----------------------------------------------------------------------------
-- Column layout of a table: name and type of every live column, in order.
-- The base and the history table must return exactly the same thing, which is
-- what lets rows be copied positionally and the two be UNIONed.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temporal.column_layout(p_table regclass)
RETURNS text[]
LANGUAGE sql STABLE
AS $$
    SELECT array_agg(format('%I %s', a.attname, format_type(a.atttypid, a.atttypmod))
                     ORDER BY a.attnum)
    FROM   pg_attribute a
    WHERE  a.attrelid = p_table
      AND  a.attnum > 0
      AND  NOT a.attisdropped;
$$;

-- ----------------------------------------------------------------------------
-- The role the caller is acting as. The versioning trigger runs SECURITY
-- DEFINER, so plain current_user would always report the function owner;
-- the "role" GUC gives the effective role the caller has SET, if any.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temporal.acting_role()
RETURNS name
LANGUAGE sql STABLE
AS $$
    SELECT CASE
             WHEN COALESCE(current_setting('role', true), 'none') IN ('none', '') THEN session_user
             ELSE current_setting('role')::name
           END;
$$;
