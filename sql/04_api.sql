-- ============================================================================
-- 04_api.sql
--   temporal.enable()  - add the system period, create the history table,
--                        wire up the triggers and create the query helpers:
--                          <table>_all    view:  base UNION ALL history
--                          <table>_as_of  function: the table at a timestamp
--   temporal.disable() - remove the triggers and the query helpers
--                        (optionally drop the history)
-- ============================================================================

CREATE OR REPLACE FUNCTION temporal.enable(
    p_table          regclass,
    p_history_table  text     DEFAULT NULL,   -- default: <table>_history, same schema
    p_history_schema text     DEFAULT NULL,   -- default: schema of p_table
    p_begin_column   name     DEFAULT 'sys_period_begin',
    p_end_column     name     DEFAULT 'sys_period_end',
    p_user_column    name     DEFAULT NULL,   -- filled with the acting role on every change
    p_delete_image   boolean  DEFAULT false   -- on DELETE, also record a begin = end image
)
RETURNS regclass
LANGUAGE plpgsql
AS $function$
DECLARE
    v_schema    name;
    v_name      name;
    v_hschema   name;
    v_hname     name;
    v_hist      regclass;
    v_key       text[];
    v_keylist   text;
    v_col       name;
    v_type      regtype;
    v_default   text;
    v_prefix    text;
    v_args      text;
    v_view      text;
    v_as_of     text;
