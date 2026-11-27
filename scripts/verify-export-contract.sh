#!/usr/bin/env bash
#
# The stack-level check of the data-export contract (contracts/export/README.md §10), on the
# running dev stack: does every service of EXPORT_SERVICES answer its part of a real job?
#
# Each service's own CI runs the kit's contract test against its handler (run_contract_check in
# the Python annexes, the functional tests in crm-backend). This script checks what no single CI
# can see: the services deployed together, on the real broker and bucket, answer a real job.
#
# What it does, as the API would but without a browser login (no step-up to fake):
#   1. creates a throwaway requester and community in crm_db, both with the auth id
#      `export-contract-probe-<run>` (the requester is ADMIN of the community; nothing else in it);
#   2. injects one user export and one community export: an export_job (pending) and one
#      export_part per service, then publishes export.job.requested (when that fails, the worker's
#      sweep starts the jobs at its next tick);
#   3. waits for every part, and fails NAMING THE SERVICE when a part is not `done` within the
#      timeout of its request (60 s by default), or answers `failed`;
#   4. once every part of a job is done, waits for its archive (the worker assembles it);
#   5. cleans up: the stored parts and archives, the outbound mails, the probe rows (their jobs,
#      parts and notifications cascade) and the probe's Mailpit messages. Probes left by an
#      interrupted or --keep run are removed at the start of the next run. A service that answers
#      after the cleanup finds no job: the worker deletes what it wrote.
#
# Dev stack only: it writes to crm_db as `postgres` and finds the containers by their compose
# names (override with COMPOSE_PROJECT_NAME, or EXPORT_CHECK_PG / _API / _WORKER / _NETWORK).
#
#   ./scripts/verify-export-contract.sh [--timeout SECONDS] [--scope user|community|both]
#                                       [--services a,b,...] [--keep]
#
#   --timeout   seconds a part may take from its request (default 60)
#   --scope     which export(s) to inject (default both)
#   --services  the parts to ask for (default: crm-backend's EXPORT_SERVICES, what a real job asks)
#   --keep      leave the probe, its jobs and archives in place for a look (the next run removes them)
#
# Exit: 0 every part done in time and every archive assembled; 1 a service failed, did not
# answer or the archive was not assembled; 2 the stack is not usable (a container down, no service).

set -uo pipefail
export MSYS_NO_PATHCONV=1 # Git Bash on Windows: pass /app and the like to docker untouched

cd "$(dirname "$0")/.." || exit 2

PROJECT="${COMPOSE_PROJECT_NAME:-monorepo}"
PG="${EXPORT_CHECK_PG:-$PROJECT-postgres-1}"
API="${EXPORT_CHECK_API:-$PROJECT-crm-backend-1}"
WORKER="${EXPORT_CHECK_WORKER:-$PROJECT-crm-export-worker-1}"
NETWORK="${EXPORT_CHECK_NETWORK:-${PROJECT}_backend}"
MAILPIT_URL="${MAILPIT_URL:-http://127.0.0.1:8007}"

SCHEMA_VERSION="1.0"  # contracts/export/README.md §2 (EXPORT_SCHEMA_VERSION)
START_TIMEOUT=100     # publish failed: the worker's tick (60 s) + its pending grace (30 s) + margin
ASSEMBLY_TIMEOUT=120  # all parts done -> archive ready
POLL_SECONDS=2
PROBE_PATTERN="export-contract-probe-%"

TIMEOUT=60
SCOPE="both"
SERVICES=""
KEEP=0

usage() { sed -n '3,35p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT="${2:-}"; shift 2 || exit 2 ;;
    --scope) SCOPE="${2:-}"; shift 2 || exit 2 ;;
    --services) SERVICES="${2:-}"; shift 2 || exit 2 ;;
    --keep) KEEP=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done
case "$TIMEOUT" in '' | *[!0-9]*) echo "--timeout takes whole seconds" >&2; exit 2 ;; esac
case "$SCOPE" in user) SCOPES=(user) ;; community) SCOPES=(community) ;; both) SCOPES=(user community) ;;
  *) echo "--scope is user, community or both" >&2; exit 2 ;; esac

sql() { docker exec -i "$PG" psql -U postgres -d crm_db -v ON_ERROR_STOP=1 -AtXq; }
env_of() { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null | sed -n "s/^$2=//p" | head -n 1; }
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }

