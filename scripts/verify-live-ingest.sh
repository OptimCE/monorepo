#!/usr/bin/env bash
# ===========================================================================
# live-data: the end-to-end checks that need a real broker.
#
# These deliberately do NOT live in the submodule's pytest suite (D-7). GitHub
# Actions creates `services:` containers BEFORE `actions/checkout` runs, so a
# repo-tracked mosquitto.conf can never be their bind-mount source - and this
# broker needs one, because `allow_anonymous false` plus the dynamic-security
# plugin is the whole point. Not one of the seven tests/docker-compose.test.yml
# files in this monorepo - live-data's own included - mounts anything.
#
# The house already draws this line for NATS: the sibling services'
# tests/test_nats_resilience.py says outright that the real behaviour "can only
# be verified end-to-end with a real broker" and unit-tests only the surface.
# live-data does the same, and this script is the other half.
#
# Style follows postgres/verify/*.sh: `set -u` and NOT `-e`, a `run` helper that
# never aborts so every assertion is attempted, lettered sections that open with
# their must-outcome, counters, and a footer naming the CONSEQUENCE rather than
# the failure.
#
# Unlike those two it runs on the HOST, not inside a container: it needs curl
# against three different ports (the service, the gateway, and crm-backend on
# 127.0.0.1:8089) and `docker compose` itself.
#
# 122 assertions: a precondition (0) and sections A-N.
#   0  Test Community is SUBSCRIBED to live-data (crm-backend, as an ADMIN)
#   A  schema, partitions          B  device creation, EAN validation
#   C  enrolment, forged headers   D  token replay, broker client count
#   E  nominal ingest              F  idempotent backlog
#   G  rejection scopes            H  revocation
#   I  the gateway surface         J  rollups
#   K  the read API                L  forecast seam, ops surface
#   M  deactivation stops ingest and keeps the devices; reactivation resumes
#   N  sharing operations: operation rollups, the shared estimate, member scoping
#
#     ./scripts/verify-live-ingest.sh
#
# Requires the dev stack up (./docker-stack.sh start). It is re-runnable: it
# revokes what it created, and a revoked device frees its EAN again because
# uq_device_community_ean_live is a PARTIAL index. Section A purges a device
# left behind by a run that died early.
#
# It also leaves Test Community SUBSCRIBED to live-data. Step 0 subscribes it (a
# 409 ALREADY_SUBSCRIBED on a re-run is fine), section M unsubscribes and
# re-subscribes it, and an interrupted M re-subscribes on the way out. Section M
# waits the worker's SUBSCRIPTION_CACHE_TTL_SECONDS + 3 s twice.
# docker-compose.dev.yml sets it to 5; without that override it is 60 and the
# section still passes, two minutes slower.
#
# Two runs inside the same minute may trip the public leg's own rate limit
# (6r/m, burst 5) and fail section D with a 503. That is the limit working.
# ===========================================================================

set -u

# Not optional under Git Bash: without it Docker Desktop rewrites every
# container-absolute path. MSYS2_ARG_CONV_EXCL='*' is deliberately NOT set - it
# also stops the mingw curl understanding /dev/null, which is why nothing below
# redirects a response body there.
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/.." || exit 2

COMPOSE_FILE=docker-compose.dev.yml
ENV_FILE=.env.dev
DC="docker compose -f $COMPOSE_FILE --env-file $ENV_FILE"

# The BACKEND. Driving the admin surface through the gateway would need a real
# Keycloak JWT; forging the headers KrakenD injects is both simpler and exactly
# what KrakenD does. The gateway leg gets its own section.
API=http://localhost:8008
# The GATEWAY, through nginx. Note the /api - localhost:8087/live/... falls
# through to the Angular SPA and answers 200 with index.html, which is how plan
# section 14's original security probe was a guaranteed false pass.
GW=http://localhost:8087/api

# The dev fixture: community 1 "Test Community", seeded by docker-stack.sh.
ORG=2c8a0ea5-d597-49d6-ae12-4dceb9e9a018
COMMUNITY=1
# Must exist in crm.meter_data with status=1 and a current validity window, and
# must not already belong to a live (non-revoked) device.
EAN=${LIVE_VERIFY_EAN:-541448200000000003}
USER_ID=00000000-0000-4000-8000-000000000001
ORGS="[orgId:${ORG} orgPath:/Test Community roles:[MANAGER]]"

# crm-backend, DIRECT - the same shortcut as API, and loopback-only in compose
# because it authenticates nothing. (Un)subscribe is roleChecker(Role.ADMIN).
CRM=http://127.0.0.1:8089
ADMIN_ORGS="[orgId:${ORG} orgPath:/Test Community roles:[ADMIN]]"
FEATURE=live-data
# The worker's subscription-cache TTL, read from the RUNNING worker in M. This
# NAME is the script's one contract with live-data/core/config.py.
SUB_REFRESH_SETTING=SUBSCRIPTION_CACHE_TTL_SECONDS
NL=$'\n'

PASSED=0
FAILED=0

# The current section's simulator transcripts, replayed under its first FAIL.
# The callers still send sim's stdout to /dev/null - this is a copy - because
# which line matters is unknowable until an assertion fails, and by then the
# `run --rm` container is gone. 2026-10-04: nine failures across E-H, the
# simulator had never reached the broker, and nothing on record said why.
SIM_LOG=$(mktemp)
SIM_SHOWN=0
trap 'rm -f "$SIM_LOG"' EXIT

run() {  # run <expected> <actual> <label>
    if [ "$1" = "$2" ]; then
        PASSED=$((PASSED + 1))
        printf '  ok   (%s)  %s\n' "$2" "$3"
    else
        FAILED=$((FAILED + 1))
        printf '  FAIL expected %s, got %s - %s\n' "$1" "$2" "$3"
        if [ "$SIM_SHOWN" = 0 ] && [ -s "$SIM_LOG" ]; then
            SIM_SHOWN=1
            note "the simulator, in this section:"
            tr -d '\r' <"$SIM_LOG" | sed 's/^/       | /'
        fi
    fi
}

note() { printf '       %s\n' "$1"; }

# The blank line before a section header, and a fresh simulator transcript, so
# a FAIL replays only the traffic of its own section.
next_section() { echo; : >"$SIM_LOG"; SIM_SHOWN=0; }

# ---- plumbing --------------------------------------------------------------

api() {  # api <method> <path> [body]  -> the response body
    if [ -n "${3:-}" ]; then
        curl -sS -X "$1" "${API}$2" \
            -H "X-User-Id: ${USER_ID}" -H "X-Community-Id: ${ORG}" \
            -H "X-User-Orgs: ${ORGS}" \
            -H 'Content-Type: application/json' -d "$3"
    else
        curl -sS -X "$1" "${API}$2" \
            -H "X-User-Id: ${USER_ID}" -H "X-Community-Id: ${ORG}" \
            -H "X-User-Orgs: ${ORGS}"
    fi
}

# `-o /dev/null` is NOT usable here: MSYS_NO_PATHCONV stops the mingw curl
# translating the path, so it tries to create the file and exits 23. Capture the
# body and read the status off the last line instead.
code() { curl -sS -w '\n%{http_code}' "$@" 2>/dev/null | tail -n 1 | tr -d '\r'; }

