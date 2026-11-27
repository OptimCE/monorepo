# `postgres/` — the unified database instance

One Postgres container (compose service `postgres`, host port **8080**) holding
**eight logical databases**, with **one login role per database**.

| database | owner role | owning service |
|---|---|---|
| `crm_db` | `crm_svc` | crm-backend |
| `allocation_key_local` | `allocation_key_svc` | allocation-key-generation |
| `simulation_key_local` | `simulation_key_svc` | simulation-key |
| `news_board_local` | `news_board_svc` | news-board |
| `billing_local` | `billing_svc` | billing |
| `administrative_document_local` | `administrative_document_svc` | administrative-document |
| `live_data_local` | `live_data_svc` | live-data |
| `signature_local` | `signature_svc` | signature |

Plus `notification_dispatch_svc`, which owns **no** database — it only works the
`outbound_message` queue inside `crm_db`.

**`keycloak` is not here.** It stays on its own instance (compose service
`keycloak-db`, host port 8081): Keycloak manages its own schema and runs its own
migrations at boot, and that is the one blast radius we are not willing to merge
into the application's. A consequence worth knowing: the roles above cannot even
resolve a network route to it, which is a stronger guarantee than any `REVOKE`.

## Why many databases, not one database with many schemas

Every service in the platform documents *"cross-DB references are plain columns,
never foreign keys"*. Separate databases are what enforce that **by physics**.
Merge into one database with per-service schemas and someone eventually adds a
real FK across a service boundary, and the separation rots silently with nothing
to catch it. Consolidating the *instances* keeps the boundary and still gives
back six postmasters' worth of memory and five host ports.

## How provisioning works

`docker-entrypoint-initdb.d` is **deliberately empty**. It runs only when the
data directory is empty and only against `POSTGRES_DB`, so it can neither
converge a rotated password nor reach a second database. Everything is done by
the `postgres-init` sidecar (`provision/provision.sh`), which runs on **every**
`up` and converges:

| step | file | re-runs? |
|---|---|---|
| 1. roles + passwords | `00-roles.sql` | yes — always re-asserts, so rotation works |
| 2. databases + `REVOKE CONNECT … FROM PUBLIC` | `10-databases.sql` | yes — `\gexec` yields no rows once they exist |
| 3. schema ownership | `20-schema-owner.sql` | yes, no-op |
| 4. schemas, applied **as the owner** | `21-set-role.sql` + the mounted file | **no — guarded**, see below |
| 5. seeds | same prelude + `/seeds/<db>/*.sql` | yes — idempotent by construction |
| 6. CRM grants | `30-crm-grants.sql` | yes — this is what converges after a migration adds a table |

No service's `schema.sql` is forked or edited. Each is bind-mounted under
`/schemas/<database>.sql`, so the sidecar never knows a repo path — which is what
lets production run the same script against a different source with no edit.

### The schema guard

A schema is applied only when its database has no relation in `public`.

**The decisive reason is `crm_db`.** `crm-backend/tests/sql/init.sql` opens with
`DROP SCHEMA IF EXISTS public CASCADE`, so replaying it would silently delete
your local data — and without that drop it would fail anyway, on the bare
`CREATE INDEX` and unguarded `CREATE TRIGGER` statements it also carries.

The seven annexe `schema.sql` files are, by contrast, **fully idempotent**:
`CREATE TABLE`/`CREATE INDEX IF NOT EXISTS` throughout, every `CREATE TRIGGER`
preceded by `DROP TRIGGER IF EXISTS` or written `CREATE OR REPLACE TRIGGER`.
They could be replayed safely. They are
guarded anyway because replay buys nothing — `CREATE TABLE IF NOT EXISTS` never
adds a **column**, so re-applying a schema is not a migration mechanism — and one
rule for all eight databases beats two.

A **half**-applied schema reads as non-empty and is skipped. That is correct: the
run that half-applied it exited non-zero, so nothing depending on it ever
started. Recovery is `./docker-stack.sh stop` then `start`, which gives the
container a fresh empty volume.

### If provisioning fails

Every `psql` runs `ON_ERROR_STOP=1` and the script runs `set -eu`, so the
container exits non-zero and every service with
`depends_on: postgres-init: service_completed_successfully` refuses to start.
There is deliberately **no** state in which the stack comes up with half its
grants — a missing CRM grant produces no application error at all (see below), so
a partial provision would be invisible.

```bash
docker compose -f docker-compose.dev.yml --env-file .env.dev logs postgres-init
```

## Verifying

```bash
./docker-stack.sh verify
```

Runs both scripts in `verify/`. Run it **twice** — once after a first init, once
after a `restart` — because only the restart case exercises convergence.

- **`isolation.sh`** — the must-fail / must-succeed matrix. No role can open
  another service's database; no role can write anything in `crm_db` it was not
  explicitly granted.
- **`positive-writes.sh`** — the one that matters most. The annexes' audit and
  notification writes run in a SAVEPOINT under a blanket `except Exception`, so a
  **missing grant does not raise**: the business transaction commits, the API
  returns 200, and the audit trail and every email vanish with only a log line.
  Never accept "we saw no 500s" as evidence — this script asserts the writes
  actually land, per role, inside `BEGIN … ROLLBACK` so no data is touched.

## Common operations

**Rotate a password.** Edit the value in `.env.dev`, then
`./docker-stack.sh restart` — **not** `start`. `provision.sh` re-asserts the
password on every run, but a *running* application container keeps the
environment it was created with, so it needs recreating too.

**Open a psql shell.** One port reaches all eight databases:

```bash
docker compose -f docker-compose.dev.yml --env-file .env.dev exec postgres psql -U postgres -d billing_local
```

**Reset everything.** There is no volume, by design — dev databases are
ephemeral. `./docker-stack.sh stop` then `start` re-creates and re-seeds them.

**Add a ninth database.** Four edits, all mechanical: a role in
`00-roles.sql`, a row and a `GRANT CONNECT` in `10-databases.sql`, a line in
`provision.sh`'s `DATABASES` registry, and a `/schemas/<db>.sql` mount in
`docker-compose.dev.yml`. If it also writes to `crm_db`, add it to the read block
in `30-crm-grants.sql` plus one narrow write grant per table — **and its sequence
if the primary key is `SERIAL`/`BIGSERIAL`**.

## The trap to remember

> **A CRM table added by a future crm-backend migration arrives readable but not
> writable.** `ALTER DEFAULT PRIVILEGES` in `30-crm-grants.sql` covers `SELECT`
> and nothing else, by design — writes are meant to be a deliberate line in that
> file. So when a migration adds a table an annexe must write, add the grant (and
> the sequence) in the same change. The grants re-run on every `up`, so it is a
> one-line edit and no wipe.