for container in "$PG" "$API" "$WORKER"; do
  running "$container" || { echo "not running: $container (start the dev stack first)" >&2; exit 2; }
done

[ -n "$SERVICES" ] || SERVICES="$(env_of "$API" EXPORT_SERVICES)"
SERVICE_LIST=()
IFS=',' read -r -a raw_services <<<"$SERVICES"
for s in "${raw_services[@]}"; do
  s="${s//[[:space:]]/}"
  [ -n "$s" ] || continue
  [[ "$s" =~ ^[a-z][a-z0-9-]{1,62}$ ]] || { echo "not a service name: $s" >&2; exit 2; }
  SERVICE_LIST+=("$s")
done
[ "${#SERVICE_LIST[@]}" -gt 0 ] || { echo "no service to ask: EXPORT_SERVICES is empty on $API" >&2; exit 2; }
SERVICES_CSV="$(IFS=','; echo "${SERVICE_LIST[*]}")"

# ---- cleanup --------------------------------------------------------------------------------

# Deletes everything stored for the given exports: parts/<id>/ (a part a service wrote before its
# job was deleted unfinished stays there: the worker removes parts only when it fails or assembles
# a job) and archives/<id>/. With the worker's own account, which deletes both anyway.
delete_export_objects() {
  local id image bucket endpoint targets=()
  for id in "$@"; do
    # Never a prefix wider than one export: an empty or odd id would make it parts/ itself.
    [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || continue
    bucket="${bucket:-$(env_of "$WORKER" EXPORT_BUCKET)}"
    targets+=("x/${bucket:-exports}/parts/$id/" "x/${bucket:-exports}/archives/$id/")
  done
  [ "${#targets[@]}" -gt 0 ] || return 0
  image="$(docker inspect -f '{{.Config.Image}}' "$PROJECT-minio-init-1" 2>/dev/null)"
  endpoint="$(env_of "$WORKER" EXPORT_STORAGE_ENDPOINT)" # http://minio:9000
  if ! docker run --rm --network "$NETWORK" \
    -e "MC_HOST_x=${endpoint%%://*}://$(env_of "$WORKER" EXPORT_STORAGE_ACCESS_KEY):$(env_of "$WORKER" EXPORT_STORAGE_SECRET_KEY)@${endpoint#*://}" \
    "${image:-pgsty/mc:latest}" rm --recursive --force --quiet "${targets[@]}" >/dev/null 2>&1; then
    echo "  stored files not deleted: the bucket's lifecycle rules remove them (parts 2 days, archives 8)" >&2
  fi
}

# Mailpit (dev's mail catcher): the probe's ready/failed mails. Best effort.
delete_mails() {
  local query ids
  query="to%3A%22$1%22"
  ids="$(curl -fsS --max-time 5 "$MAILPIT_URL/api/v1/search?query=$query" 2>/dev/null |
    grep -o '"ID":"[^"]*"' | sed 's/"ID":"\([^"]*\)"/"\1"/' | paste -sd, -)"
  [ -n "$ids" ] || return 0
  curl -fsS --max-time 5 -X DELETE -H 'Content-Type: application/json' \
    -d "{\"IDs\":[${ids}]}" "$MAILPIT_URL/api/v1/messages" >/dev/null 2>&1 || true
}

# Removes every probe matching the LIKE pattern $1, and what it left.
remove_probes() {
  local jobs
  jobs="$(sql <<SQL
SELECT j.id FROM export_job j JOIN app_user u ON u.id = j.id_requester WHERE u.auth_user_id LIKE '$1';
SQL
)"
  # shellcheck disable=SC2086 # export ids are UUIDs
  [ -z "$jobs" ] || delete_export_objects $jobs
  sql <<SQL >/dev/null
DELETE FROM outbound_message WHERE type LIKE 'data_export.%' AND data->>'export_id' IN (
  SELECT j.id::text FROM export_job j JOIN app_user u ON u.id = j.id_requester WHERE u.auth_user_id LIKE '$1');
DELETE FROM app_user WHERE auth_user_id LIKE '$1';
DELETE FROM community WHERE auth_community_id LIKE '$1';
SQL
}

