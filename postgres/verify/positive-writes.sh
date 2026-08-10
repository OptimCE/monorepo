#!/bin/sh
# ===========================================================================
# The script that matters most. Proves every granted CRM write actually LANDS.
#
# "We saw no 500s" is not evidence here. Two of the three CRM write paths
# swallow their own exception:
#
#   AuditLogService.log       — billing/core/audit_log/service.py:73
#   NotificationService.publish — billing/core/notifications/service.py:155
#
# Both wrap the INSERT in a begin_nested() SAVEPOINT under a blanket
# `except Exception: logger.exception(...)`. A missing grant therefore does NOT
# raise: the business transaction commits, the API returns 200, and the audit
# trail and every email disappear with only a log line to show for it. Only
# allocation-key-generation's CRM write fails loudly
# (allocation-key-generation/shared/crm_repository.py:11).
#
# So the grants must be proved POSITIVELY, per role.
#
#     docker compose -f docker-compose.dev.yml --env-file .env.dev run --rm \
#       --no-deps --entrypoint /postgres/verify/positive-writes.sh postgres-init
#
# Every assertion runs inside BEGIN; ... ROLLBACK; so dev — and production —
# data is untouched. nextval is non-transactional, so the sequence advances:
# harmless, and exactly what proves the sequence grant was needed and present.
# ===========================================================================
set -u

PASSED=0
FAILED=0

pw_for() {
    case $1 in
        crm_svc)                     printf '%s' "$CRM_DB_PASSWORD" ;;
        allocation_key_svc)          printf '%s' "$ALLOCATION_KEY_DB_PASSWORD" ;;
        simulation_key_svc)          printf '%s' "$SIMULATION_KEY_DB_PASSWORD" ;;
        news_board_svc)              printf '%s' "$NEWS_BOARD_DB_PASSWORD" ;;
        billing_svc)                 printf '%s' "$BILLING_DB_PASSWORD" ;;
        administrative_document_svc) printf '%s' "$ADMINISTRATIVE_DOCUMENT_DB_PASSWORD" ;;
        notification_dispatch_svc)   printf '%s' "$NOTIFICATION_DISPATCH_DB_PASSWORD" ;;
        *) printf '' ;;
    esac
}

# check <role> <label>  — SQL on stdin, must succeed.
# On failure the psql output is printed: "permission denied for sequence
# audit_log_id_seq" tells you exactly which line to add to 30-crm-grants.sql.
check() {
    role=$1; label=$2
    pw=$(pw_for "$role")
    if out=$(PGPASSWORD="$pw" psql --no-psqlrc -q -v ON_ERROR_STOP=1 \
        -U "$role" -d crm_db -f - 2>&1); then
        PASSED=$((PASSED + 1))
        printf '  ok    %s\n' "$label"
    else
        FAILED=$((FAILED + 1))
        printf '  FAIL  %s\n' "$label"
        printf '%s\n' "$out" | sed 's/^/          /'
    fi
}

AUDIT_WRITERS='allocation_key_svc simulation_key_svc news_board_svc billing_svc administrative_document_svc'
NOTIFIERS='news_board_svc billing_svc administrative_document_svc'

# ---------------------------------------------------------------------------
echo
echo 'audit_log INSERT + audit_log_id_seq USAGE — all five annexe roles'
echo '  (id_community is nullable, so this ALWAYS inserts exactly one row and'
echo '   therefore ALWAYS calls nextval — the sequence grant is really exercised,'
echo '   not skipped because a lookup happened to return nothing.)'
for role in $AUDIT_WRITERS; do
    check "$role" "$role -> audit_log" <<'SQL'
BEGIN;
INSERT INTO audit_log (id_community, action, source, entity_type, entity_id, payload)
VALUES (NULL, 'verify.grant', 'verify', 'verify', '0', '{}'::jsonb);
ROLLBACK;
SQL
done

# ---------------------------------------------------------------------------
echo
echo 'notification INSERT + notification_id_seq USAGE — the three producers'
echo '  (id_user is NOT NULL REFERENCES app_user, so it must come from a real'
echo '   row. The 1/count(*) guard turns "the seed had no users, nothing was'
echo '   inserted, nothing was proved" into a division-by-zero FAILURE rather'
echo '   than a silent pass.)'
for role in $NOTIFIERS; do
    check "$role" "$role -> notification" <<'SQL'
