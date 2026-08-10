#!/bin/sh
# ===========================================================================
# Converges the unified Postgres instance on EVERY `up`.
#
# This is the SINGLE provisioning path. /docker-entrypoint-initdb.d is
# deliberately left empty: those scripts run only on an empty data directory and
# only against POSTGRES_DB, so they can neither converge a rotated password nor
# reach a second database. Two mechanisms would also be two things that can
# diverge — see postgres/README.md.
#
# Production reuses this file UNCHANGED, in two passes. See
# docs/runbooks/database-consolidation.md:
#     pass 1, before pg_restore:  SKIP_SCHEMAS=1 SKIP_SEEDS=1 sh provision.sh
#     pass 2, after pg_restore:   sh provision.sh
#
# POSIX sh (busybox ash). Three details that are easy to get wrong and are load
# bearing here:
#   * `while ... done <<'EOF'`, never `echo ... | while`. A pipeline puts the
#     loop body in a subshell in ash; here-doc redirection does not.
#   * `if ...; then ...; fi`, never a bare `[ x ] && { ...; }` statement — a
#     false test makes the whole list return 1 and, as the complete command,
#     trips `set -e`.
#   * Multiple -f files in ONE psql invocation share one session, in order. That
#     is how 21-set-role.sql becomes a prelude without editing any schema file.
# ===========================================================================
set -eu

SQL_DIR=${SQL_DIR:-/postgres/provision}
SCHEMA_DIR=${SCHEMA_DIR:-/schemas}
SEED_DIR=${SEED_DIR:-/seeds}
SKIP_SCHEMAS=${SKIP_SCHEMAS:-0}
SKIP_SEEDS=${SKIP_SEEDS:-0}

# ON_ERROR_STOP=1 on every invocation. A failed statement aborts psql, `set -e`
# aborts this script, the container exits non-zero, and every service depending
# on it with `condition: service_completed_successfully` refuses to start.
#
# That is the point: there is no state in which the stack comes up with half its
# grants. A missing CRM grant produces NO application error (the annexes swallow
# it), so a partial provision would be invisible until an audit trail or an email
# was silently missing.
PSQL="psql --no-psqlrc --quiet -v ON_ERROR_STOP=1"

log() { printf '[postgres-init] %s\n' "$*"; }

# The registry. One line per database: <database>|<owner role>|<schema file>
#
# Adding a seventh service means one line here, one role in 00-roles.sql, one
# row in 10-databases.sql, and one mount in docker-compose.dev.yml.
DATABASES='crm_db|crm_svc|crm_db.sql
allocation_key_local|allocation_key_svc|allocation_key_local.sql
simulation_key_local|simulation_key_svc|simulation_key_local.sql
news_board_local|news_board_svc|news_board_local.sql
billing_local|billing_svc|billing_local.sql
administrative_document_local|administrative_document_svc|administrative_document_local.sql'

# --- 0. Wait ---------------------------------------------------------------
# `depends_on: service_healthy` already covers the compose path. This makes
# `docker compose run --rm --no-deps postgres-init` work too.
i=0
until pg_isready -q; do
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then
        log "postgres never became ready after 60s"
        exit 1
    fi
    sleep 1
done

# --- 1. Roles --------------------------------------------------------------
# Creates if absent, then ALWAYS re-asserts every password, so rotating a
# ${*_DB_PASSWORD} in .env.dev takes effect on the next `up` with no data wipe.
log "roles"
$PSQL -d postgres \
    -v crm_password="$CRM_DB_PASSWORD" \
    -v allocation_key_password="$ALLOCATION_KEY_DB_PASSWORD" \
    -v simulation_key_password="$SIMULATION_KEY_DB_PASSWORD" \
    -v news_board_password="$NEWS_BOARD_DB_PASSWORD" \
    -v billing_password="$BILLING_DB_PASSWORD" \
    -v administrative_document_password="$ADMINISTRATIVE_DOCUMENT_DB_PASSWORD" \
    -v notification_dispatch_password="$NOTIFICATION_DISPATCH_DB_PASSWORD" \
    -f "$SQL_DIR/00-roles.sql"