# `exec`, not `run --rm`: the API container is already up, and this is ~0.6s
# against ~3.7s. Only ever used to READ json.
jget() { $DC exec -T live-data python -c "
import json, sys
d = json.load(sys.stdin)
for p in '$1'.split('.'):
    d = d[p]
print(d)
" 2>/dev/null | tr -d '\r'; }

psql_live() {
    $DC exec -T -e PGPASSWORD="$LIVE_DB_PW" postgres \
        psql -U live_data_svc -d live_data_local -At -c "$1" 2>/dev/null | tr -d '\r'
}
psql_crm() {
    $DC exec -T -e PGPASSWORD="$LIVE_DB_PW" postgres \
        psql -U live_data_svc -d crm_db -At -c "$1" 2>/dev/null | tr -d '\r'
}

# The output still goes to stdout, because section M greps it; a copy goes to
# $SIM_LOG for the replay.
sim() {
    local out rc
    out=$($DC run --rm --no-deps live-data python scripts/simulate_device.py "$@" 2>&1)
    rc=$?
    printf '$ simulate_device.py %s(exit %s)\n%s\n' "$(sim_args "$@")" "$rc" "$out" >>"$SIM_LOG"
    printf '%s\n' "$out"
    return "$rc"
}

# sim's arguments for the transcript, the MQTT password masked: the replay lands
# in a terminal or a CI log. The simulator itself never prints it.
sim_args() {
    local a prev=''
    for a in "$@"; do
        [ "$prev" = --password ] && a='***'
        printf '%s ' "$a"
        prev=$a
    done
}

# mosquitto_ctrl always prints two unencrypted-connection warnings and a blank
# line to stdout before the payload.
dynsec_clients() {
    $DC run --rm --no-deps --entrypoint sh mosquitto-roles -c \
        'mosquitto_ctrl -h mosquitto -p 1883 -u $MOSQUITTO_DYNSEC_USER -P $MOSQUITTO_DYNSEC_PASSWORD dynsec listClients' \
        2>/dev/null | grep -cvE '^(Warning:|This means|[[:space:]]*$)'
}

# Every log grep below is filtered by this run's own device UUID. `compose logs`
# has no cursor and accumulates across runs, so an unfiltered `grep -c` would
# answer 1 today and 2 tomorrow.
mlog() { $DC logs mosquitto --since 15m 2>&1 | grep -c "$1"; }

# POST /annexes-services/live-data/<action> as an ADMIN of Test Community - the
# endpoint the Annex services page calls. Prints "<status> <error_code>": `200 0`,
# `409 31003` ALREADY_SUBSCRIBED, `403 31004` NOT_SUBSCRIBED, `404 31002` when
# the image's catalog has no live-data entry, or `000 ` when nothing answered.
crm_annex() {  # crm_annex subscribe|unsubscribe
    CRM_OUT=$(curl -sS -w '\n%{http_code}' -X POST "${CRM}/annexes-services/${FEATURE}/$1" \
        -H "X-User-Id: ${USER_ID}" -H "X-Community-Id: ${ORG}" \
        -H "X-User-Orgs: ${ADMIN_ORGS}" 2>/dev/null | tr -d '\r')
    printf '%s %s\n' "${CRM_OUT##*"$NL"}" "$(printf '%s' "${CRM_OUT%"$NL"*}" | jget error_code)"
}

# 't', 'f', or '' when there is no row at all.
sub_active() {
    psql_crm "SELECT is_active FROM community_subscription WHERE id_community = ${COMMUNITY} AND feature = '${FEATURE}';"
}

# The public leg straight to the backend. Body, then the status on the last line.
enrol_direct() {  # enrol_direct <token>
    curl -sS -w '\n%{http_code}' -X POST "${API}/enroll" -H 'Content-Type: application/json' \
        -d "{\"token\":\"$1\",\"connector\":{\"name\":\"verify-deactivation\",\"version\":\"0\"}}" \
        2>/dev/null | tr -d '\r'
}

# Test Community's settings row as "<count> <updated_at>": "0 -" when it never
# saved them. updated_at is in it so that a GET which UPSERTs an existing row is
# caught as well as one which inserts a missing row.
settings_row() {
    psql_live "SELECT count(*) || ' ' || coalesce(max(updated_at)::text, '-') FROM community_live_settings WHERE id_community = ${COMMUNITY};"
}

# Section M's device only - never the community, which E-G already filled.
m_rows() {
    psql_live "SELECT count(*) FROM measurement m JOIN device d ON d.id = m.id_device WHERE d.public_id = '${M_DEVICE}';"
}

LIVE_DB_PW=$(grep '^LIVE_DATA_DB_PASSWORD=' "$ENV_FILE" | cut -d= -f2- | tr -d '\r')
if [ -z "$LIVE_DB_PW" ]; then
    echo "LIVE_DATA_DB_PASSWORD is not in $ENV_FILE - nothing below could run." >&2
    exit 2
fi

echo
echo "============================================================"
echo " live-data end-to-end   (the dev stack must be up)"
echo "============================================================"

# ---------------------------------------------------------------------------
next_section
echo "0. Precondition: Test Community is SUBSCRIBED to live-data - through the"
echo "   crm-backend endpoint the annexes page calls, not an INSERT."
note "every live-data route sits behind require_feature and no seed creates a"
note "community_subscription row: without this A cannot purge, B is a 403, and"
note "the run ends there. The real endpoint because activation IS under test,"
note "and because it writes the audit row an INSERT would skip."
SUB=$(crm_annex subscribe)
case "$SUB" in
    "200 "*)     note "subscribed now (there was no row, or an inactive one)" ;;
    "409 31003") note "already subscribed - ALREADY_SUBSCRIBED is the re-run case" ;;
    "000 "*)
        echo "crm-backend is not answering on ${CRM} - is the dev stack up?" >&2
        exit 2 ;;
    *)
        note "crm-backend answered: ${SUB}"
        note "a 404 31002 FEATURE_NOT_FOUND means crm-backend does not serve live-data."
        note "Two causes. (1) live-data ships \"defaultEnabled\": false, so the"
        note "container needs ANNEX_CATALOG_ENABLE=live-data (.env.dev); check with"
        note "  ${DC} exec crm-backend printenv ANNEX_CATALOG_ENABLE"
        note "and recreate after editing: ./docker-stack.sh restart -s crm-backend"
        note "(2) a STALE image: the catalog, config/annexes-services.json, is baked"
        note "in at build time. Rebuild it: docker compose ... up -d --build crm-backend"
        note "The boot log line annexes_services:catalog_loaded lists what it serves." ;;
esac
SUB_STATE=$(sub_active)
run t "$SUB_STATE" "community_subscription says live-data is ACTIVE for community ${COMMUNITY}"
if [ "$SUB_STATE" != t ]; then
    echo "  (every route below would answer 403 NOT_SUBSCRIBED - nothing after this could pass)"
    exit 1
fi

# ---------------------------------------------------------------------------
next_section
echo "A. The service is up, and its SCHEMA is the one this build expects."
note "readiness reads schema_version rather than SELECT 1: postgres/provision"
note "creates live_data_local BEFORE any schema is applied, so SELECT 1 goes"
note "green over an empty database and the container reports healthy."
run 200 "$(code ${API}/health/readiness)" "GET /health/readiness"
# The APPLIED version, not the row count. Every migration adds a row, so a
# count assertion goes stale on the next one - and it was asserting the wrong
# property anyway: what matters is that the database is at the version this
# build expects, which is exactly what /health/readiness compares.
EXPECTED_SCHEMA=$($DC exec -T live-data python -c "from shared.const import LOCAL_SCHEMA_VERSION; print(LOCAL_SCHEMA_VERSION)" 2>/dev/null | tr -d '\r')
run "$EXPECTED_SCHEMA" "$(psql_live 'SELECT max(version) FROM schema_version;')" \
    "the database is at the schema version this build expects"
run 0 "$(psql_live 'SELECT count(*) FROM measurement_default;')" "measurement_default is EMPTY"
note "the three lines above are CONSEQUENCE then CAUSE, not three of the same"
note "thing: readiness aggregates all three of its checks into one 503, and"
note "these two SQL counts say which one tripped. Seeding a single row into the"
note "default partition turns the first line red as well - that is how the pair"
note "was proven able to fail rather than merely asserted."
note "a non-empty DEFAULT means the create-ahead job has stopped. Nothing fails"
note "at write time when it does: rows land in the default, queries keep"
note "working, and the bill arrives at 00:00 UTC on the first of some later"
note "month when ATTACH PARTITION refuses a range the default already holds."

