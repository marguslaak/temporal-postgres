-- ============================================================================
-- 03_history_guard.sql
--   Second trigger: protects a history table from direct data manipulation.
--
--   Every INSERT / UPDATE / DELETE on the history table is rejected unless it
--   comes from temporal.versioning() / temporal.versioning_truncate(), which
--   announce themselves by setting the session variable temporal.history_write
--   to 'on' for the duration of their own statements only (is_local => true).
--
--   TRUNCATE of a history table is rejected unconditionally: nothing in this
--   library ever truncates history.
--
--   Attach with (see 04_api.sql, which does this for you):
--
--     CREATE TRIGGER <name>_guard
--         BEFORE INSERT OR UPDATE OR DELETE ON <history_table>
--         FOR EACH ROW EXECUTE FUNCTION temporal.protect_history();
--     ALTER TABLE <history_table> ENABLE ALWAYS TRIGGER <name>_guard;
--
--     CREATE TRIGGER <name>_guard_truncate
--         BEFORE TRUNCATE ON <history_table>
--         FOR EACH STATEMENT EXECUTE FUNCTION temporal.protect_history_truncate();
--     ALTER TABLE <history_table> ENABLE ALWAYS TRIGGER <name>_guard_truncate;
--
--   ENABLE ALWAYS makes the guard fire for replication apply as well, not just
--   for ordinary "origin" sessions.
--
--   NOTE: a trigger keeps honest sessions honest. It stops application bugs,
--   ad-hoc UPDATEs and accidental DELETEs. It is not a defence against the
--   table owner or a superuser, who can ALTER TABLE ... DISABLE TRIGGER. Pair
--   it with privileges (see 04_api.sql: DML on history tables is revoked from
--   PUBLIC, and only the owner of the SECURITY DEFINER trigger functions can
--   write) if you need protection against a malicious role.
-- ============================================================================

CREATE OR REPLACE FUNCTION temporal.protect_history()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
    IF current_setting(temporal.write_flag_name(), true) = 'on' THEN
        -- Written by the versioning trigger: allow it through unchanged.
        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        END IF;
        RETURN NEW;
    END IF;

    RAISE EXCEPTION
        '% on history table % is not allowed', TG_OP, TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME
        USING ERRCODE  = 'insufficient_privilege',
              DETAIL   = format('History is maintained automatically from %s and is append-only.',
                                COALESCE((SELECT v.main_table::text
                                            FROM temporal.versioned_table v
                                           WHERE v.history_table = TG_RELID::regclass),
                                         'the main table')),
              HINT     = 'Change the main table instead; the history follows automatically.';
END;
$function$;

COMMENT ON FUNCTION temporal.protect_history() IS
  'BEFORE INSERT/UPDATE/DELETE row trigger: rejects direct data manipulation of '
  'a history table; only temporal.versioning() may write.';


CREATE OR REPLACE FUNCTION temporal.protect_history_truncate()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
    RAISE EXCEPTION
        'TRUNCATE on history table % is not allowed', TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME
        USING ERRCODE = 'insufficient_privilege',
              HINT    = 'History is append-only. Drop versioning first if you really mean to discard it.';
END;
$function$;

COMMENT ON FUNCTION temporal.protect_history_truncate() IS
  'BEFORE TRUNCATE statement trigger: rejects TRUNCATE of a history table.';