BEGIN
    SELECT n.nspname, c.relname
      INTO v_schema, v_name
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.oid = p_table;

    v_hschema := COALESCE(p_history_schema, v_schema);
    v_hname   := COALESCE(p_history_table, v_name || '_history');

    v_key := temporal.primary_key_columns(p_table);
    IF v_key IS NULL THEN
        RAISE EXCEPTION 'table % has no primary key; system versioning needs one '
                        'to identify a row over time', p_table
            USING ERRCODE = 'invalid_table_definition';
    END IF;

    IF p_begin_column = ANY (v_key) OR p_end_column = ANY (v_key) THEN
        RAISE EXCEPTION 'the system period columns of % may not be part of its primary key', p_table
            USING ERRCODE = 'invalid_table_definition';
    END IF;

    IF EXISTS (SELECT 1 FROM temporal.versioned_table WHERE main_table = p_table) THEN
        RAISE EXCEPTION 'system versioning is already enabled on %', p_table
            USING ERRCODE = 'duplicate_object';
    END IF;

    IF p_user_column IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM pg_attribute
            WHERE attrelid = p_table AND attname = p_user_column
              AND attnum > 0 AND NOT attisdropped) THEN
        RAISE EXCEPTION 'user column % does not exist in %', p_user_column, p_table
            USING ERRCODE = 'undefined_column';
    END IF;

    -- ------------------------------------------------------- system period
    -- Added if missing. Existing rows get begin = now, i.e. versioning starts
    -- knowing them from the moment it is switched on.
    FOREACH v_col IN ARRAY ARRAY[p_begin_column, p_end_column] LOOP
        v_default := CASE v_col WHEN p_begin_column THEN 'now()'
                                ELSE 'temporal.end_of_time()' END;

        SELECT atttypid::regtype INTO v_type
          FROM pg_attribute
         WHERE attrelid = p_table AND attname = v_col
           AND attnum > 0 AND NOT attisdropped;

        IF v_type IS NULL THEN
            EXECUTE format('ALTER TABLE %s ADD COLUMN %I timestamptz NOT NULL DEFAULT %s',
                           p_table, v_col, v_default);
        ELSIF v_type <> 'timestamptz'::regtype THEN
            RAISE EXCEPTION 'column %.% must be timestamptz, not %', p_table, v_col, v_type
                USING ERRCODE = 'datatype_mismatch';
        ELSE
            EXECUTE format('ALTER TABLE %s ALTER COLUMN %I SET DEFAULT %s',
                           p_table, v_col, v_default);
            EXECUTE format('UPDATE %s SET %I = %s WHERE %I IS NULL',
                           p_table, v_col, v_default, v_col);
            EXECUTE format('ALTER TABLE %s ALTER COLUMN %I SET NOT NULL', p_table, v_col);
        END IF;
    END LOOP;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = p_table
                      AND conname  = left(v_name || '_sys_period_chk', 63)) THEN
        EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I CHECK (%I <= %I)',
                       p_table, left(v_name || '_sys_period_chk', 63),
                       p_begin_column, p_end_column);
    END IF;

    -- ---------------------------------------------------------------- history
    -- Same definition as the base table; only the primary key differs:
    -- (<base pk>, <begin>). Defaults, identity and generated expressions are
    -- left out on purpose: the history stores the values the base table had,
    -- it never generates its own. An existing history table (e.g. kept by
    -- temporal.disable()) is reused if its layout still matches.
    v_hist := to_regclass(format('%I.%I', v_hschema, v_hname));

    IF v_hist IS NULL THEN
        EXECUTE format(
            'CREATE TABLE %I.%I (LIKE %s INCLUDING CONSTRAINTS INCLUDING STORAGE
                                        INCLUDING COMPRESSION INCLUDING COMMENTS)',
            v_hschema, v_hname, p_table);

        v_hist := format('%I.%I', v_hschema, v_hname)::regclass;

        SELECT string_agg(quote_ident(c), ', ') INTO v_keylist FROM unnest(v_key) AS c;

        EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I PRIMARY KEY (%s, %I)',
                       v_hist, left(v_hname || '_pkey', 63), v_keylist, p_begin_column);

        -- "what did the world look like at T" scans.
        EXECUTE format('CREATE INDEX %I ON %s (%I, %I)',
                       left(v_hname || '_period_idx', 63), v_hist,
                       p_end_column, p_begin_column);

        EXECUTE format('COMMENT ON TABLE %s IS %L', v_hist,
            format('System-versioned history of %s. Maintained by trigger, insert-only.',
                   p_table));
    END IF;

    IF temporal.column_layout(v_hist) IS DISTINCT FROM temporal.column_layout(p_table) THEN
        RAISE EXCEPTION 'history table % does not have the same columns as %', v_hist, p_table
            USING ERRCODE = 'invalid_table_definition',
                  DETAIL  = format('%s has (%s), %s has (%s)',
                                   p_table, array_to_string(temporal.column_layout(p_table), ', '),
                                   v_hist,  array_to_string(temporal.column_layout(v_hist), ', ')),
                  HINT    = 'Apply the same ALTER TABLE to both tables.';
    END IF;

    -- ------------------------------------------------------------- triggers 1
    -- stamp the period on the base table, write before-images to the history
    v_prefix := left(v_name, 40);
    v_args   := format('%L, %L, %L, %L, %L',
                       format('%I.%I', v_hschema, v_hname),
                       p_begin_column, p_end_column,
                       COALESCE(p_user_column, ''), p_delete_image);

    EXECUTE format(
        'CREATE TRIGGER %I
             BEFORE INSERT OR UPDATE ON %s
             FOR EACH ROW
             EXECUTE FUNCTION temporal.stamp_period(%L, %L, %L)',
        v_prefix || '_period', p_table,
        p_begin_column, p_end_column, COALESCE(p_user_column, ''));

    EXECUTE format(
        'CREATE TRIGGER %I
             AFTER UPDATE OR DELETE ON %s
             FOR EACH ROW
             EXECUTE FUNCTION temporal.versioning(%s)',
        v_prefix || '_versioning', p_table, v_args);

    EXECUTE format(
        'CREATE TRIGGER %I
             BEFORE TRUNCATE ON %s
             FOR EACH STATEMENT
             EXECUTE FUNCTION temporal.versioning_truncate(%s)',
        v_prefix || '_versioning_truncate', p_table, v_args);

    -- ------------------------------------------------------------- triggers 2
    -- protect the history table from direct data manipulation
    EXECUTE format(
        'CREATE TRIGGER %I
             BEFORE INSERT OR UPDATE OR DELETE ON %s
             FOR EACH ROW
             EXECUTE FUNCTION temporal.protect_history()',
        left(v_hname, 40) || '_guard', v_hist);
    EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER %I',
        v_hist, left(v_hname, 40) || '_guard');

    EXECUTE format(
        'CREATE TRIGGER %I
             BEFORE TRUNCATE ON %s
             FOR EACH STATEMENT
             EXECUTE FUNCTION temporal.protect_history_truncate()',
        left(v_hname, 40) || '_guard_truncate', v_hist);
    EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER %I',
        v_hist, left(v_hname, 40) || '_guard_truncate');

    -- Belt and braces: the trigger stops mistakes, privileges stop intent.
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON %s FROM PUBLIC', v_hist);

    -- ---------------------------------------------------------- query helpers
    -- Next to the base table. The view's column list is fixed when it is
    -- created; after a schema change disable() + enable() recreates both.
    v_view  := format('%I.%I', v_schema, left(v_name, 59) || '_all');
    v_as_of := format('%I.%I', v_schema, left(v_name, 57) || '_as_of');

    EXECUTE format(
        'CREATE VIEW %s AS
             SELECT * FROM %s
             UNION ALL
             SELECT * FROM %s',
        v_view, p_table, v_hist);

    EXECUTE format('COMMENT ON VIEW %s IS %L', v_view,
        format('Full timeline of %s: current rows UNION ALL history.', p_table));

    EXECUTE format(
        'CREATE FUNCTION %s(p_at timestamptz)
         RETURNS SETOF %s
         LANGUAGE sql STABLE
         AS %L',
        v_as_of, p_table,
        format('SELECT * FROM %s WHERE %I <= p_at AND %I > p_at',
               v_view, p_begin_column, p_end_column));

    EXECUTE format('COMMENT ON FUNCTION %s(timestamptz) IS %L', v_as_of,
        format('The rows of %s as they were at p_at.', p_table));

    INSERT INTO temporal.versioned_table
           (main_table, history_table, key_columns,
            begin_column, end_column, user_column, delete_image,
            all_view, as_of_function)
    VALUES (p_table, v_hist, v_key,
            p_begin_column, p_end_column, p_user_column, p_delete_image,
            v_view, v_as_of || '(timestamptz)');

    RETURN v_hist;