# Purge a device an earlier run left live, so this one is not a 409 in B.
STALE=$(api GET /devices | $DC exec -T live-data python -c "
import json, sys
for d in json.load(sys.stdin)['data']:
    if d['ean'] == '${EAN}' and d['status'] != 3:
        print(d['device_id'])
        break
" 2>/dev/null | tr -d '\r')
if [ -n "$STALE" ]; then
    note "purging ${STALE}, left live by an earlier run"
    api POST "/devices/${STALE}/revoke" >/dev/null
fi

# ---------------------------------------------------------------------------
next_section
echo "B. A device is created through the API, and its EAN is VALIDATED."
note "device.ean is a plain column in a different database and can never be a"
note "foreign key, so this check is the only thing that will ever look at it."
CREATED=$(api POST /devices "{\"name\":\"verify-run\",\"ean\":\"${EAN}\",\"type\":1,\"pure_injection\":true}")
DEVICE_ID=$(printf '%s' "$CREATED" | jget data.device_id)
CAPACITY=$(printf '%s' "$CREATED" | jget data.capacity_kva)
run 1 "$([ -n "$DEVICE_ID" ] && echo 1 || echo 0)" "POST /devices returned a device_id"
if [ -z "$DEVICE_ID" ]; then
    echo "  (no device - everything after this would be noise)"
    printf '%s\n' "$CREATED" | head -c 400
    echo
    exit 1
fi
note "device ${DEVICE_ID}"
run 1 "$([ -n "$CAPACITY" ] && [ "$CAPACITY" != None ] && echo 1 || echo 0)" \
    "capacity_kva was snapshotted from the CRM (${CAPACITY})"
note "kVA - the AC INJECTION ceiling - never kWc. A 5 kWc array behind a 3 kVA"
note "inverter cannot export above 3, and over_device_ceiling uses this number."
run 422 "$(code -X POST ${API}/devices \
    -H "X-User-Id: ${USER_ID}" -H "X-Community-Id: ${ORG}" -H "X-User-Orgs: ${ORGS}" \
    -H 'Content-Type: application/json' \
    -d '{"name":"bad-ean","ean":"000000000000000000","type":1,"pure_injection":true}')" \
    "an EAN with no active meter is refused"
run 409 "$(code -X POST ${API}/devices \
    -H "X-User-Id: ${USER_ID}" -H "X-Community-Id: ${ORG}" -H "X-User-Orgs: ${ORGS}" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"dup\",\"ean\":\"${EAN}\",\"type\":1,\"pure_injection\":true}")" \
    "a second LIVE device on the same EAN is refused"

# ---------------------------------------------------------------------------
next_section
echo "C. Enrolment over the PUBLIC leg returns credentials, and a forged"
echo "   gateway-trust header changes nothing about the result."
note "this is the platform's only unauthenticated endpoint. KrakenD's"
note "input_headers is global with no per-service override, so a client-supplied"
note "x-user-id IS forwarded to the backend; nginx's exact-match location is the"
note "only thing in the chain that blanks it."
CLIENTS_BEFORE=$(dynsec_clients)
TOKEN=$(api POST "/devices/${DEVICE_ID}/token" | jget data.token)
run 1 "$([ -n "$TOKEN" ] && echo 1 || echo 0)" "POST /devices/{id}/token returned a token"
ENROL=$(curl -sS -X POST "${GW}/live-public/enroll" -H 'Content-Type: application/json' \
    -H "X-User-Id: 11111111-1111-4111-8111-111111111111" \
    -H "X-Community-Id: 3fa85f64-5717-4562-b3fc-2c963f66afa6" \
    -H "X-User-Orgs: [orgId:3fa85f64-5717-4562-b3fc-2c963f66afa6 orgPath:/Forged roles:[MANAGER]]" \
    -d "{\"token\":\"${TOKEN}\",\"connector\":{\"name\":\"verify-forged\",\"version\":\"9.9\"}}")
MQ_USER=$(printf '%s' "$ENROL" | jget data.credentials.username)
MQ_PASS=$(printf '%s' "$ENROL" | jget data.credentials.password)
BROKER_HOST=$(printf '%s' "$ENROL" | jget data.broker.host)
run "$DEVICE_ID" "$MQ_USER" "the credential username IS the device id (protocol 5.2)"
run 1 "$([ -n "$MQ_PASS" ] && echo 1 || echo 0)" "a password was returned"
run 1 "$([ -n "$BROKER_HOST" ] && [ "$BROKER_HOST" != mosquitto ] && echo 1 || echo 0)" \
    "broker.host is the PUBLIC name (${BROKER_HOST}), not the one the API dials"
note "D-7: BROKER_PUBLIC_HOST and MQTT_HOST differ in every environment. This"
note "value goes into a device's NVS and is never asked for a second time."
run 2 "$(psql_live "SELECT status FROM device WHERE public_id='${DEVICE_ID}';")" \
    "the device is ACTIVE (2)"
run "$COMMUNITY" "$(psql_crm "SELECT id_community FROM audit_log WHERE action='live_data.device.enrolled' AND entity_id='${DEVICE_ID}' ORDER BY timestamp DESC LIMIT 1;")" \
    "the audit row is filed against the DEVICE's community, not the forged one"
note "_write_audit passes id_community explicitly because the ContextVar is"
note "unset on this leg. Left to the ContextVar the row would be filed against"
note "nothing at all, and this probe would pass for entirely the wrong reason."
run verify-forged "$(psql_live "SELECT connector_name FROM device WHERE public_id='${DEVICE_ID}';")" \
    "the connector name was recorded from the enrolment request"

# ---------------------------------------------------------------------------
next_section
echo "D. The SAME token again is refused with the SAME answer as an unknown"
echo "   one, and creates NO second broker client."
REPLAY=$(curl -sS -X POST "${GW}/live-public/enroll" -H 'Content-Type: application/json' \
    -d "{\"token\":\"${TOKEN}\",\"connector\":{\"name\":\"v\",\"version\":\"0\"}}")
UNKNOWN=$(curl -sS -X POST "${GW}/live-public/enroll" -H 'Content-Type: application/json' \
    -d '{"token":"0000-0000-0000-0000-0000-0000-00","connector":{"name":"v","version":"0"}}')
# Compared whole, reported short: printing two identical French error bodies
# on the ok line buries every other assertion in the section.
run identical "$([ "$UNKNOWN" = "$REPLAY" ] && echo identical || echo different)" "a consumed token and an unknown one give the IDENTICAL answer"
note "not merely 'both are 4xx'. A distinguishable answer turns this endpoint"
note "into a token oracle: an attacker learns that a guess was REAL, and the"
note "whole premise of a 128-bit token is that guesses cost nothing to make."
run 2411 "$(printf '%s' "$REPLAY" | jget error_code)" "and the code is the single opaque 2411"
run "$CLIENTS_BEFORE" "$(( $(dynsec_clients) - 1 ))" \
    "exactly ONE broker client exists for this run"
note "the count is the assertion that matters. A 4xx with a client created"
note "anyway would be the worst of both outcomes, and invisible from the API."

# ---------------------------------------------------------------------------
next_section
echo "E. Nominal ingest: a published measurement reaches the table."
psql_live "DELETE FROM measurement m USING device d WHERE d.id = m.id_device AND d.public_id = '${DEVICE_ID}';" >/dev/null
sim --username "$MQ_USER" --password "$MQ_PASS" --community "$COMMUNITY" \
    --profile pv-day --once >/dev/null
sleep 3
run 1 "$(psql_live "SELECT count(*) FROM measurement m JOIN device d ON d.id = m.id_device WHERE d.public_id = '${DEVICE_ID}';")" \
    "one measurement stored"
run 1 "$(psql_live "SELECT count(*) FROM device_last dl JOIN device d ON d.id = dl.id_device WHERE d.public_id = '${DEVICE_ID}' AND dl.online;")" \
    "device_last says online"
note "device_last keeps TWO clocks on purpose: ts is the measurement's own and"
note "status_at is when the broker received it. One clock cannot tell a stale"
note "backlog apart from a device that is live right now."

# ---------------------------------------------------------------------------
next_section
echo "F. Store-and-forward is IDEMPOTENT: 24 readings in one array, sent twice."
note "protocol 4.3 promises connector authors that re-sending OVERWRITES. That"
note "promise is why QoS 1 is sufficient, and why a connector unsure whether a"
note "message landed is supposed to send it again rather than guess."
psql_live "DELETE FROM measurement m USING device d WHERE d.id = m.id_device AND d.public_id = '${DEVICE_ID}';" >/dev/null
# ONE ANCHOR FOR BOTH RUNS. Without it the batch ends at the CURRENT
# quarter-hour, so a boundary falling between the two sends makes the second
# batch a DIFFERENT batch: 25 distinct timestamps where 24 were expected, and a
# red line that reads as a broken upsert. Seen on 2026-09-19, and the tell is
# that "rows == distinct ts" still passes - idempotence held perfectly, the two
# batches simply were not the same one.
BACKLOG_ANCHOR=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sim --username "$MQ_USER" --password "$MQ_PASS" --community "$COMMUNITY" \
    --profile backlog --hours 6 --anchor-ts "$BACKLOG_ANCHOR" >/dev/null
sim --username "$MQ_USER" --password "$MQ_PASS" --community "$COMMUNITY" \
    --profile backlog --hours 6 --anchor-ts "$BACKLOG_ANCHOR" >/dev/null