PROBE=""
JOB_IDS=()
cleanup() {
  [ -n "$PROBE" ] || return 0
  if [ "$KEEP" = 1 ]; then
    echo "kept: requester and community '$PROBE' with their export(s); the next run removes them"
    return 0
  fi
  # An archive being written is left to finish: deleting its job under the worker only fails it.
  local i
  for i in $(seq 1 15); do
    [ "$(sql <<<"SELECT count(*) FROM export_job j JOIN app_user u ON u.id = j.id_requester
                 WHERE u.auth_user_id = '$PROBE' AND j.status = 'assembling';")" = "0" ] && break
    sleep 2
  done
  remove_probes "$PROBE"
  sleep 3 # a ready/failed mail already handed to the dispatcher lands in Mailpit first
  delete_mails "$PROBE@example.test"
  echo "cleaned: probe '$PROBE', ${#JOB_IDS[@]} export(s), their archives and mails"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

# ---- probe and jobs -------------------------------------------------------------------------

remove_probes "$PROBE_PATTERN" # leftovers of an interrupted or --keep run

PROBE="export-contract-probe-$(date +%s)$$"
ids="$(sql <<SQL
WITH u AS (
  INSERT INTO app_user (auth_user_id, email, first_name, last_name, locale)
  VALUES ('$PROBE', '$PROBE@example.test', 'Export', 'Contract probe', 'fr') RETURNING id
), c AS (
  INSERT INTO community (name, auth_community_id) VALUES ('Export contract probe', '$PROBE') RETURNING id
), cu AS (
  INSERT INTO community_user (id_community, id_user, role) SELECT c.id, u.id, 'ADMIN' FROM c, u
)
SELECT u.id || ' ' || c.id FROM u, c;
SQL
)" || { echo "could not create the probe in crm_db" >&2; exit 2; }
read -r USER_ID COMMUNITY_ID <<<"$ids"

for scope in "${SCOPES[@]}"; do
  if [ "$scope" = user ]; then community="NULL"; else community="$COMMUNITY_ID"; fi
  # created_at a minute back: past the worker's pending grace, so its sweep starts the job even if
  # the publish below fails.
  job="$(sql <<SQL
WITH j AS (
  INSERT INTO export_job (id, scope_type, scope_id, id_community, requester_user_id, id_requester,
                          schema_version, locale, created_at)
  VALUES (gen_random_uuid(), '$scope', '$PROBE', $community, '$PROBE', $USER_ID,
          '$SCHEMA_VERSION', 'fr', NOW() - INTERVAL '1 minute')
  RETURNING id
), p AS (
  INSERT INTO export_part (id, export_job_id, service)
  SELECT gen_random_uuid(), j.id, s FROM j, unnest(string_to_array('$SERVICES_CSV', ',')) AS s
)
SELECT id FROM j;
SQL
)" || { echo "could not inject the $scope export" >&2; exit 2; }
  JOB_IDS+=("$job")
done
IN_LIST="$(printf "'%s'," "${JOB_IDS[@]}")"
IN_LIST="${IN_LIST%,}"

# export.job.requested, as the API publishes it (Nats-Msg-Id <exportId>:requested), from the
# worker's container: it has the broker's address and a NATS client.
if docker exec -i -w /app -e "IDS=${JOB_IDS[*]}" -e "V=$SCHEMA_VERSION" "$WORKER" node --input-type=module -e '
import { connect, JSONCodec } from "nats";
const codec = JSONCodec();
const nc = await connect({ servers: process.env.NATS_URL, timeout: 3000 });
const js = nc.jetstream();
for (const exportId of process.env.IDS.split(" ")) {
  await js.publish("export.job.requested", codec.encode({ schemaVersion: process.env.V, exportId }),
    { msgID: `${exportId}:requested`, expect: { streamName: "EXPORTS" }, timeout: 2000 });
}
await nc.drain();
' >/dev/null 2>&1; then
  started_how="export.job.requested published"
else
  started_how="publish failed: waiting for the worker's sweep (up to ${START_TIMEOUT} s)"
fi

echo "Export contract check: ${#SERVICE_LIST[@]} service(s) x ${#JOB_IDS[@]} export(s), ${TIMEOUT} s per part"
echo "  probe $PROBE; $started_how"

# ---- wait for the parts ---------------------------------------------------------------------

