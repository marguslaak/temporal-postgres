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
    v_b0   timestamptz;
    v_b1   timestamptz;
    v_t1   timestamptz;
    v_msg  text;
    v_row  employee_history%ROWTYPE;
BEGIN
    ---------------------------------------------------------- same definition
    ASSERT temporal.column_layout('employee') = temporal.column_layout('employee_history'),
           'base and history must have the same columns';

    ------------------------------------------------------------------ INSERT
    INSERT INTO employee (first_name, last_name, department, salary,
                          sys_period_begin, sys_period_end, sys_changed_by)
    VALUES ('Mari', 'Tamm', 'Payments', 4000.00,
            '2000-01-01', '2000-01-02', 'somebody_else')   -- must be overwritten
    RETURNING employee_id, sys_period_begin INTO v_id, v_b0;

    ASSERT v_b0 > now() - interval '1 minute',
           'INSERT must set system-period-begin to the current time';
    ASSERT (SELECT sys_period_end FROM employee WHERE employee_id = v_id) = temporal.end_of_time(),
           'INSERT must set system-period-end to 9999-12-30';
    ASSERT (SELECT sys_changed_by FROM employee WHERE employee_id = v_id) = session_user,
           'the user column must be filled by the versioning';

    SELECT count(*) INTO v_n FROM employee_history WHERE employee_id = v_id;
    ASSERT v_n = 0, 'INSERT must not write to the history';

    PERFORM pg_sleep(0.01);

    ------------------------------------------------------------------ UPDATE
    UPDATE employee SET salary = 4500.00, department = 'Treasury'
     WHERE employee_id = v_id
    RETURNING sys_period_begin INTO v_b1;

    ASSERT v_b1 > v_b0, 'UPDATE must advance system-period-begin of the current row';

    SELECT * INTO v_row FROM employee_history WHERE employee_id = v_id;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    ASSERT v_n = 1, 'UPDATE must insert exactly one before-image';
    ASSERT v_row.salary = 4000.00 AND v_row.department = 'Payments',
           'the before-image must keep the old values';
    ASSERT v_row.sys_period_begin = v_b0, 'the before-image keeps its own begin';
    ASSERT v_row.sys_period_end = v_b1,
           'the before-image must end exactly where the current row begins';

    v_t1 := clock_timestamp();
    PERFORM pg_sleep(0.01);

    -- two updates in a row: periods stay contiguous, keys never collide
    UPDATE employee SET salary = 4600.00 WHERE employee_id = v_id;
    UPDATE employee SET salary = 4700.00 WHERE employee_id = v_id;

    SELECT count(*) INTO v_n
      FROM employee_all a
      JOIN employee_all b
        ON b.employee_id = a.employee_id AND b.sys_period_begin = a.sys_period_end
     WHERE a.employee_id = v_id AND a.sys_period_end <> temporal.end_of_time();
    ASSERT v_n = 3, format('history periods must be contiguous (have %s links, want 3)', v_n);

    -- time travel
    ASSERT (SELECT salary FROM employee_as_of(v_b0) WHERE employee_id = v_id) = 4000.00,
           'as-of query must return the value that was current then';
    ASSERT (SELECT salary FROM employee_as_of(v_t1) WHERE employee_id = v_id) = 4500.00,
           'as-of query must return the value current at t1';
    ASSERT (SELECT salary FROM employee_as_of(clock_timestamp()) WHERE employee_id = v_id) = 4700.00,
           'as-of now must return the current value';

    PERFORM pg_sleep(0.01);

    ------------------------------------------------------------------ DELETE
    DELETE FROM employee WHERE employee_id = v_id;

    SELECT count(*) INTO v_n FROM employee_history WHERE employee_id = v_id;
    ASSERT v_n = 5, format('DELETE must add before-image + delete image (have %s, want 5)', v_n);

    SELECT count(*) INTO v_n FROM employee_history
     WHERE employee_id = v_id AND sys_period_begin = sys_period_end
       AND sys_changed_by = session_user AND salary = 4700.00;
    ASSERT v_n = 1, 'the delete image must have begin = end and record who deleted';

    SELECT count(*) INTO v_n FROM employee_history
     WHERE employee_id = v_id AND sys_period_end = temporal.end_of_time();
    ASSERT v_n = 0, 'no history row may be open';

    ASSERT (SELECT salary FROM employee_as_of(v_t1) WHERE employee_id = v_id) = 4500.00,
           'a deleted row must still be visible as of a time when it existed';
    ASSERT NOT EXISTS (SELECT 1 FROM employee_as_of(clock_timestamp())
                        WHERE employee_id = v_id),
           'a deleted row must not be visible as of now';

    ---------------------------------------------------- guard: direct INSERT
    BEGIN
        INSERT INTO employee_history (employee_id, first_name, last_name, salary, hired_on,
                                      sys_period_begin, sys_period_end)
        VALUES (-1, 'Fake', 'Row', 0, current_date, now(), now());
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

    ------------------------------- guard: UPDATE blocked even with the flag set
    BEGIN
        PERFORM set_config(temporal.write_flag_name(), 'on', true);
        UPDATE employee_history SET salary = 999999 WHERE employee_id = v_id;
        RAISE EXCEPTION 'guard let an UPDATE of the history through';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'blocked as expected: UPDATE with write flag set';
    END;
    PERFORM set_config(temporal.write_flag_name(), 'off', true);

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
    ASSERT v_n = 5, format('history must be intact after blocked writes (have %s, want 5)', v_n);

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