sleep 4
ROWS=$(psql_live "SELECT count(*) FROM measurement m JOIN device d ON d.id = m.id_device WHERE d.public_id = '${DEVICE_ID}';")
DISTINCT=$(psql_live "SELECT count(DISTINCT m.ts) FROM measurement m JOIN device d ON d.id = m.id_device WHERE d.public_id = '${DEVICE_ID}';")
run "$DISTINCT" "$ROWS" "rows == distinct ts"
run 24 "$ROWS" "and both are 24"

# ---------------------------------------------------------------------------
next_section
echo "G. Malformed traffic is REJECTED by scope, counted, and absent from the"
echo "   measurement table."
note "the split is the whole design: an envelope or identity fault discards the"
note "MESSAGE, a value or time fault discards one READING and the rest of the"
note "batch is still stored. A connector cannot learn either way - the flow is"
note "one-way and there is no command topic - so these rows are the only place"
note "a problem will ever surface."
psql_live "DELETE FROM ingest_dead_letter;" >/dev/null
sim --username "$MQ_USER" --password "$MQ_PASS" --community "$COMMUNITY" \
    --profile malformed >/dev/null
sleep 4
for reason in schema_invalid unknown_field duplicate_ts_in_batch community_mismatch; do
    run 1 "$(psql_live "SELECT count(*) FROM ingest_dead_letter WHERE reason = '${reason}';")" \
        "message-scoped: ${reason} was dead-lettered"
done
run 0 "$(psql_live "SELECT count(*) FROM ingest_dead_letter WHERE reason IN ('ts_in_future','ts_too_old','ts_not_aligned','negative_energy','over_device_ceiling','implausible_production');")" \
    "measurement-scoped reasons discarded NO message"
run 1 "$(psql_live "SELECT count(*) FROM device_last dl JOIN device d ON d.id = dl.id_device WHERE d.public_id = '${DEVICE_ID}' AND dl.last_reject_reason IS NOT NULL;")" \
    "but they DID land on device_last.last_reject_reason"
note "both halves, never either. Zero dead letters on its own is also exactly"
note "what a validator that had quietly stopped running looks like."
run 0 "$(psql_live "SELECT count(*) FROM measurement WHERE ts > now() + interval '5 minutes';")" \
    "nothing dated in the future was stored"
note "community_mismatch is load-bearing, not theatre: the device role's ACL is"
note "ce/+/%u/telemetry and the + accepts ANY community id. The broker cannot"
note "check this one, so the worker is the only place it is ever caught."

# ---------------------------------------------------------------------------
next_section
echo "H. Revoking cuts the LIVE connection AND refuses the next one. BOTH."
printf '$ simulate_device.py --profile pv-day --once --keep-alive (detached)\n' >>"$SIM_LOG"
KEEPALIVE=$($DC run -d --no-deps live-data python scripts/simulate_device.py \
    --username "$MQ_USER" --password "$MQ_PASS" --community "$COMMUNITY" \
    --profile pv-day --once --keep-alive 2>>"$SIM_LOG" | tr -d '\r')
sleep 8
api POST "/devices/${DEVICE_ID}/revoke" >/dev/null
sleep 4
# What it printed so far, for the replay: the container is removed below.
if [ -n "${KEEPALIVE:-}" ]; then
    docker logs "$KEEPALIVE" >>"$SIM_LOG" 2>&1
fi
run 1 "$(mlog "Client ${DEVICE_ID} .*administrative action")" \
    "the open connection was dropped by the broker"
run 1 "$(mlog "PUBLISH from live-data-admin .*r1.*ce/${COMMUNITY}/${DEVICE_ID}/status.*(0 bytes)")" \
    "the retained status was CLEARED by a zero-byte retained publish"
note "that clear needs the reaper role on the admin client. Phase 0 saw all"
note "three identities denied it - the bootstrap admin included - and a denied"
note "publish is still PUBACKed, so the failure is completely silent. Without"
note "it the last status replays to the worker on every reconnect, for ever."
RETRY=$($DC run --rm --no-deps --entrypoint sh mosquitto-roles -c \
    "mosquitto_pub -h mosquitto -p 1883 -u '${DEVICE_ID}' -P '${MQ_PASS}' -i '${DEVICE_ID}' -t 'ce/${COMMUNITY}/${DEVICE_ID}/telemetry' -m '{}' 2>&1" 2>/dev/null)
run 1 "$(printf '%s' "$RETRY" | grep -c 'not authorised')" "and the next connection is REFUSED"
run 3 "$(psql_live "SELECT status FROM device WHERE public_id='${DEVICE_ID}';")" \
    "the row is REVOKED (3)"
run "$CLIENTS_BEFORE" "$(dynsec_clients)" "the broker client is GONE"
if [ -n "${KEEPALIVE:-}" ]; then
    docker rm -f "$KEEPALIVE" >/dev/null 2>&1
fi

# ---------------------------------------------------------------------------
next_section
echo "I. The gateway surface. Every URL below goes through /api - read on."
run 401 "$(code ${GW}/live/devices)" "GET /api/live/devices is AUTHENTICATED"
run 400 "$(code -X POST ${GW}/live-public/enroll -H 'Content-Type: application/json' \
    -d '{"token":"0000-0000-0000-0000-0000-0000-00","connector":{"name":"v","version":"0"}}')" \
    "POST /api/live-public/enroll is PUBLIC and reaches the backend"
run 404 "$(code -X POST ${GW}/live-public/definitely-not-a-route)" \
    "the control: the router discriminates rather than passing everything"
run 401 "$(code ${GW}/communities/)" "the 191 pre-existing endpoints still answer"
note "localhost:8087/live/devices - WITHOUT the /api - returns 200 with"
note "index.html from the Angular SPA. That is why plan section 14's original"
note "security probe could never have failed."
run 5 "$($DC exec -T reverse-proxy sh -c \
    "awk '/location = .api.live-public.enroll/,/^    }/' /etc/nginx/conf.d/default.conf | grep -c 'proxy_set_header X-.* \"\";'" \
    2>/dev/null | tr -d '\r')" \
    "the RENDERED nginx config blanks all five trust headers"
run 1 "$($DC exec -T reverse-proxy sh -c \
    "grep -c 'limit_req_zone .binary_remote_addr zone=live_enroll' /etc/nginx/conf.d/default.conf" \
    2>/dev/null | tr -d '\r')" \
    "and the rate-limit zone survived envsubst with its variable intact"
