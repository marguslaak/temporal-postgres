-- ============================================================================
-- 06_test.sql
--   Self-checking smoke test. Run after 01..05; it raises on any failure.
--     psql -v ON_ERROR_STOP=1 -f sql/06_test.sql
-- ============================================================================
\set ON_ERROR_STOP on

DO $$
DECLARE
    v_id   bigint;
    v_n    integer;
    v_t0   timestamptz;
    v_t1   timestamptz;
    v_msg  text;
BEGIN
    ------------------------------------------------------------------ INSERT
    INSERT INTO employee (first_name, last_name, department, salary)
    VALUES ('Mari', 'Tamm', 'Payments', 4000.00)
    RETURNING employee_id INTO v_id;

    SELECT count(*) INTO v_n FROM employee_history
     WHERE employee_id = v_id AND operation = 'INSERT' AND valid_to IS NULL;
    ASSERT v_n = 1, 'INSERT must open exactly one history version';

    SELECT valid_from INTO v_t0 FROM employee_history
     WHERE employee_id = v_id AND valid_to IS NULL;

    PERFORM pg_sleep(0.01);

    ------------------------------------------------------------------ UPDATE
    UPDATE employee SET salary = 4500.00, department = 'Treasury'
     WHERE employee_id = v_id;

    SELECT count(*) INTO v_n FROM employee_history WHERE employee_id = v_id;
    ASSERT v_n = 2, format('UPDATE must add a version (have %s, want 2)', v_n);

    SELECT count(*) INTO v_n FROM employee_history
     WHERE employee_id = v_id AND valid_to IS NULL;
    ASSERT v_n = 1, 'exactly one version may be open at a time';

    SELECT count(*) INTO v_n FROM employee_history
     WHERE employee_id = v_id AND ended_by = 'UPDATE' AND salary = 4000.00;
    ASSERT v_n = 1, 'the closed version must keep the old values';

    -- the closed period must abut the open one: no gap, no overlap
    SELECT count(*) INTO v_n
      FROM employee_history a
      JOIN employee_history b
        ON b.employee_id = a.employee_id AND b.valid_from = a.valid_to
     WHERE a.employee_id = v_id AND a.valid_to IS NOT NULL;
    ASSERT v_n = 1, 'history periods must be contiguous';

    v_t1 := clock_timestamp();
    PERFORM pg_sleep(0.01);

    -- time travel: the old salary is still visible as of v_t0
    ASSERT (SELECT salary FROM employee_as_of(v_t0) WHERE employee_id = v_id) = 4000.00,
           'as-of query must return the value that was current then';
    ASSERT (SELECT salary FROM employee_as_of(v_t1) WHERE employee_id = v_id) = 4500.00,
           'as-of query must return the current value for "now"';

    ------------------------------------------------------------------ DELETE
    DELETE FROM employee WHERE employee_id = v_id;

    SELECT count(*) INTO v_n FROM employee_history
     WHERE employee_id = v_id AND valid_to IS NULL;
    ASSERT v_n = 0, 'DELETE must close the open version';

    SELECT count(*) INTO v_n FROM employee_history
     WHERE employee_id = v_id AND ended_by = 'DELETE';
    ASSERT v_n = 1, 'the deleted version must be marked ended_by = DELETE';

    ASSERT (SELECT salary FROM employee_as_of(v_t1) WHERE employee_id = v_id) = 4500.00,
           'a deleted row must still be visible as of a time when it existed';
    ASSERT NOT EXISTS (SELECT 1 FROM employee_as_of(clock_timestamp())
                        WHERE employee_id = v_id),
           'a deleted row must not be visible as of now';

    ---------------------------------------------------- guard: direct INSERT
    BEGIN
        INSERT INTO employee_history (employee_id, first_name, last_name, salary,
                                      hired_on, valid_from, operation, changed_at,
                                      changed_by, changed_role, txid)
        VALUES (-1, 'Fake', 'Row', 0, current_date, now(), 'INSERT', now(),
                session_user, current_user, 0);
        RAISE EXCEPTION 'guard did not block a direct INSERT into the history';
    EXCEPTION WHEN insufficient_privilege THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        RAISE NOTICE 'blocked as expected: %', v_msg;
    END;

    ---------------------------------------------------- guard: direct UPDATE
    BEGIN
        UPDATE employee_history SET salary = 999999 WHERE employee_id = v_id;
        RAISE EXCEPTION 'guard did not block a direct UPDATE of the history';
    EXCEPTION WHEN insufficient_privilege THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        RAISE NOTICE 'blocked as expected: %', v_msg;
    END;

    ---------------------------------------------------- guard: direct DELETE
    BEGIN
        DELETE FROM employee_history WHERE employee_id = v_id;
        RAISE EXCEPTION 'guard did not block a direct DELETE from the history';
    EXCEPTION WHEN insufficient_privilege THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        RAISE NOTICE 'blocked as expected: %', v_msg;
    END;

    -- and the history is untouched after all that
    SELECT count(*) INTO v_n FROM employee_history WHERE employee_id = v_id;
    ASSERT v_n = 2, format('history must be intact after blocked writes (have %s, want 2)', v_n);

    RAISE NOTICE 'row-level tests passed';
END;
$$;

-- TRUNCATE of the history is rejected (statement-level trigger).
DO $$
BEGIN
    TRUNCATE employee_history;
    RAISE EXCEPTION 'guard did not block TRUNCATE of the history';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'blocked as expected: TRUNCATE employee_history';
END;
$$;

-- TRUNCATE of the main table closes every open version instead of losing them.
INSERT INTO employee (first_name, last_name, salary) VALUES ('Jaan', 'Kask', 3000);
TRUNCATE employee;

DO $$
DECLARE v_n integer;
BEGIN
    SELECT count(*) INTO v_n FROM employee_history WHERE valid_to IS NULL;
    ASSERT v_n = 0, 'TRUNCATE of the main table must close all open versions';

    SELECT count(*) INTO v_n FROM employee_history WHERE ended_by = 'TRUNCATE';
    ASSERT v_n = 1, 'the truncated row must be marked ended_by = TRUNCATE';

    RAISE NOTICE 'truncate tests passed';
END;
$$;

-- Back-fill: enabling versioning on a table that already has rows.
CREATE TABLE account (
    iban    text PRIMARY KEY,
    balance numeric(14,2) NOT NULL
);
INSERT INTO account VALUES ('EE001', 10.00), ('EE002', 20.00);
SELECT temporal.enable('account');

DO $$
DECLARE v_n integer;
BEGIN
    SELECT count(*) INTO v_n FROM account_history
     WHERE operation = 'BACKFILL' AND valid_to IS NULL;
    ASSERT v_n = 2, 'existing rows must be back-filled as open versions';

    UPDATE account SET balance = 30.00 WHERE iban = 'EE001';
    SELECT count(*) INTO v_n FROM account_history WHERE iban = 'EE001';
    ASSERT v_n = 2, 'a back-filled row must version normally afterwards';

    RAISE NOTICE 'backfill tests passed';
END;
$$;

SELECT 'ALL TESTS PASSED' AS result;
