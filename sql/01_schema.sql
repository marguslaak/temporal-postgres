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
    enabled_at      timestamptz NOT NULL DEFAULT now(),
    enabled_by      name        NOT NULL DEFAULT session_user
);

COMMENT ON TABLE temporal.versioned_table IS
  'One row per table that has system versioning enabled via temporal.enable().';

-- ----------------------------------------------------------------------------
-- The name of the session variable that the versioning trigger flips on while
-- it writes to a history table. The guard trigger on the history table lets a
-- write through only while it is set. It is always set with is_local => true,
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