# The broker's authorisation model has TWO sources of truth and only one of them
# runs: the `mosquitto-roles` block in docker-compose.dev.yml creates the roles,
# and live-data/shared/const.py + domain/topics.py describe them. Nothing in
# either repository can compare them - the submodule's CI never sees compose, and
# compose has no test - so they drift silently, and the drift that matters is the
# `%u` pattern D-1 pins Mosquitto 2.1.2 for.
ROLE_FACTS=$($DC exec -T live-data python -c "
from domain.topics import device_acl_pattern
from shared import const
print(device_acl_pattern('telemetry'))
print(device_acl_pattern('status'))
print(const.ROLE_DEVICE, const.ROLE_INGEST, const.ROLE_REAPER)
" 2>/dev/null | tr -d '\r')
# WITHOUT THIS LINE THE CHECK BELOW PASSES VACUOUSLY. An exec that fails - a
# container down, an import error - yields an empty ROLE_FACTS, both loops
# iterate zero times, DRIFT stays 0 and the assertion reports success about
# nothing. Five tokens is what a healthy read returns.
run 5 "$(echo $ROLE_FACTS | wc -w | tr -d ' ')" "the role facts were actually read from the service"

DRIFT=0
for pattern in $(echo "$ROLE_FACTS" | head -2); do
    grep -q "addRoleACL device .*'${pattern}'" docker-compose.dev.yml || DRIFT=1
done
for role in $(echo "$ROLE_FACTS" | tail -1); do
    grep -q "createRole ${role}" docker-compose.dev.yml || DRIFT=1
done
run 0 "$DRIFT" "the broker roles in compose match domain/topics.py and shared/const.py"
note "on Mosquitto 2.0.x, %u is a LITERAL: the broker starts, the plugin loads,"
note "enrolment succeeds, and the device can publish nowhere. Nothing errors."

run 0 "$(python scripts/verify-krakend-public-surface.py >/dev/null 2>&1; echo $?)"     "the GENERATED krakend.json publishes exactly one unauthenticated endpoint"
note "the third gate, and the only one that reads what the GATEWAY publishes."
note "live-data's own two guards reason about the service's OpenAPI; KrakenD's"
note "JWT validator is configured per SERVICE ENTRY, so a builder mistake ships"
note "an authenticated route with no validator and nothing here fails."

note "the template writes a section sign and a trailing sed restores the dollar."
note "envsubst runs with no SHELL-FORMAT, so a literal one renders EMPTY, nginx"
note "refuses to start, and the whole reverse proxy goes down at stack start."

# ---------------------------------------------------------------------------
next_section
echo "J. The rollups. The tick is run on demand rather than waited for."
note "15 minutes is too long for a merge gate, so this calls the SAME function"
note "the scheduler calls, in the scheduler container, against the same rows."

# Everything the device sent in sections E-G is still there: revoking does not
# delete what a device already published (protocol 8.6).
RAW_ROWS=$(psql_live "SELECT count(*) FROM measurement WHERE id_community = ${COMMUNITY};")
run 1 "$([ "$RAW_ROWS" -gt 0 ] && echo 1 || echo 0)" \
    "there are raw measurements to roll up ($RAW_ROWS)"

$DC exec -T live-data-scheduler python -c "
import asyncio, datetime
from worker.context import local_sessionmaker
from worker import rollups

async def main():
    sessions = local_sessionmaker()
    async with sessions() as session:
        await rollups.run_tick(session, now=datetime.datetime.now(datetime.UTC))
        await session.commit()

asyncio.run(main())
" >/dev/null 2>&1

run 0 "$(psql_live "SELECT count(*) FROM rollup_dirty WHERE id_community = ${COMMUNITY};")" \
    "the tick DRAINED rollup_dirty - claim and recompute commit together"
note "ingest marks every bucket dirty in the same statement as the measurement,"
note "unconditionally. A bucket written at 10:59:59 is inside the 48-hour window"
note "at write time and outside it when the tick fires at 11:00:02."

HOUR_ROWS=$(psql_live "SELECT count(*) FROM rollup_community_hour WHERE id_community = ${COMMUNITY};")
run 1 "$([ "$HOUR_ROWS" -gt 0 ] && echo 1 || echo 0)" \
    "community hours were computed ($HOUR_ROWS)"

# THE ACCEPTANCE PROPERTY, in SQL: every rolled-up hour equals the sum of the
# quarter-hours that produced it. The bucket expression is the `- 1 second` form,
# because `ts` is the END of its interval - `date_trunc('hour', ts)` here would
# disagree with the tick by exactly one hour and this assertion is what says so.
run 0 "$(psql_live "
  SELECT count(*) FROM (
    SELECT r.bucket, r.import_wh AS rolled, COALESCE(m.total, 0) AS raw_total
      FROM rollup_community_hour r
      LEFT JOIN (
        SELECT date_trunc('hour', (ts - INTERVAL '1 second') AT TIME ZONE 'UTC')
                 AT TIME ZONE 'UTC' AS bucket,
               SUM(import_wh) AS total
          FROM measurement WHERE id_community = ${COMMUNITY} GROUP BY 1
      ) m ON m.bucket = r.bucket
     WHERE r.id_community = ${COMMUNITY}
       AND abs(r.import_wh - COALESCE(m.total, 0)) > 0.001
  ) x;")" \
    "every rolled-up hour equals the sum of its quarter-hours"

run 0 "$(psql_live "SELECT count(*) FROM measurement_default;")" \
    "measurement_default is still empty after the tick"
run 0 "$(psql_live "SELECT count(*) FROM rollup_device_hour_default;")" \
    "and so is rollup_device_hour_default"
note "a probe naming only measurement would let the rollups freeze about four"
note "months in while ingestion went on looking perfectly healthy."

EXPECTED_SCHEMA=$($DC exec -T live-data python -c "from shared.const import LOCAL_SCHEMA_VERSION; print(LOCAL_SCHEMA_VERSION)" 2>/dev/null | tr -d '\r')
run "$EXPECTED_SCHEMA" "$(psql_live 'SELECT max(version) FROM schema_version;')" \
    "the scheduler container agrees with the database about the schema version"

# ---------------------------------------------------------------------------
next_section
echo "K. The read API. Through the gateway, which strips the service prefix."
run 200 "$(code -H "X-User-Id: ${USER_ID}" -H "X-Community-Id: ${ORG}" \
    -H "X-User-Orgs: ${ORGS}" ${API}/summary)" "GET /summary answers"
# `True`, not `true`: jget prints through Python, so the comparison is
# against the repr rather than against the JSON literal.
run True "$(api GET /summary | jget data.indicative)" \
    "and it is stamped indicative SERVER-side"
run neutral "$(api GET /summary | jget data.signal)" \
    "the signal is the only value deviation 6 permits"
note "with no consumption term, 'the sun is shining' is not 'now is a good time"
note "to run the washing machine' - and a green light meaning the first is read"
note "as the second. Literal['neutral'] makes the others unrepresentable."

run 0 "$(api GET /summary | $DC exec -T live-data python -c \
    "import json,sys; print(sum(1 for k in json.load(sys.stdin)['data'] if k.startswith('consumption')))" \
    2>/dev/null | tr -d '\r')" \
    "there is NO consumption key - not consumption: null"
note "null is what a chart library renders as zero, so a nulled term does not"
note "read as withheld, it reads as a claim nobody made. The absent[] list names"
note "it with a reason instead."

run 1 "$(api GET /summary | $DC exec -T live-data python -c \
    "import datetime,json,sys; b=json.load(sys.stdin)['data'].get('bucket'); print(1 if b is None or datetime.datetime.fromisoformat(b.replace('Z', '+00:00')) + datetime.timedelta(hours=1) <= datetime.datetime.now(datetime.UTC) else 0)" \
    2>/dev/null | tr -d '\r')" \
    "the production card reads a CLOSED hour, never the one in progress"
note "labelled 'last full hour', it used to serve the NEWEST bucket - the hour in"
note "progress for most of every hour, so the figure dropped at each turn of the"
note "hour and read as a fall in production."

run 200 "$(code -H "X-User-Id: ${USER_ID}" -H "X-Community-Id: ${ORG}" \
    -H "X-User-Orgs: ${ORGS}" "${API}/series?resolution=hour")" "GET /series answers"
run 422 "$(code -H "X-User-Id: ${USER_ID}" -H "X-Community-Id: ${ORG}" \
    -H "X-User-Orgs: ${ORGS}" "${API}/series?resolution=hour&from=2026-09-01T10:17:00Z")" \
    "an UNSNAPPED bound is refused, never snapped"
note "plan 9.3: free-form bounds are the differencing attack. An attacker who"
note "can move a boundary by a minute requests two windows and subtracts them."
note "Snapping silently answers BOTH - which is what makes them subtractable."
run 422 "$(code -H "X-User-Id: ${USER_ID}" -H "X-Community-Id: ${ORG}" \
    -H "X-User-Orgs: ${ORGS}" "${API}/series?resolution=fortnight")" \
    "and an unknown resolution is a 422, not a guess"
run 200 "$(code -H "X-User-Id: ${USER_ID}" -H "X-Community-Id: ${ORG}" \
    -H "X-User-Orgs: ${ORGS}" "${API}/series?resolution=hour&from=2026-09-01T10:00:00Z&to=2026-09-02T10:00:00Z")" \
    "the positive control: a SNAPPED bound is accepted"

# Against the row as it was BEFORE the GET, never against "no row". One save of
# the settings panel leaves a row for good, and an absolute zero then failed this
# section on every run with nothing broken (2026-10-04: k set to 3 from the UI).
# An unreadable row is a FAIL, never two empty strings agreeing.
SETTINGS_BEFORE=$(settings_row)
case "$SETTINGS_BEFORE" in
    "0 -")  SETTINGS_DEFAULT=True ;;
    [1-9]*) SETTINGS_DEFAULT=False ;;
    *)      SETTINGS_BEFORE="(unreadable)"; SETTINGS_DEFAULT="(unreadable)" ;;
esac
run "$SETTINGS_DEFAULT" "$(api GET /settings | jget data.is_default)" \
    "GET /settings reports is_default exactly when the community never saved them"
