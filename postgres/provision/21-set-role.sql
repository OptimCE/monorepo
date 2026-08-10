-- ===========================================================================
-- Prelude. psql applies multiple -f files in ONE session, in order, so this
-- runs a schema or seed file as its owner without editing that file:
--
--     psql -d billing_local -v owner=billing_svc \
--          -f 21-set-role.sql -f /schemas/billing_local.sql
--
-- Applying a schema as `postgres` instead would leave every table owned by the
-- superuser, so the service role could never ALTER its own schema later — the
-- trap called out in IMPLEMENTATION_PLAN.md §5.6.
--
-- SET ROLE is session-scoped and survives a file's internal BEGIN/COMMIT, which
-- is what makes it work for the administrative-document seeds.
-- ===========================================================================
\set ON_ERROR_STOP on

SET ROLE :"owner";