END;
$function$;

COMMENT ON FUNCTION temporal.enable(regclass, text, text, name, name, name, boolean) IS
  'Adds the system period to a table, creates <table>_history with the same '
  'columns and attaches the triggers: the ones that maintain the period and '
  'insert before-images into the history on UPDATE/DELETE, and the ones that '
  'keep the history insert-only. Also creates the <table>_all view and the '
  '<table>_as_of(timestamptz) function.';


-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temporal.disable(
    p_table         regclass,
    p_drop_history  boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    v_rec    temporal.versioned_table%ROWTYPE;
    v_name   name;
    v_hname  name;
BEGIN
    SELECT * INTO v_rec FROM temporal.versioned_table WHERE main_table = p_table;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'system versioning is not enabled on %', p_table
            USING ERRCODE = 'undefined_object';
    END IF;

    SELECT relname INTO v_name  FROM pg_class WHERE oid = v_rec.main_table;
    SELECT relname INTO v_hname FROM pg_class WHERE oid = v_rec.history_table;

    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s',
                   left(v_name, 40) || '_period', v_rec.main_table);
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s',
                   left(v_name, 40) || '_versioning', v_rec.main_table);
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s',
                   left(v_name, 40) || '_versioning_truncate', v_rec.main_table);
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s',
                   left(v_hname, 40) || '_guard', v_rec.history_table);
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s',
                   left(v_hname, 40) || '_guard_truncate', v_rec.history_table);

    EXECUTE format('DROP FUNCTION IF EXISTS %s', v_rec.as_of_function);
    EXECUTE format('DROP VIEW IF EXISTS %s', v_rec.all_view);

    IF p_drop_history THEN
        EXECUTE format('DROP TABLE %s', v_rec.history_table);
    END IF;

    DELETE FROM temporal.versioned_table WHERE main_table = p_table;
END;
$function$;

COMMENT ON FUNCTION temporal.disable(regclass, boolean) IS
  'Detaches system versioning from a table and drops its _all view and _as_of '
  'function; optionally drops the history table. The system period columns '
  'stay on the base table.';