run "$SETTINGS_BEFORE" "$(settings_row)" "and it did NOT write the row"
note "a GET that writes breaks on a replica, audits a manager who merely opened"
note "a panel, and freezes today's default into a row - so a later platform"
note "change silently never reaches them."
if [ "$SETTINGS_DEFAULT" = False ]; then
    note "Test Community has SAVED its settings, so this run checked the saved path."
    note "The never-saved defaults are pinned by live-data's pytest suite instead:"
    note "test_read_api.py::TestSettings::test_get_returns_the_defaults_without_inserting"
fi

run 401 "$(code ${GW}/live/summary)" "GET /api/live/summary is AUTHENTICATED at the gateway"
run 401 "$(code ${GW}/live/ops/health)" "and so is /api/live/ops/health"

# ---------------------------------------------------------------------------
next_section
echo "L. The forecast seam, and the ops surface."
run no_method_for_production_chain "$(api GET /forecast | jget data.reason)" \
    "GET /forecast is EMPTY WITH A NAMED REASON"
run 0 "$(api GET /forecast | $DC exec -T live-data python -c \
    "import json,sys; print(len(json.load(sys.stdin)['data']['buckets']))" 2>/dev/null | tr -d '\r')" \
    "its buckets list is empty"
note "criterion 7: a bare [] or a 404 is a FAILURE. Once methods exist, either"
note "is indistinguishable from a broken job - and a 404 makes a frontend hide"
note "the panel, so the day the first method ships nothing appears."
run 0 "$(api GET /forecast/methods | $DC exec -T live-data python -c \
    "import json,sys; print(len(json.load(sys.stdin)['data']))" 2>/dev/null | tr -d '\r')" \
    "GET /forecast/methods is correctly an empty LIST"

run 200 "$(code -H "X-User-Id: ${USER_ID}" -H "X-Community-Id: ${ORG}" \
    -H "X-User-Orgs: ${ORGS}" ${API}/ops/health)" "GET /ops/health answers"
OPS_DEVICES=$(api GET /ops/health | jget data.n_devices)
run 1 "$([ "$OPS_DEVICES" -ge 1 ] && echo 1 || echo 0)" \
    "the fleet view lists the device even though it was REVOKED in section H"
note "a revoked device keeps its measurements, so it keeps needing an owner and"
note "a place on the maintenance page. Filtering it out here is how history"
note "silently loses its attribution."
run 1 "$(api GET /ops/health | $DC exec -T live-data python -c \
    "import json,sys; d=json.load(sys.stdin)['data']; print(1 if d['by_health'].get('revoked', 0) >= 1 else 0)" \
    2>/dev/null | tr -d '\r')" \
    "and that device reads REVOKED - listed, and never 'needing attention'"
note "classified from its last report alone, a revoked device read silent a day"
note "later and inflated the attention count for ever."
run 1 "$(api GET /ops/health | $DC exec -T live-data python -c \
    "import json,sys; d=json.load(sys.stdin)['data']; print(1 if d.get('rollup_age_minutes') is not None else 0)" \
    2>/dev/null | tr -d '\r')" \
    "and it reports how new the rolled-up DATA is"
run fresh "$(api GET /ops/health | jget data.rollup_freshness)" \
    "and the SCHEDULER's verdict is fresh, right after section J's tick"
note "every device can be healthy while the scheduler is not ticking, and"
note "nothing else on that page would say so. But the age of the newest data"
note "cannot say it either: a quiet fleet ages it while every tick runs. The"
note "verdict reads computed_at and the pending dirty marks instead."

# ---------------------------------------------------------------------------
next_section
echo "M. DEACTIVATION stops ingestion and keeps the devices; REACTIVATION"
echo "   resumes it with the same credentials and no re-enrolment."
note "an unsubscribed community's TELEMETRY is DISCARDED by the worker (its"
note "status is still processed), every live-data route is 403 NOT_SUBSCRIBED -"
note "revoke included, no carve-out - and the device, its broker client and its"
note "history survive. What is sent meanwhile is PUBACKed and then lost, not queued."

SUB_REFRESH=$($DC exec -T live-data-worker python -c \
    "from core.config import settings; print(int(settings.${SUB_REFRESH_SETTING}))" \
    2>/dev/null | tr -d '\r')
# WITHOUT THIS LINE A RENAMED SETTING MAKES EVERY WAIT BELOW A GUESS.
run 1 "$(case "$SUB_REFRESH" in ''|*[!0-9]*) echo 0 ;; *) echo 1 ;; esac)" \
    "the worker's ${SUB_REFRESH_SETTING} was read (${SUB_REFRESH:-nothing})"
case "$SUB_REFRESH" in ''|*[!0-9]*) SUB_REFRESH=60 ;; esac
SUB_WAIT=$((SUB_REFRESH + 3))
note "every flip below is followed by ${SUB_WAIT}s before anything is published:"
note "the worker's cache is lazy, so a message handled more than one TTL after"
note "a flip is guaranteed to be judged against the new state."

# H revoked the first device, which frees the EAN (a PARTIAL unique index).
M_CREATED=$(api POST /devices "{\"name\":\"verify-deactivation\",\"ean\":\"${EAN}\",\"type\":1,\"pure_injection\":true}")
M_DEVICE=$(printf '%s' "$M_CREATED" | jget data.device_id)
run 1 "$([ -n "$M_DEVICE" ] && echo 1 || echo 0)" "a second device was created on the freed EAN"

# DIRECT to the backend, not via nginx: C, D and I already prove the gateway,
# and two more calls there would spend the 6r/m zone for nothing.
M_TOKEN1=$(api POST "/devices/${M_DEVICE}/token" | jget data.token)
M_ENROL=$(enrol_direct "$M_TOKEN1")
M_USER=$(printf '%s' "${M_ENROL%"$NL"*}" | jget data.credentials.username)
M_PASS=$(printf '%s' "${M_ENROL%"$NL"*}" | jget data.credentials.password)
# `:-none`, or a failed create would compare two empty strings and pass.
run "$M_DEVICE" "${M_USER:-none}" "and enrolled while the community is subscribed"

# MINTED NOW: /devices/{id}/token is behind the same gate after the flip.
M_TOKEN2=$(api POST "/devices/${M_DEVICE}/token" | jget data.token)
run 1 "$([ -n "$M_TOKEN2" ] && echo 1 || echo 0)" "a second token was minted BEFORE deactivation"

if [ -z "$M_DEVICE" ] || [ -z "$M_PASS" ]; then
    note "no enrolled device - the rest of section M would be noise; skipped"
