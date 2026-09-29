-- ============================================================================
-- 02_versioning_trigger.sql
--   Trigger functions that maintain the system period of the base table and
--   append before-images to its history table.
--
--   Attach with (see 04_api.sql, which does this for you):
--
--     CREATE TRIGGER <name>_period
--         BEFORE INSERT OR UPDATE ON <base_table>
--         FOR EACH ROW EXECUTE FUNCTION
--         temporal.stamp_period('<begin col>', '<end col>', '<user col or empty>');
--
--     CREATE TRIGGER <name>_versioning
--         AFTER UPDATE OR DELETE ON <base_table>
--         FOR EACH ROW EXECUTE FUNCTION
--         temporal.versioning('<history_table>', '<begin col>', '<end col>',
--                             '<user col or empty>', '<delete image: true|false>');
--
--     CREATE TRIGGER <name>_versioning_truncate
--         BEFORE TRUNCATE ON <base_table>
--         FOR EACH STATEMENT EXECUTE FUNCTION
--         temporal.versioning_truncate(<same arguments as temporal.versioning>);
--
--   History model
--   -------------
--   The base and the history table have exactly the same columns, including
--   the system period  [system-period-begin, system-period-end).
--
--     INSERT  new row in base:   begin = now, end = 9999-12-30.
--             Nothing is written to the history.
--     UPDATE  before-image -> history with end = now;
--             the current row in base gets begin = the same now.
--     DELETE  before-image -> history with end = now.
--             Optionally a second image with begin = end = now, whose user
--             column records who deleted the row.
--
--   The history is only ever INSERTed into, never updated or deleted from.
--   "The table as of T" is  begin <= T AND end > T  over base UNION ALL history.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- SELECT list that copies a row of p_table column by column, in order, with
-- the columns named in p_cols replaced by the matching SQL in p_exprs.
--
-- Field access on the row is used rather than jsonb_populate_record(row, ...)
-- because the latter loses the value of columns that were added with
-- ALTER TABLE ... ADD COLUMN ... DEFAULT and never rewritten ("fast default").
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temporal.image_select_list(
    p_table regclass,
    p_row   text,
    p_cols  text[],
    p_exprs text[]
)
RETURNS text
LANGUAGE sql STABLE
AS $$
    SELECT string_agg(COALESCE(p_exprs[array_position(p_cols, a.attname::text)],
                               format('%s.%I', p_row, a.attname)),
                      ', ' ORDER BY a.attnum)
    FROM   pg_attribute a
    WHERE  a.attrelid = p_table
      AND  a.attnum > 0
      AND  NOT a.attisdropped;
$$;

-- ----------------------------------------------------------------------------
-- BEFORE INSERT/UPDATE: the period columns (and the user column, if any) are
-- owned by the versioning; whatever the statement supplied is overwritten.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temporal.stamp_period()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
    v_begin_col text := TG_ARGV[0];
    v_end_col   text := TG_ARGV[1];
    v_user_col  text := NULLIF(TG_ARGV[2], '');
    v_now       timestamptz := clock_timestamp();
    v_begin     timestamptz;
    v_patch     jsonb;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        -- Periods must strictly advance, or the before-image would get an
        -- empty period and the history key (pk, begin) could collide.
        EXECUTE format('SELECT ($1).%I', v_begin_col) INTO v_begin USING OLD;
        v_now := greatest(v_now, v_begin + interval '1 microsecond');
    END IF;

    v_patch := jsonb_build_object(v_begin_col, v_now,
                                  v_end_col,   temporal.end_of_time());
    IF v_user_col IS NOT NULL THEN
        v_patch := v_patch || jsonb_build_object(v_user_col, temporal.acting_role());
    END IF;

    NEW := jsonb_populate_record(NEW, v_patch);
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION temporal.stamp_period() IS
  'BEFORE INSERT/UPDATE row trigger: sets system-period-begin to now and '
  'system-period-end to temporal.end_of_time() on the base table row.';


