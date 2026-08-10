-- ===========================================================================
-- One LOGIN role per database. Runs as the superuser, on EVERY start.
--
-- Creates a role if absent, and ALWAYS re-asserts its password — that is what
-- makes rotating a ${*_DB_PASSWORD} in .env.dev take effect on the next `up`
-- with no data wipe. `docker-entrypoint-initdb.d` cannot do this: it runs only
-- when the data directory is empty.
--
-- Before consolidation every service connected as `postgres` (superuser) with a
-- per-INSTANCE password. That was safe only because the instances were
-- separate. One instance + one shared superuser would mean a single leaked
-- password reaches every database, including the ones it has no business in.
-- ===========================================================================
\set ON_ERROR_STOP on

-- ALTER ROLE ... PASSWORD is echoed verbatim into the server log when
-- log_statement is 'ddl' or 'all'. The default is 'none', but pin it for this
-- session so a server configured to log DDL does not persist seven cleartext
-- passwords. (password_encryption defaults to scram-sha-256, so nothing is
-- cleartext at rest.)
SET log_statement = 'none';

-- INHERIT (the default) is load-bearing, not decoration. A database owner is an
-- implicit member of pg_database_owner, which owns schema `public` on PG15+;
-- that membership is only usable if the role INHERITs. Create these NOINHERIT
-- and applying a schema starts failing with "must be owner of schema public".
-- 20-schema-owner.sql makes ownership direct so we do not depend on this, but
-- the two together are the belt and the braces.
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY[
    'crm_svc',
    'allocation_key_svc',
    'simulation_key_svc',
    'news_board_svc',
    'billing_svc',
    'administrative_document_svc',
    'notification_dispatch_svc'
  ] LOOP
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format(
        'CREATE ROLE %I LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION',
        r);
    END IF;
  END LOOP;
END $$;

-- :'name' — psql emits the value as a correctly escaped SQL string literal, so
-- a password containing a quote, a backslash or a newline cannot break out.
-- Never :name (raw substitution) and never -c "... PASSWORD '$PW'" (shell
-- interpolation AND raw substitution). Contrast :"name", which is a quoted
-- IDENTIFIER — right for SET ROLE, wrong for a password.
ALTER ROLE crm_svc                     WITH LOGIN PASSWORD :'crm_password';
ALTER ROLE allocation_key_svc          WITH LOGIN PASSWORD :'allocation_key_password';
ALTER ROLE simulation_key_svc          WITH LOGIN PASSWORD :'simulation_key_password';
ALTER ROLE news_board_svc              WITH LOGIN PASSWORD :'news_board_password';
ALTER ROLE billing_svc                 WITH LOGIN PASSWORD :'billing_password';
ALTER ROLE administrative_document_svc WITH LOGIN PASSWORD :'administrative_document_password';
ALTER ROLE notification_dispatch_svc   WITH LOGIN PASSWORD :'notification_dispatch_password';