# One line per part: scope|service|part status|job status|seconds since its request (-1 not yet
# requested)|last error.
parts_state() {
  sql <<SQL
SELECT j.scope_type, p.service, p.status, j.status,
       CASE WHEN p.requested_at IS NULL THEN -1
            ELSE floor(extract(epoch FROM
                   (CASE WHEN p.status = 'pending' THEN NOW() ELSE p.updated_at END) - p.requested_at))::int
       END,
       regexp_replace(coalesce(p.last_error, ''), '\s+', ' ', 'g')
  FROM export_part p JOIN export_job j ON j.id = p.export_job_id
 WHERE j.id IN ($IN_LIST)
 ORDER BY j.scope_type DESC, p.service;
SQL
}

start_deadline=$(($(date +%s) + START_TIMEOUT))
while :; do
  state="$(parts_state)" || { echo "crm_db query failed" >&2; exit 2; }
  open=0
  while IFS='|' read -r _scope _service pstatus jstatus elapsed _error; do
    [ -n "$pstatus" ] || continue
    if [ "$pstatus" = pending ] && [ "$jstatus" != failed ]; then
      if [ "$elapsed" -lt 0 ]; then
        [ "$(date +%s)" -ge "$start_deadline" ] || open=$((open + 1))
      elif [ "$elapsed" -lt "$TIMEOUT" ]; then
        open=$((open + 1))
      fi
    fi
  done <<<"$state"
  [ "$open" -gt 0 ] || break
  sleep "$POLL_SECONDS"
done

# ---- report ---------------------------------------------------------------------------------

FAILED_SERVICES=()
fail() { FAILED_SERVICES+=("$1"); }

printf '\n  %-10s %-28s %s\n' "scope" "service" "result"
while IFS='|' read -r scope service pstatus jstatus elapsed error; do
  [ -n "$pstatus" ] || continue
  case "$pstatus" in
    done)
      if [ "$elapsed" -le "$TIMEOUT" ]; then
        result="done in ${elapsed} s"
      else
        result="LATE: done in ${elapsed} s (over ${TIMEOUT} s)"; fail "$service"
      fi ;;
    failed) result="FAILED: ${error:-no detail}"; fail "$service" ;;
    *)
      if [ "$jstatus" = failed ]; then
        result="not answered: the job failed on another part first"
      elif [ "$elapsed" -lt 0 ]; then
        result="NOT REQUESTED: the worker never started the job ($WORKER)"; fail "worker"
      else
        result="NO ANSWER in ${TIMEOUT} s"; fail "$service"
      fi ;;
  esac
  printf '  %-10s %-28s %s\n' "$scope" "$service" "$result"
done <<<"$(parts_state)"

# The archives: only for jobs whose every part is done (otherwise nothing to assemble).
assembled_ok=1
for job in "${JOB_IDS[@]}"; do
  pending="$(sql <<<"SELECT count(*) FROM export_part WHERE export_job_id = '$job' AND status <> 'done';")"
  [ "$pending" = "0" ] || continue
  deadline=$(($(date +%s) + ASSEMBLY_TIMEOUT))
  while :; do
    row="$(sql <<<"SELECT scope_type, status, coalesce(size_bytes::text, ''), coalesce(error_code, '') FROM export_job WHERE id = '$job';")"
    IFS='|' read -r scope status size code <<<"$row"
    case "$status" in ready | failed) break ;; esac
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep "$POLL_SECONDS"
  done
  case "$status" in
    ready) printf '  %-10s %-28s %s\n' "$scope" "(archive)" "assembled, ${size} bytes" ;;
    failed) printf '  %-10s %-28s %s\n' "$scope" "(archive)" "FAILED: ${code}"; assembled_ok=0 ;;
    *) printf '  %-10s %-28s %s\n' "$scope" "(archive)" "NOT ASSEMBLED in ${ASSEMBLY_TIMEOUT} s (status ${status})"; assembled_ok=0 ;;
  esac
done
echo

if [ "${#FAILED_SERVICES[@]}" -gt 0 ]; then
  names="$(printf '%s\n' "${FAILED_SERVICES[@]}" | sort -u | paste -sd, - | sed 's/,/, /g')"
  echo "FAIL: $names"
  exit 1
fi
if [ "$assembled_ok" != 1 ]; then
  echo "FAIL: every part was done, but the worker did not assemble the archive (see $WORKER's logs)"
  exit 1
fi
echo "OK: every part of ${#SERVICE_LIST[@]} service(s) done within ${TIMEOUT} s, ${#JOB_IDS[@]} archive(s) assembled"
exit 0