-- ----------------------------------------------------------------------------
-- AFTER UPDATE/DELETE: append the before-image to the history.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temporal.versioning()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
    v_history      regclass := TG_ARGV[0]::regclass;
    v_begin_col    text     := TG_ARGV[1];
    v_end_col      text     := TG_ARGV[2];
    v_user_col     text     := NULLIF(TG_ARGV[3], '');
    v_delete_image boolean  := TG_ARGV[4]::boolean;
    v_now          timestamptz;
    v_begin        timestamptz;
BEGIN
    IF TG_NARGS <> 5 THEN
        RAISE EXCEPTION
            'temporal.versioning() on % needs 5 trigger arguments, got %',
            TG_RELID::regclass, TG_NARGS
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF TG_OP = 'UPDATE' THEN
        -- The before-image ends exactly where the new current row begins.
        EXECUTE format('SELECT ($1).%I', v_begin_col) INTO v_now USING NEW;
    ELSE
        EXECUTE format('SELECT ($1).%I', v_begin_col) INTO v_begin USING OLD;
        v_now := greatest(clock_timestamp(), v_begin + interval '1 microsecond');
    END IF;

    -- Let the guard trigger on the history table through for the statements
    -- below only. is_local => true: the flag is scoped to this (sub)transaction
    -- and cannot leak out of it, not even if an outer block traps an error.
    PERFORM set_config(temporal.write_flag_name(), 'on', true);

    -- Positional copy: base and history have the same column layout.
    EXECUTE format('INSERT INTO %s SELECT %s', v_history,
                   temporal.image_select_list(TG_RELID, '($1)',
                                              ARRAY[v_end_col], ARRAY['$2']))
    USING OLD, v_now;

    IF TG_OP = 'DELETE' AND v_delete_image THEN
        EXECUTE format('INSERT INTO %s SELECT %s', v_history,
                       temporal.image_select_list(TG_RELID, '($1)',
                                                  ARRAY[v_begin_col, v_end_col, v_user_col],
                                                  ARRAY['$2', '$2', '$3']))
        USING OLD, v_now, temporal.acting_role();
    END IF;

    PERFORM set_config(temporal.write_flag_name(), 'off', true);

    RETURN NULL;   -- AFTER trigger: return value is ignored
END;
$function$;

COMMENT ON FUNCTION temporal.versioning() IS
  'AFTER UPDATE/DELETE row trigger: inserts the before-image of the row into the '
  'history table given as TG_ARGV[0], with system-period-end = now.';


-- ----------------------------------------------------------------------------
-- TRUNCATE bypasses row triggers entirely, so it needs its own statement
-- trigger; it versions every row as if it had been deleted.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temporal.versioning_truncate()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
    v_history      regclass := TG_ARGV[0]::regclass;
    v_begin_col    text     := TG_ARGV[1];
    v_end_col      text     := TG_ARGV[2];
    v_user_col     text     := NULLIF(TG_ARGV[3], '');
    v_delete_image boolean  := TG_ARGV[4]::boolean;
    v_now          timestamptz := clock_timestamp();
    v_end          text;
BEGIN
    v_end := format('greatest($1, t.%I + interval ''1 microsecond'')', v_begin_col);

    PERFORM set_config(temporal.write_flag_name(), 'on', true);

    EXECUTE format('INSERT INTO %s SELECT %s FROM %s AS t', v_history,
                   temporal.image_select_list(TG_RELID, 't', ARRAY[v_end_col], ARRAY[v_end]),
                   TG_RELID::regclass)
    USING v_now;

    IF v_delete_image THEN
        EXECUTE format('INSERT INTO %s SELECT %s FROM %s AS t', v_history,
                       temporal.image_select_list(TG_RELID, 't',
                                                  ARRAY[v_begin_col, v_end_col, v_user_col],
                                                  ARRAY[v_end, v_end, '$2']),
                       TG_RELID::regclass)
        USING v_now, temporal.acting_role();
    END IF;

    PERFORM set_config(temporal.write_flag_name(), 'off', true);

    RETURN NULL;
END;
$function$;

COMMENT ON FUNCTION temporal.versioning_truncate() IS
  'BEFORE TRUNCATE statement trigger: inserts every row of the base table into '
  'the history table given as TG_ARGV[0], as if each had been deleted.';
