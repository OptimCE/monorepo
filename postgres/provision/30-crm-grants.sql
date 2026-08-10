-- ===========================================================================
-- The CRM grant matrix. Connected to crm_db, run on EVERY start.
--
-- This is the file that turns the "read-only CRM port" every annexe documents
-- into something the database enforces, rather than something the code
-- promises. Before consolidation all six services reached crm_db as the
-- superuser.
--
-- Adding a CRM table an annexe must WRITE means adding two lines below: the
-- table, and — if its primary key is SERIAL/BIGSERIAL — its sequence. The READ
-- side needs nothing; ALTER DEFAULT PRIVILEGES covers it.
-- ===========================================================================
\set ON_ERROR_STOP on

-- MUST run with current_user = crm_svc, for two separate reasons:
--
--   * ALTER DEFAULT PRIVILEGES with no FOR ROLE applies only to objects created
--     by the CURRENT role. Every CRM table is created by crm_svc — the sidecar
--     applies the schema under SET ROLE crm_svc, and crm-backend connects as
--     crm_svc. Attach the defaults to `postgres` instead and the table
--     tomorrow's migration adds arrives ungranted.
--
--   * "Ungranted" is SILENT here. The annexes' audit and notification writes
--     run inside a SAVEPOINT under a blanket `except Exception` (see
--     billing/core/audit_log/service.py:73 and
--     billing/core/notifications/service.py:155), so a missing grant does not
--     raise: the business transaction commits, the API returns 200, and the
--     audit trail and every email vanish with only a log line. Verify with
--     postgres/verify/positive-writes.sh, never by watching for 500s.
SET ROLE crm_svc;

-- ---------------------------------------------------------------------------
-- Reads — blunt, deliberately.
--
-- The set of CRM tables an annexe SELECTs from changes with the code, and a
-- missing SELECT grant is a runtime failure in production. Blanket SELECT still
-- blocks every write, which is the actual risk this file exists to close.
--
-- USAGE ON SCHEMA public is load-bearing, not hygiene: crm_db's schema file
-- opens with DROP SCHEMA public CASCADE + CREATE SCHEMA public, and a
-- user-created schema carries NO privileges for PUBLIC (unlike the historic
-- initdb-created `public`). Without this line every annexe fails its first
-- query with "permission denied for schema public".
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA public TO
    allocation_key_svc,
    simulation_key_svc,
    news_board_svc,
    billing_svc,
    administrative_document_svc,
    notification_dispatch_svc;

-- Not retroactive is the whole reason this runs on EVERY start rather than once:
-- it covers tables that already existed when a role was added, and tables a
-- crm-backend migration added between two `up`s.
GRANT SELECT ON ALL TABLES IN SCHEMA public TO
    allocation_key_svc,
    simulation_key_svc,
    news_board_svc,
    billing_svc,
    administrative_document_svc,
    notification_dispatch_svc;

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO
    allocation_key_svc,
    simulation_key_svc,
    news_board_svc,
    billing_svc,
    administrative_document_svc,
    notification_dispatch_svc;

-- ---------------------------------------------------------------------------
-- Writes — narrow, one block per verified call site.
-- ---------------------------------------------------------------------------

-- audit_log — every annexe writes its own audit trail on the CRM session
-- (core/audit_log/service.py, identical in all five).
--
-- BIGSERIAL. INSERT on the table ALONE yields "permission denied for sequence
-- audit_log_id_seq" on the first insert — a failure that appears only at
-- runtime, never at deploy.
GRANT INSERT ON audit_log TO
    allocation_key_svc,
    simulation_key_svc,
    news_board_svc,
    billing_svc,
    administrative_document_svc;
GRANT USAGE ON SEQUENCE audit_log_id_seq TO
    allocation_key_svc,
    simulation_key_svc,
    news_board_svc,
    billing_svc,
    administrative_document_svc;

-- notification + outbound_message — the three services with a notification
-- port. simulation-key and allocation-key-generation have no core/notifications
-- package at all, so they are deliberately absent here.
--
-- Both BIGSERIAL, hence the sequences. The outbound insert is
-- `ON CONFLICT (dedupe_key) DO NOTHING` (core/notifications/repository.py:154),
-- which needs INSERT only. If that ever becomes DO UPDATE it will also need
-- UPDATE on outbound_message — and that would collapse the producer/dispatcher
-- boundary this file draws, so make it a deliberate decision, not a side effect.
GRANT INSERT ON notification, outbound_message TO
    news_board_svc,
    billing_svc,
    administrative_document_svc;
GRANT USAGE ON SEQUENCE notification_id_seq, outbound_message_id_seq TO
    news_board_svc,
    billing_svc,
    administrative_document_svc;

-- allocation-key-generation is the only annexe that writes CRM DOMAIN rows: one
-- ORM cascade inserts allocation_key -> iteration -> consumer in a single flush
-- (shared/crm_repository.py:11, api/generation/mappers.py:85). Granting only
-- allocation_key fails at flush time on the children.
--
-- All three are GENERATED ALWAYS AS IDENTITY. An identity column's nextval is
-- evaluated internally with the sequence ACL check skipped, so INSERT on the
-- table is sufficient and NO sequence grant is needed. That is precisely why the
-- BIGSERIAL tables above DO need one: a SERIAL default is a plain
-- nextval('...') expression and goes through the normal ACL check.
-- postgres/verify/positive-writes.sh proves this rather than assuming it.
GRANT INSERT ON allocation_key, iteration, consumer TO allocation_key_svc;

-- notification-dispatch owns the delivery loop and nothing else. It claims rows
-- with SELECT ... FOR UPDATE SKIP LOCKED (infra/outbound_repository.py:84) — a
-- row-lock clause requires the UPDATE privilege in its own right, so this one
-- grant covers both the claim and the CLAIMED/SENT/FAILED/SUPPRESSED
-- transitions and the stale-claim reaper. It never inserts a notification, never
-- inserts an outbound_message, and never writes an audit row.
GRANT UPDATE ON outbound_message  TO notification_dispatch_svc;

-- email_suppression's primary key is the address itself (VARCHAR(320) PRIMARY
-- KEY) — the one write in the matrix with no sequence.
GRANT INSERT ON email_suppression TO notification_dispatch_svc;

RESET ROLE;

-- ---------------------------------------------------------------------------
-- What is deliberately NOT granted, because that is the point:
--
--   * No DELETE on anything. No service issues one against crm_db.
--   * No UPDATE for any annexe. Only notification_dispatch_svc, only on
--     outbound_message.
--   * No INSERT on community, app_user, member, meter, document,
--     sharing_operation, ... for anyone but crm_svc.
--   * No CREATE on schema public for anyone but crm_svc — no annexe can run DDL
--     against the CRM. `Base.metadata.create_all` appears nowhere outside tests.
--
-- TEMPORARY stays granted to PUBLIC (the default). It is reachable only by a
-- role that already has CONNECT, and a temp table in a private temp schema is
-- not a boundary violation.
-- ---------------------------------------------------------------------------
