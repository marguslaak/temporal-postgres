-- ============================================================================
-- 04_api.sql
--   temporal.enable()  - create the history table and wire up both triggers
--   temporal.disable() - remove the triggers (optionally drop the history)
-- ============================================================================

CREATE OR REPLACE FUNCTION temporal.enable(
    p_table          regclass,
    p_history_table  text     DEFAULT NULL,   -- default: <table>_history, same schema
    p_history_schema text     DEFAULT NULL    -- default: schema of p_table
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
    v_args      text;
    v_prefix    text;
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

    IF EXISTS (SELECT 1 FROM temporal.versioned_table WHERE main_table = p_table) THEN
        RAISE EXCEPTION 'system versioning is already enabled on %', p_table
            USING ERRCODE = 'duplicate_object';
    END IF;

    -- ---------------------------------------------------------------- history
    -- LIKE without INCLUDING DEFAULTS/IDENTITY/GENERATED on purpose: the
    -- history stores the values the main table had, it never generates its own.
    EXECUTE format(
        'CREATE TABLE %I.%I (LIKE %s INCLUDING STORAGE INCLUDING COMMENTS)',
        v_hschema, v_hname, p_table);

    EXECUTE format(
        'ALTER TABLE %I.%I
             ADD COLUMN valid_from   timestamptz NOT NULL,
             ADD COLUMN valid_to     timestamptz,
             ADD COLUMN operation    text        NOT NULL,
             ADD COLUMN ended_by     text,
             ADD COLUMN changed_at   timestamptz NOT NULL,
             ADD COLUMN changed_by   name        NOT NULL,
             ADD COLUMN changed_role name        NOT NULL,
             ADD COLUMN txid         bigint      NOT NULL',
        v_hschema, v_hname);

    v_hist := format('%I.%I', v_hschema, v_hname)::regclass;

    SELECT string_agg(quote_ident(c), ', ') INTO v_keylist FROM unnest(v_key) AS c;

    EXECUTE format(
        'ALTER TABLE %s
             ADD CONSTRAINT %I PRIMARY KEY (%s, valid_from),
             ADD CONSTRAINT %I CHECK (valid_to IS NULL OR valid_to >= valid_from),
             ADD CONSTRAINT %I CHECK (operation IN (''INSERT'', ''UPDATE'', ''BACKFILL'')),
             ADD CONSTRAINT %I CHECK (ended_by IS NULL
                                      OR ended_by IN (''UPDATE'', ''DELETE'', ''TRUNCATE''))',
        v_hist,
        left(v_hname || '_pkey', 63),
        v_keylist,
        left(v_hname || '_period_chk', 63),
        left(v_hname || '_operation_chk', 63),
        left(v_hname || '_ended_by_chk', 63));

    -- At most one open version per key: the core invariant of the timeline.
    EXECUTE format(
        'CREATE UNIQUE INDEX %I ON %s (%s) WHERE valid_to IS NULL',
        left(v_hname || '_open_uq', 63), v_hist, v_keylist);

    -- "what did the world look like at T" scans.
    EXECUTE format(
        'CREATE INDEX %I ON %s (valid_from, valid_to)',
        left(v_hname || '_period_idx', 63), v_hist);

    EXECUTE format('COMMENT ON TABLE %s IS %L', v_hist,
        format('System-versioned history of %s. Maintained by trigger, do not write to it directly.',
               p_table));

    -- ------------------------------------------------------------- triggers 1
    -- populate the history from every change to the main table
    v_prefix := left(v_name, 40);

    SELECT string_agg(quote_literal(c), ', ') INTO v_args FROM unnest(v_key) AS c;

    EXECUTE format(
        'CREATE TRIGGER %I
             AFTER INSERT OR UPDATE OR DELETE ON %s
             FOR EACH ROW
             EXECUTE FUNCTION temporal.versioning(%L, %s)',
        v_prefix || '_versioning', p_table,
        format('%I.%I', v_hschema, v_hname), v_args);

    EXECUTE format(
        'CREATE TRIGGER %I
             BEFORE TRUNCATE ON %s
             FOR EACH STATEMENT
             EXECUTE FUNCTION temporal.versioning_truncate(%L)',
        v_prefix || '_versioning_truncate', p_table,
        format('%I.%I', v_hschema, v_hname));

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

    -- ------------------------------------------------------------- back-fill
    -- Rows that already exist in the main table get an open version so the
    -- history is complete from the moment versioning is switched on.
    PERFORM set_config(temporal.write_flag_name(), 'on', true);
    EXECUTE format(
        'INSERT INTO %1$s
         SELECT r.*
           FROM %2$s AS t
           CROSS JOIN LATERAL jsonb_populate_record(NULL::%1$s, to_jsonb(t) || $1) AS r',
        v_hist, p_table)
    USING jsonb_build_object(
        'valid_from',   now(),
        'valid_to',     NULL,
        'operation',    'BACKFILL',
        'ended_by',     NULL,
        'changed_at',   now(),
        'changed_by',   session_user,
        'changed_role', temporal.acting_role(),
        'txid',         pg_current_xact_id()::text::bigint);
    PERFORM set_config(temporal.write_flag_name(), 'off', true);

    INSERT INTO temporal.versioned_table (main_table, history_table, key_columns)
    VALUES (p_table, v_hist, v_key);

    RETURN v_hist;
END;
$function$;

COMMENT ON FUNCTION temporal.enable(regclass, text, text) IS
  'Creates <table>_history and attaches both triggers: the one that populates '
  'the history on INSERT/UPDATE/DELETE, and the one that protects the history '
  'from direct data manipulation. Existing rows are back-filled.';


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
                   left(v_name, 40) || '_versioning', v_rec.main_table);
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s',
                   left(v_name, 40) || '_versioning_truncate', v_rec.main_table);
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s',
                   left(v_hname, 40) || '_guard', v_rec.history_table);
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s',
                   left(v_hname, 40) || '_guard_truncate', v_rec.history_table);

    IF p_drop_history THEN
        EXECUTE format('DROP TABLE %s', v_rec.history_table);
    END IF;

    DELETE FROM temporal.versioned_table WHERE main_table = p_table;
END;
$function$;

COMMENT ON FUNCTION temporal.disable(regclass, boolean) IS
  'Detaches system versioning from a table; optionally drops the history table.';