BEGIN;
WITH src AS (SELECT id FROM app_user ORDER BY id LIMIT 1)
INSERT INTO notification (id_community, id_user, type, data)
SELECT NULL, id, 'verify.grant', '{}'::jsonb FROM src;
SELECT 1 / count(*)::int FROM notification WHERE type = 'verify.grant';
ROLLBACK;
SQL
done

# ---------------------------------------------------------------------------
echo
echo 'outbound_message INSERT + outbound_message_id_seq USAGE — the three producers'
echo '  (gen_random_uuid() keeps the unique index on dedupe_key out of the way.)'
for role in $NOTIFIERS; do
    check "$role" "$role -> outbound_message" <<'SQL'
BEGIN;
INSERT INTO outbound_message
    (id_notification, id_community, channel, recipient, type, category, data, dedupe_key)
VALUES
    (NULL, NULL, 2, 'verify@example.invalid', 'verify.grant', 1, '{}'::jsonb,
     'verify-' || gen_random_uuid());
SELECT 1 / count(*)::int FROM outbound_message WHERE type = 'verify.grant';
ROLLBACK;
SQL
done

# ---------------------------------------------------------------------------
echo
echo 'allocation_key -> iteration -> consumer cascade — allocation_key_svc'
echo '  (one ORM flush inserts all three, so granting only allocation_key fails'
echo '   on the children. This ALSO proves the GENERATED ALWAYS AS IDENTITY'
echo '   assumption in 30-crm-grants.sql: no sequence grant was issued for these'
echo '   three, and if that assumption were wrong this is where it breaks.'
echo '   Needs at least one community row — it is the one check that can fail'
echo '   for a seed reason rather than a grant reason.)'
check allocation_key_svc 'allocation_key_svc -> allocation_key/iteration/consumer' <<'SQL'
BEGIN;
WITH c AS (SELECT id FROM community ORDER BY id LIMIT 1),
     k AS (INSERT INTO allocation_key (name, description, id_community)
           SELECT '_verify', '_verify', id FROM c
           RETURNING id, id_community),
     i AS (INSERT INTO iteration (number, energy_allocated_percentage, id_key, id_community)
           SELECT 1, 100.0, id, id_community FROM k
           RETURNING id, id_community)
INSERT INTO consumer (name, energy_allocated_percentage, id_iteration, id_community)
SELECT '_verify', 100.0, id, id_community FROM i;
SELECT 1 / count(*)::int FROM consumer WHERE name = '_verify';
ROLLBACK;
SQL

# ---------------------------------------------------------------------------
echo
echo 'notification-dispatch: the claim loop and the bounce record'
echo '  (SELECT ... FOR UPDATE SKIP LOCKED requires the UPDATE privilege in its'
echo '   own right — this is the exact shape of infra/outbound_repository.py:84.)'
check notification_dispatch_svc 'notification_dispatch_svc -> claim outbound_message' <<'SQL'
BEGIN;
SELECT id FROM outbound_message
 WHERE status = 1 AND scheduled_for <= now()
 ORDER BY scheduled_for
 FOR UPDATE SKIP LOCKED
 LIMIT 1;
UPDATE outbound_message SET status = status WHERE id = -1;
ROLLBACK;
SQL

check notification_dispatch_svc 'notification_dispatch_svc -> email_suppression' <<'SQL'
BEGIN;
INSERT INTO email_suppression (email, reason, detail)
VALUES ('verify@example.invalid', 4, 'grant verification')
ON CONFLICT (email) DO NOTHING;
ROLLBACK;
SQL

# ---------------------------------------------------------------------------
echo
printf 'positive writes: %s passed, %s failed\n' "$PASSED" "$FAILED"
if [ "$FAILED" -ne 0 ]; then
    echo 'A GRANTED WRITE DOES NOT WORK. In the running app this failure is'
    echo 'SILENT — the API returns 200 and the row simply never appears.'
    exit 1
fi
echo 'every granted CRM write lands.'
exit 0
