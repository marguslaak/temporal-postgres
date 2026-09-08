-- ============================================================================
-- 00_install.sql
--   Installs the temporal table support. Run as a role that may create the
--   schema and that owns (or may write to) the history tables:
--
--     psql -v ON_ERROR_STOP=1 -f sql/00_install.sql
--
--   The example table and the test suite are deliberately NOT installed here;
--   run sql/05_example.sql and sql/06_test.sql yourself if you want them.
-- ============================================================================
\set ON_ERROR_STOP on

\ir 01_schema.sql
\ir 02_versioning_trigger.sql
\ir 03_history_guard.sql
\ir 04_api.sql
