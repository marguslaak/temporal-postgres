-- ============================================================================
-- 02_versioning_trigger.sql
--   Trigger function that keeps the history table of a main table up to date.
--
--   Attach with (see 04_api.sql, which does this for you):
--
--     CREATE TRIGGER <name>_versioning
--         AFTER INSERT OR UPDATE OR DELETE ON <main_table>
--         FOR EACH ROW EXECUTE FUNCTION
--         temporal.versioning('<history_table>', '<pk col>' [, '<pk col>' ...]);
--
--     CREATE TRIGGER <name>_versioning_truncate
--         BEFORE TRUNCATE ON <main_table>
--         FOR EACH STATEMENT EXECUTE FUNCTION
--         temporal.versioning_truncate('<history_table>');
--
--   History model
--   -------------
--   The history table holds *every* version of a row, including the one that
--   is currently live in the main table:
--
--     valid_from  when this version came into existence
--     valid_to    when it stopped being current; NULL => this is the live row
--     operation   statement that created the version: INSERT | UPDATE
--     ended_by    statement that closed the version:  UPDATE | DELETE | TRUNCATE
--
--   So "the row as of T" is:  valid_from <= T AND (valid_to IS NULL OR valid_to > T)
--   and a deleted row is one whose newest version has ended_by = 'DELETE'.
-- ============================================================================

CREATE OR REPLACE FUNCTION temporal.versioning()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
    v_history   regclass;
    v_main      regclass := TG_RELID::regclass;
    v_key       text[];
    v_now       timestamptz := clock_timestamp();
    v_join      text;
    v_payload   jsonb;
    v_closed    integer;
BEGIN
    IF TG_NARGS < 2 THEN
        RAISE EXCEPTION
            'temporal.versioning() on % needs the history table and at least '
            'one key column as trigger arguments', v_main
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    v_history := TG_ARGV[0]::regclass;
    v_key     := TG_ARGV[1:TG_NARGS - 1];

    -- h.<key> IS NOT DISTINCT FROM k.<key>, where k is the OLD row rebuilt with
    -- its real column types, so keys of any type (uuid, timestamptz, composite,
    -- ...) compare correctly and NULL-able keys behave sanely.
    SELECT string_agg(
               format('h.%1$I IS NOT DISTINCT FROM k.%1$I', c), ' AND ')
      INTO v_join
      FROM unnest(v_key) AS c;

    -- Let the guard trigger on the history table through for the statements
    -- below only. is_local => true: the flag is scoped to this (sub)transaction
    -- and cannot leak out of it, not even if an outer block traps an error.
    PERFORM set_config(temporal.write_flag_name(), 'on', true);

    -- --- close the version that was current until now -----------------------
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        EXECUTE format(
            'UPDATE %1$s AS h
                SET valid_to = $2,
                    ended_by = $3
               FROM jsonb_populate_record(NULL::%2$s, $1) AS k
              WHERE h.valid_to IS NULL
                AND %3$s',
            v_history, v_main, v_join)
        USING to_jsonb(OLD), v_now, TG_OP;

        GET DIAGNOSTICS v_closed = ROW_COUNT;

        -- No open version means the row predates versioning (or history was
        -- tampered with). Back-fill one so the timeline is not silently torn.
        IF v_closed = 0 THEN
            v_payload := to_jsonb(OLD) || jsonb_build_object(
                'valid_from',    '-infinity'::timestamptz,
                'valid_to',      v_now,
                'operation',     'BACKFILL',
                'ended_by',      TG_OP,
                'changed_at',    v_now,
                'changed_by',    session_user,
                'changed_role',  temporal.acting_role(),
                'txid',          pg_current_xact_id()::text::bigint);

            EXECUTE format(
                'INSERT INTO %1$s SELECT * FROM jsonb_populate_record(NULL::%1$s, $1)',
                v_history)
            USING v_payload;
        END IF;
    END IF;

    -- --- open the new current version ---------------------------------------
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        v_payload := to_jsonb(NEW) || jsonb_build_object(
            'valid_from',   v_now,
            'valid_to',     NULL,
            'operation',    TG_OP,
            'ended_by',     NULL,
            'changed_at',   v_now,
            'changed_by',   session_user,
            'changed_role', temporal.acting_role(),
            'txid',         pg_current_xact_id()::text::bigint);

        EXECUTE format(
            'INSERT INTO %1$s SELECT * FROM jsonb_populate_record(NULL::%1$s, $1)',
            v_history)
        USING v_payload;
    END IF;

    PERFORM set_config(temporal.write_flag_name(), 'off', true);

    RETURN NULL;   -- AFTER trigger: return value is ignored
END;
$function$;

COMMENT ON FUNCTION temporal.versioning() IS
  'AFTER INSERT/UPDATE/DELETE row trigger: maintains the history table given as '
  'TG_ARGV[0], keyed by the columns in TG_ARGV[1..].';


-- ----------------------------------------------------------------------------
-- TRUNCATE bypasses row triggers entirely, so it needs its own statement
-- trigger, otherwise a TRUNCATE would leave every history row open forever.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temporal.versioning_truncate()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
    v_history regclass := TG_ARGV[0]::regclass;
    v_now     timestamptz := clock_timestamp();
BEGIN
    PERFORM set_config(temporal.write_flag_name(), 'on', true);

    EXECUTE format(
        'UPDATE %1$s SET valid_to = $1, ended_by = ''TRUNCATE'' WHERE valid_to IS NULL',
        v_history)
    USING v_now;

    PERFORM set_config(temporal.write_flag_name(), 'off', true);

    RETURN NULL;
END;
$function$;

COMMENT ON FUNCTION temporal.versioning_truncate() IS
  'BEFORE TRUNCATE statement trigger: closes every open version in the history '
  'table given as TG_ARGV[0].';