else
    AUDIT_MARK=$(psql_crm "SELECT COALESCE(max(id), 0) FROM audit_log;")
    # Armed only while the community is held unsubscribed. Any other death is
    # repaired by the next run's step 0.
    trap 'echo; echo "  interrupted - re-subscribing Test Community"; crm_annex subscribe >/dev/null; exit 130' INT TERM

    UNSUB=$(crm_annex unsubscribe)
    run 200 "${UNSUB%% *}" "POST /annexes-services/live-data/unsubscribe as an ADMIN"
    run f "$(sub_active)" "community_subscription.is_active is now false - the row is kept"
    run 1 "$(psql_crm "SELECT count(*) FROM audit_log WHERE id > ${AUDIT_MARK} AND id_community = ${COMMUNITY} AND action = 'crm.community_subscription.unsubscribed';")" \
        "and crm-backend audited the flip"

    # /version's handler touches no database, so a 403 there can only be the
    # router-level gate - and the status AND the code, in one line.
    M_VERSION=$(curl -sS -w '\n%{http_code}' "${API}/version" \
        -H "X-User-Id: ${USER_ID}" -H "X-Community-Id: ${ORG}" -H "X-User-Orgs: ${ORGS}" \
        2>/dev/null | tr -d '\r')
    run "403 1003" "${M_VERSION##*"$NL"} $(printf '%s' "${M_VERSION%"$NL"*}" | jget error_code)" \
        "GET /version is 403 NOT_SUBSCRIBED (1003) - the code the SPA's switch-off keys on"

    # BEFORE the parity probes: a /token that slipped the gate would consume
    # M_TOKEN2 and turn this 2430 into a 2411.
    M_REFUSED=$(enrol_direct "$M_TOKEN2")
    run 403 "${M_REFUSED##*"$NL"}" "enrolment with a token minted while subscribed is REFUSED"
    run 2430 "$(printf '%s' "${M_REFUSED%"$NL"*}" | jget error_code)" \
        "as COMMUNITY_NOT_SUBSCRIBED (2430), not the opaque token answer"

    # STRICT PARITY. Revoke LAST: if it slipped through, every line after says so.
    for probe in "GET /devices" "GET /summary" "GET /ops/health" \
                 "POST /devices/${M_DEVICE}/token" "POST /devices/${M_DEVICE}/revoke"; do
        run 403 "$(code -X "${probe%% *}" "${API}${probe#* }" \
            -H "X-User-Id: ${USER_ID}" -H "X-Community-Id: ${ORG}" -H "X-User-Orgs: ${ORGS}")" \
            "${probe} is 403 while deactivated"
    done
    run 2 "$(psql_live "SELECT status FROM device WHERE public_id='${M_DEVICE}';")" \
        "the device is still ACTIVE (2): deactivation keeps it"

    sleep "$SUB_WAIT"
    # Anchored 3 h BEFORE the reactivated batch below, so the two hours cannot
    # overlap: a worker that replayed this one later would make that count 8.
    M_SIM=$(sim --username "$M_USER" --password "$M_PASS" --community "$COMMUNITY" \
        --profile backlog --hours 1 --anchor-ts "$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)")
    sleep 4
    run 1 "$(printf '%s' "$M_SIM" | grep -c "connected as ${M_DEVICE}")" \
        "its credentials still CONNECT - after the refused enrolment, so nothing rotated them"
    run 1 "$(mlog "Sending PUBLISH to live-data-ingest .*ce/${COMMUNITY}/${M_DEVICE}/telemetry")" \
        "the broker DELIVERED the telemetry to the worker"
    run 0 "$(m_rows)" "and the worker DISCARDED it: nothing stored"
    run 1 "$(psql_live "SELECT count(*) FROM device_last dl JOIN device d ON d.id = dl.id_device WHERE d.public_id = '${M_DEVICE}' AND dl.status_at IS NOT NULL AND dl.ts IS NULL;")" \
        "its STATUS was processed, its telemetry was not"
    note "all three, never one alone: zero rows is also what a device that never"
    note "connected, or a broker that never delivered, looks like. Status is kept"
    note "on purpose - dropped, a device that reconnected while deactivated would"
    note "read OFFLINE after reactivation until its next reconnect."

    RESUB=$(crm_annex subscribe)
    trap - INT TERM
    run 200 "${RESUB%% *}" "POST /annexes-services/live-data/subscribe re-activates"
    run 1 "$(psql_crm "SELECT count(*) FROM audit_log WHERE id > ${AUDIT_MARK} AND id_community = ${COMMUNITY} AND action = 'crm.community_subscription.reactivated';")" \
        "as a REACTIVATION of the same row, audited"
    run 200 "$(code -H "X-User-Id: ${USER_ID}" -H "X-Community-Id: ${ORG}" \
        -H "X-User-Orgs: ${ORGS}" ${API}/version)" "GET /version answers 200 again at once"
    note "the API gate reads the CRM per request; only the worker caches."

    sleep "$SUB_WAIT"
    sim --username "$M_USER" --password "$M_PASS" --community "$COMMUNITY" \
        --profile backlog --hours 1 --anchor-ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null
    sleep 4
    run 4 "$(m_rows)" "the SAME credentials' next hour is stored - no re-enrolment"
    note "4, not 8: the hour sent while deactivated is gone for good. A worker that"
    note "parked it and replayed it here would contradict the unsubscribe dialog."

    api POST "/devices/${M_DEVICE}/revoke" >/dev/null
    run "$CLIENTS_BEFORE" "$(dynsec_clients)" "revoked on the way out: no broker client left behind"
fi
run t "$(sub_active)" "Test Community is left SUBSCRIBED, so the next run starts green"

# ---------------------------------------------------------------------------
next_section
echo "N. Sharing operations (D-14): per-operation rollups, the shared estimate,"
echo "   and the line a member may not cross."
note "the projection is refreshed and the tick run on demand, with the same"
note "functions the scheduler calls - ownership FIRST, as the scheduler now does."

$DC exec -T live-data-scheduler python -c "
import asyncio, datetime
from ports.crm_core import SqlAlchemyCrmCoreRead
from worker import rollups
from worker.context import crm_sessionmaker, local_sessionmaker
from worker.ownership import refresh_ownership

async def main():
    now = datetime.datetime.now(datetime.UTC)
    async with local_sessionmaker()() as local, crm_sessionmaker()() as crm:
        await refresh_ownership(local, SqlAlchemyCrmCoreRead(crm), now=now, communities=None)
        await local.commit()
        await rollups.run_tick(local, now=now)
        await local.commit()

asyncio.run(main())
" >/dev/null 2>&1

N_OP_CRM=$(psql_crm "SELECT id_sharing_operation FROM meter_data WHERE ean = '${EAN}' AND status = 1 AND id_sharing_operation IS NOT NULL ORDER BY start_date DESC LIMIT 1;")
N_OP_LIVE=$(psql_live "SELECT id_sharing_operation FROM device_owner_window WHERE ean = '${EAN}' AND id_community = ${COMMUNITY} AND NOT ambiguous ORDER BY valid_from DESC LIMIT 1;")
run "${N_OP_CRM:-(none in the CRM)}" "${N_OP_LIVE:-(none projected)}" \
    "the projection carries ${EAN}'s sharing operation from the CRM"

N_ROWS=$(psql_live "SELECT count(*) FROM rollup_operation_hour WHERE id_community = ${COMMUNITY} AND id_sharing_operation <> 0;")
run 1 "$([ "${N_ROWS:-0}" -gt 0 ] && echo 1 || echo 0)" \
    "operation hours are rolled up ($N_ROWS)"

run 0 "$(psql_live "SELECT count(*) FROM rollup_operation_hour WHERE id_community = ${COMMUNITY} AND shared_wh > LEAST(import_wh, export_wh) + 0.000001;")" \
    "no operation hour claims more shared than its lesser flow"

run 0 "$(psql_live "SELECT count(*) FROM rollup_community_hour c WHERE c.id_community = ${COMMUNITY} AND abs(c.import_wh - COALESCE((SELECT sum(o.import_wh) FROM rollup_operation_hour o WHERE o.id_community = c.id_community AND o.bucket = c.bucket), -1)) > 0.001;")" \
    "every community hour's IMPORT is exactly the sum of its operation rows"
run 0 "$(psql_live "SELECT count(*) FROM rollup_community_hour c WHERE c.id_community = ${COMMUNITY} AND abs(c.export_wh - COALESCE((SELECT sum(o.export_wh) FROM rollup_operation_hour o WHERE o.id_community = c.id_community AND o.bucket = c.bucket), -1)) > 0.001;")" \
    "and its EXPORT too"
note "the remainder row (id 0) is what makes this exact - and the global privacy"
note "verdict depends on it: it must know whether anything outside the visible"
note "operations exists at all."