# --- 2. Databases + CONNECT ACLs -------------------------------------------
log "databases"
$PSQL -d postgres -f "$SQL_DIR/10-databases.sql"

# --- 3. Schema ownership, schemas, seeds -----------------------------------
while IFS='|' read -r db owner schema; do
    if [ -z "$db" ]; then continue; fi

    # Always: make the service role the DIRECT owner of schema public.
    $PSQL -d "$db" -v owner="$owner" -f "$SQL_DIR/20-schema-owner.sql"

    # ---- schema, guarded --------------------------------------------------
    #
    # A schema is applied ONLY when the database has no ordinary or partitioned
    # relation in `public`.
    #
    # The decisive reason is crm_db. crm-backend/tests/sql/init.sql:1 opens with
    # `DROP SCHEMA IF EXISTS public CASCADE`, so a second pass would silently
    # DELETE the developer's local data — and without that drop it would fail
    # anyway, on the 40 bare `CREATE INDEX` and 20 unguarded `CREATE TRIGGER`
    # statements it also carries.
    #
    # The five annexe schema.sql files are, by contrast, fully idempotent —
    # CREATE TABLE / CREATE INDEX IF NOT EXISTS throughout, and every CREATE
    # TRIGGER preceded by DROP TRIGGER IF EXISTS. They could be replayed safely.
    # They are guarded anyway, for two reasons: replay buys nothing (`CREATE
    # TABLE IF NOT EXISTS` never adds a COLUMN, so it is not a migration
    # mechanism — the trap IMPLEMENTATION_PLAN.md §5.6 calls out), and one rule
    # for all six databases is one rule to reason about instead of two.
    #
    # A HALF-applied schema reads as non-empty and is therefore skipped. That is
    # correct: the run that half-applied it exited non-zero, so no dependent
    # service ever started. Recovery is `docker-stack.sh stop` + `start`, which
    # gives the container a fresh empty volume.
    if [ "$SKIP_SCHEMAS" = "1" ]; then
        log "$db: schema skipped (SKIP_SCHEMAS=1)"
    elif [ ! -f "$SCHEMA_DIR/$schema" ]; then
        log "$db: no $SCHEMA_DIR/$schema mounted — schema skipped"
    else
        empty=$($PSQL -d "$db" -tAc "SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r','p'))")
        if [ "$empty" = "t" ]; then
            log "$db: applying $schema as $owner"
            $PSQL -d "$db" -v owner="$owner" \
                -f "$SQL_DIR/21-set-role.sql" \
                -f "$SCHEMA_DIR/$schema"
        else
            log "$db: already populated — schema not re-applied"
        fi
    fi

    # ---- seeds, unconditional ---------------------------------------------
    #
    # Unlike the schemas. These are region REFERENCE data (CWaPE deadline rules
    # and the document-template catalogue), not developer rows, and every file
    # declares itself idempotent — 0001/0002 rely on NULLS NOT DISTINCT unique
    # indexes, 0003 is UPDATE + INSERT and must run after 0002, which filename
    # order guarantees. Re-running on every `up` is what lets newly registered
    # reference data land without a wipe. Each file is BEGIN/COMMIT wrapped, so
    # ON_ERROR_STOP rolls a failure back whole rather than half-applying it.
    if [ "$SKIP_SEEDS" != "1" ] && [ -d "$SEED_DIR/$db" ]; then
        for seed in "$SEED_DIR/$db"/*.sql; do
            if [ ! -e "$seed" ]; then continue; fi
            log "$db: seed $(basename "$seed")"
            $PSQL -d "$db" -v owner="$owner" \
                -f "$SQL_DIR/21-set-role.sql" \
                -f "$seed"
        done
    fi
done <<EOF
$DATABASES
EOF

# --- 4. Grants -------------------------------------------------------------
# Unconditional, every run. ALTER DEFAULT PRIVILEGES is not retroactive, so this
# is what converges after a crm-backend migration adds a table, and after a role
# is added to the matrix.
log "crm grants"
$PSQL -d crm_db -f "$SQL_DIR/30-crm-grants.sql"

log "done"
exit 0