-- TRUNCATE of the base table versions every row as if it had been deleted.
INSERT INTO employee (first_name, last_name, salary) VALUES ('Jaan', 'Kask', 3000);
TRUNCATE employee;

DO $$
DECLARE v_n integer;
BEGIN
    SELECT count(*) INTO v_n FROM employee_history
     WHERE first_name = 'Jaan' AND sys_period_begin < sys_period_end;
    ASSERT v_n = 1, 'TRUNCATE must insert the before-image of every row';

    SELECT count(*) INTO v_n FROM employee_history
     WHERE first_name = 'Jaan' AND sys_period_begin = sys_period_end;
    ASSERT v_n = 1, 'TRUNCATE must insert a delete image when those are enabled';

    RAISE NOTICE 'truncate tests passed';
END;
$$;

-- Enabling versioning on a table that already has rows, with default options.
CREATE TABLE account (
    iban    text PRIMARY KEY,
    balance numeric(14,2) NOT NULL
);
INSERT INTO account VALUES ('EE001', 10.00), ('EE002', 20.00);
SELECT temporal.enable('account');

DO $$
DECLARE v_n integer;
BEGIN
    SELECT count(*) INTO v_n FROM account
     WHERE sys_period_begin <= now() AND sys_period_end = temporal.end_of_time();
    ASSERT v_n = 2, 'existing rows must get a system period';

    SELECT count(*) INTO v_n FROM account_history;
    ASSERT v_n = 0, 'enabling must not write to the history';

    UPDATE account SET balance = 30.00 WHERE iban = 'EE001';
    DELETE FROM account WHERE iban = 'EE002';

    SELECT count(*) INTO v_n FROM account_history;
    ASSERT v_n = 2, 'without delete images, one history row per UPDATE/DELETE';

    RAISE NOTICE 'existing-table tests passed';
END;
$$;

-- disable + re-enable keeps and reuses the history; a mismatch is refused.
SELECT temporal.disable('account');
SELECT temporal.enable('account');

DO $$
BEGIN
    ASSERT (SELECT count(*) FROM account_history) = 2, 're-enable must reuse the history';

    PERFORM temporal.disable('account');
    ALTER TABLE account ADD COLUMN owner text;
    BEGIN
        PERFORM temporal.enable('account');
        RAISE EXCEPTION 'enable accepted a history table with different columns';
    EXCEPTION WHEN invalid_table_definition THEN
        RAISE NOTICE 'refused as expected: history layout differs';
    END;

    RAISE NOTICE 'disable/re-enable tests passed';
END;
$$;

SELECT 'ALL TESTS PASSED' AS result;
