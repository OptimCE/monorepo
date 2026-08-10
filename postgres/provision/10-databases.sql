-- ===========================================================================
-- Six logical databases in one instance — NOT one database with six schemas.
--
-- Every service in the platform documents "cross-DB references are plain
-- columns, never foreign keys". Separate databases are what currently enforce
-- that by physics. Merge into one database with per-service schemas and someone
-- eventually adds a real FK across a service boundary, and the separation rots
-- silently. Only the host part of each DSN changes; nothing else moves.
--
-- `keycloak` is deliberately absent: it stays on its own instance
-- (compose service `keycloak-db`). See postgres/README.md.
-- ===========================================================================
\set ON_ERROR_STOP on

-- CREATE DATABASE cannot run inside DO or a transaction block. Generate the
-- statements and let \gexec execute each one standalone. Produces zero rows —
-- and therefore does nothing — on every run after the first.
SELECT format('CREATE DATABASE %I OWNER %I', d.name, d.owner)
  FROM (VALUES
    ('crm_db',                        'crm_svc'),
    ('allocation_key_local',          'allocation_key_svc'),
    ('simulation_key_local',          'simulation_key_svc'),
    ('news_board_local',              'news_board_svc'),
    ('billing_local',                 'billing_svc'),
    ('administrative_document_local', 'administrative_document_svc')
  ) AS d(name, owner)
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = d.name)
\gexec

-- PUBLIC holds CONNECT on every new database by default. THIS is the line that
-- actually delivers the isolation; without it the roles above are decoration
-- and any role could open any database.
REVOKE CONNECT ON DATABASE
    crm_db,
    allocation_key_local,
    simulation_key_local,
    news_board_local,
    billing_local,
    administrative_document_local
  FROM PUBLIC;

-- template1 too, so a seventh database created here later inherits "PUBLIC
-- cannot connect" instead of relying on someone remembering this file.
--
-- `postgres` (the maintenance database) is deliberately NOT revoked: pg_database
-- and pg_roles are readable from any database anyway so it buys nothing, and it
-- would break the default connection target of every GUI client.
REVOKE CONNECT ON DATABASE template1 FROM PUBLIC;

-- Own database: exactly one role each.
GRANT CONNECT ON DATABASE allocation_key_local          TO allocation_key_svc;
GRANT CONNECT ON DATABASE simulation_key_local          TO simulation_key_svc;
GRANT CONNECT ON DATABASE news_board_local              TO news_board_svc;
GRANT CONNECT ON DATABASE billing_local                 TO billing_svc;
GRANT CONNECT ON DATABASE administrative_document_local TO administrative_document_svc;

-- crm_db: its owner, plus every consumer of the read-only CRM port. What each
-- of them may actually DO once connected is 30-crm-grants.sql.
GRANT CONNECT ON DATABASE crm_db TO
    crm_svc,
    allocation_key_svc,
    simulation_key_svc,
    news_board_svc,
    billing_svc,
    administrative_document_svc,
    notification_dispatch_svc;