run 0 "$(psql_live "WITH q AS (SELECT m.id_device, m.ts, m.import_wh, m.export_wh, date_trunc('hour', (m.ts - INTERVAL '1 second') AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS bucket FROM measurement m WHERE m.id_community = ${COMMUNITY}), a AS (SELECT q.*, w.id_sharing_operation AS op FROM q JOIN device d ON d.id = q.id_device JOIN device_owner_window w ON w.ean = d.ean AND w.id_community = d.id_community AND NOT w.ambiguous AND (q.bucket AT TIME ZONE 'Europe/Brussels')::date BETWEEN w.valid_from AND COALESCE(w.valid_to, 'infinity'::date) WHERE w.id_sharing_operation IS NOT NULL), per_q AS (SELECT op, bucket, ts, LEAST(sum(export_wh), sum(import_wh)) AS s FROM a GROUP BY op, bucket, ts), recomputed AS (SELECT op, bucket, sum(s) AS s FROM per_q GROUP BY op, bucket) SELECT count(*) FROM rollup_operation_hour r JOIN recomputed x ON x.op = r.id_sharing_operation AND x.bucket = r.bucket WHERE r.id_community = ${COMMUNITY} AND abs(r.shared_wh - x.s) > 0.001;")" \
    "the shared figure equals a PER-QUARTER recomputation from the raw readings"
note "never from hourly sums: a 10:15 surplus cannot cover a 10:45 offtake, and"
note "the hourly form would claim it did."

run 0 "$(psql_live "SELECT count(*) FROM rollup_operation_day d WHERE d.id_community = ${COMMUNITY} AND abs(d.import_wh - (SELECT sum(h.import_wh) FROM rollup_operation_hour h WHERE h.id_community = d.id_community AND h.id_sharing_operation = d.id_sharing_operation AND h.bucket >= d.bucket AND h.bucket < ((d.bucket AT TIME ZONE 'Europe/Brussels') + INTERVAL '1 day') AT TIME ZONE 'Europe/Brussels')) > 0.001;")" \
    "every operation day is the sum of its hours"
run 0 "$(psql_live "SELECT count(*) FROM rollup_operation_hour WHERE id_sharing_operation = 0 AND shared_wh IS NOT NULL;")" \
    "the remainder row never carries a shared figure"
run 0 "$(psql_live "SELECT (SELECT count(*) FROM rollup_operation_hour_default) + (SELECT count(*) FROM rollup_operation_day_default);")" \
    "nothing landed in the operation tables' DEFAULT partitions"

# ---- as the MANAGER ----
run 200 "$(code -H "X-User-Id: ${USER_ID}" -H "X-Community-Id: ${ORG}" \
    -H "X-User-Orgs: ${ORGS}" "${API}/operations")" "GET /operations answers the manager"
run 1 "$(api GET /operations | $DC exec -T live-data python -c \
    "import json,sys; print(sum(1 for op in json.load(sys.stdin)['data'] if str(op['id']) == '${N_OP_CRM}'))" \
    2>/dev/null | tr -d '\r')" \
    "and lists the operation ${EAN} is in"
run 200 "$(code -H "X-User-Id: ${USER_ID}" -H "X-Community-Id: ${ORG}" \
    -H "X-User-Orgs: ${ORGS}" "${API}/operations/${N_OP_CRM}/series?resolution=hour")" \
    "GET /operations/{id}/series answers"
run 404 "$(code -H "X-User-Id: ${USER_ID}" -H "X-Community-Id: ${ORG}" \
    -H "X-User-Orgs: ${ORGS}" "${API}/operations/999999/series")" \
    "an operation that is not this community's is NOT FOUND, never 403"
run 422 "$(code -H "X-User-Id: ${USER_ID}" -H "X-Community-Id: ${ORG}" \
    -H "X-User-Orgs: ${ORGS}" "${API}/operations/0/series")" \
    "the remainder row is not addressable as an operation"

# ---- as a MEMBER: the seeded `auth0|member`, Member One, who holds a meter ----
M_USER='auth0|member'
M_ORGS="[orgId:${ORG} orgPath:/Test Community roles:[MEMBER]]"
mcode() { code -H "X-User-Id: ${M_USER}" -H "X-Community-Id: ${ORG}" -H "X-User-Orgs: ${M_ORGS}" "${API}$1"; }
mget() { curl -sS "${API}$1" -H "X-User-Id: ${M_USER}" -H "X-Community-Id: ${ORG}" -H "X-User-Orgs: ${M_ORGS}"; }
M_OP=$(psql_crm "SELECT DISTINCT md.id_sharing_operation FROM meter_data md JOIN user_member_link uml ON uml.id_member = md.id_member JOIN app_user au ON au.id = uml.id_user JOIN meter mt ON mt.ean = md.ean AND mt.id_community = ${COMMUNITY} WHERE au.auth_user_id = '${M_USER}' AND md.status = 1 AND md.id_sharing_operation IS NOT NULL AND CURRENT_DATE BETWEEN md.start_date AND COALESCE(md.end_date, 'infinity'::date) ORDER BY 1 LIMIT 1;")
M_OTHER=$(psql_crm "SELECT id FROM sharing_operation WHERE id_community = ${COMMUNITY} AND id <> ${M_OP:-0} ORDER BY id LIMIT 1;")

for path in /summary "/series?resolution=hour" /forecast /operations; do
    run 403 "$(mcode "$path")" "a MEMBER is refused the community read ${path%%\?*}"
done
run "${M_OP:-(none)}" "$(mget /mine/operations | $DC exec -T live-data python -c \
    "import json,sys; print(','.join(str(op['id']) for op in json.load(sys.stdin)['data']) or '(none)')" \
    2>/dev/null | tr -d '\r')" \
    "GET /mine/operations lists exactly the member's own operation"
run 0 "$(mget "/mine/operations/${M_OP}/series?resolution=hour" | grep -cE '"(import_wh|shared_wh)"')" \
    "their series carries no import and no shared figure, anywhere"
if [ -n "$M_OTHER" ]; then
    run 404 "$(mcode "/mine/operations/${M_OTHER}/series")" \
        "another operation of the same community is NOT FOUND for them"
fi

# Criterion 8 on the member read, with its positive control - and the settings
# put back exactly as they were, row or no row.
N_SETTINGS=$(psql_live "SELECT members_see_production FROM community_live_settings WHERE id_community = ${COMMUNITY};")
if [ -n "$N_SETTINGS" ]; then
    psql_live "UPDATE community_live_settings SET members_see_production = FALSE WHERE id_community = ${COMMUNITY};" >/dev/null
else
    psql_live "INSERT INTO community_live_settings (id_community, members_see_production, members_see_aggregate, k) VALUES (${COMMUNITY}, FALSE, TRUE, 5);" >/dev/null
fi
run 2440 "$(mget /mine/operations | jget error_code)" \
    "with production hidden from members, /mine is refused with 2440"
if [ -n "$N_SETTINGS" ]; then
    # QUOTED and cast: psql -At prints a boolean as `t`/`f`, and a bare `t` is a
    # column name - the restore failed silently and left the setting OFF.
    psql_live "UPDATE community_live_settings SET members_see_production = '${N_SETTINGS}'::boolean WHERE id_community = ${COMMUNITY};" >/dev/null
else
    psql_live "DELETE FROM community_live_settings WHERE id_community = ${COMMUNITY};" >/dev/null
fi
run 200 "$(mcode /mine/operations)" "and answers again once the setting is restored"
run "${N_SETTINGS:-(no row)}" "$(psql_live "SELECT members_see_production FROM community_live_settings WHERE id_community = ${COMMUNITY};")"     "and the setting is back EXACTLY as it was"

run 401 "$(code ${GW}/live/mine/operations)" \
    "GET /api/live/mine/operations is AUTHENTICATED at the gateway"


# ---------------------------------------------------------------------------
echo
echo "============================================================"
printf 'live ingest: %s passed, %s failed\n' "$PASSED" "$FAILED"
if [ "$FAILED" -ne 0 ]; then
    cat <<'FOOTER'

THE LIVE DATA PATH IS NOT PROVEN.

What each section costs when it fails, so the output above can be triaged
without reading any of the code:

  A  the service reports healthy over a database with no schema, or the
     create-ahead partition job has stopped and readings are quietly
     accumulating in DEFAULT, where no range query will find them.
  B  an EAN typo creates a device that ingests perfectly and is attributed to
     nobody. Found months later, with real data already stored against it.
  C  the enrolment leg is broken, or a forged header reaches the handler. The
     second is a tenancy hole on the one endpoint with no authentication.
  D  a token can be spent twice, a device is issued a credential that
     authenticates nothing, or the endpoint tells an attacker which guesses
     were real. On a keyboard-less box in a basement, each is a site visit.
  E  telemetry is accepted and lost. Nothing reports it: the flow is one-way.
  F  a re-sent backlog duplicates - and 4.3 has already told every connector
     author that re-sending is the safe thing to do.
  G  rejections are invisible, so nobody can tell a silent device from a
     rejected one, and the first symptom is a member's bill.
  H  a revoked device keeps publishing, or its retained status replays on every
     worker reconnect until the team stops reading the alert.
  I  the public leg is unreachable, or - far worse - an authenticated route has
     been published without its validator, or nginx is about to refuse to start
     on the next deploy. None of the three shows up in `docker compose ps`:
     the krakend service has no healthcheck at all.
  J  the rollups are wrong or frozen. Every chart in the product reads from
     them, nothing errors when they stop, and a partial hour written over a
     correct one is invisible for ever.
  K  the read API is unreachable, or - worse - it answers an unsnapped window,
     which is the differencing attack answered politely.
  L  the forecast seam has changed shape before a method exists, so the
     frontend written against it in step 10 is written against a guess.
  M  deactivating Live Data only hides a page: an unsubscribed community's
     meters keep streaming into storage and rollups for ever - or reactivation
     strands every device and each one needs a site visit to re-enrol.
  N  a sharing operation's figures are wrong or leak: energy counted in the
     wrong operation or twice, a shared figure larger than what was ever
     shared, or a member reading the community or someone else's operation.
FOOTER
    exit 1
fi
echo
exit 0
