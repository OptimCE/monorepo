#!/bin/sh
# ===========================================================================
# Prove the isolation from postgres/provision/, don't assume it.
#
# IMPLEMENTATION_PLAN.md §5.8: "A test that connects as billing_svc and asserts
# it *cannot* reach the other databases is the only evidence that 5.3 worked."
#
# Run it TWICE — once after a first init, once after `docker-stack.sh restart` —
# because only the restart case exercises convergence.
#
#     docker compose -f docker-compose.dev.yml --env-file .env.dev run --rm \
#       --no-deps --entrypoint /postgres/verify/isolation.sh postgres-init
#
# keycloak is deliberately absent from every matrix below: it lives on a
# SEPARATE instance (compose service `keycloak-db`), so these roles cannot even
# resolve a route to it. That is a stronger guarantee than a REVOKE, and it is
# why §5.3's `REVOKE CONNECT ... FROM PUBLIC` on `keycloak` was dropped.
# ===========================================================================
set -u

PASSED=0
FAILED=0

# run <pass|fail> <role> <password-var-value> <database> <sql> <label>
run() {
    expect=$1; role=$2; pw=$3; db=$4; sql=$5; label=$6
    if PGPASSWORD="$pw" psql --no-psqlrc -q -v ON_ERROR_STOP=1 \
        -U "$role" -d "$db" -c "$sql" >/dev/null 2>&1; then
        got=pass
    else
        got=fail
    fi
    if [ "$got" = "$expect" ]; then
        PASSED=$((PASSED + 1))
        printf '  ok   (%s)  %s\n' "$got" "$label"
    else
        FAILED=$((FAILED + 1))
        printf '  FAIL expected %s, got %s — %s\n' "$expect" "$got" "$label"
    fi
}

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

# role|its own database  ('-' = owns nothing)
OWNERS='crm_svc|crm_db
allocation_key_svc|allocation_key_local
simulation_key_svc|simulation_key_local
news_board_svc|news_board_local
billing_svc|billing_local
administrative_document_svc|administrative_document_local
notification_dispatch_svc|-'

LOCAL_DBS='allocation_key_local simulation_key_local news_board_local billing_local administrative_document_local'

# Every role that reaches crm_db.
CRM_CONSUMERS='allocation_key_svc simulation_key_svc news_board_svc billing_svc administrative_document_svc notification_dispatch_svc'

# ---------------------------------------------------------------------------
echo
echo 'A. Cross-database reachability — must FAIL'
echo '   REVOKE CONNECT ... FROM PUBLIC in 10-databases.sql is the line under test.'
while IFS='|' read -r role own; do
    if [ -z "$role" ]; then continue; fi
    pw=$(pw_for "$role")
    for db in $LOCAL_DBS; do
        if [ "$db" = "$own" ]; then continue; fi
        run fail "$role" "$pw" "$db" 'SELECT 1' "$role -> $db"
    done
done <<EOF
$OWNERS
EOF

# crm_db is the one shared database, so it is NOT in matrix A — every role above
# is granted CONNECT on it by design. What they may DO there is matrix C/D.

# ---------------------------------------------------------------------------
echo
echo 'B. Own database — must SUCCEED (CONNECT + schema CREATE + ownership)'
while IFS='|' read -r role own; do
    if [ -z "$role" ] || [ "$own" = "-" ]; then continue; fi
    pw=$(pw_for "$role")
    run pass "$role" "$pw" "$own" \
        'CREATE TABLE _verify_owner (x int); DROP TABLE _verify_owner;' \
        "$role owns $own"
done <<EOF
$OWNERS
EOF

# ---------------------------------------------------------------------------
echo
echo 'C. crm_db reads — must SUCCEED (the read-only CRM port)'
for role in $CRM_CONSUMERS; do
    pw=$(pw_for "$role")
    run pass "$role" "$pw" crm_db 'SELECT count(*) FROM community' "$role reads community"
done

# ---------------------------------------------------------------------------
echo
echo 'D. crm_db writes — must FAIL'
echo '   NOTE: the UPDATE is bounded by WHERE id = -1. §5.8 spells it'
echo '   `UPDATE community SET name = name`, which rewrites EVERY row if the'
echo '   grant is wrongly present — an unbounded write run to prove writes are'
echo '   impossible. Privilege is checked at executor-init regardless of'
echo '   matching rows, so the bounded form proves exactly the same thing.'
for role in $CRM_CONSUMERS; do
    pw=$(pw_for "$role")
    run fail "$role" "$pw" crm_db \
        'UPDATE community SET name = name WHERE id = -1' "$role UPDATE community"
    run fail "$role" "$pw" crm_db \
        'DELETE FROM audit_log WHERE id = -1' "$role DELETE audit_log"
    run fail "$role" "$pw" crm_db \
        "INSERT INTO community (name) VALUES ('_verify_should_fail')" "$role INSERT community"
    run fail "$role" "$pw" crm_db \
        'CREATE TABLE _verify_crm (x int)' "$role CREATE TABLE in crm_db"
done

echo
echo '   ... and each narrow grant absent from every role that must not have it'
for role in allocation_key_svc simulation_key_svc notification_dispatch_svc; do
    pw=$(pw_for "$role")
    run fail "$role" "$pw" crm_db \
        "INSERT INTO notification (id_user, type) VALUES (1, '_verify')" \
        "$role INSERT notification"
done
for role in allocation_key_svc simulation_key_svc news_board_svc billing_svc administrative_document_svc; do
    pw=$(pw_for "$role")
    run fail "$role" "$pw" crm_db \
        'UPDATE outbound_message SET status = status WHERE id = -1' \
        "$role UPDATE outbound_message"
    run fail "$role" "$pw" crm_db \
        "INSERT INTO email_suppression (email, reason) VALUES ('_verify@example.invalid', 4)" \
        "$role INSERT email_suppression"
done
for role in simulation_key_svc news_board_svc billing_svc administrative_document_svc notification_dispatch_svc; do
    pw=$(pw_for "$role")
    run fail "$role" "$pw" crm_db \
        "INSERT INTO allocation_key (name, description, id_community) VALUES ('_verify', '_verify', 1)" \
        "$role INSERT allocation_key"
done
run fail notification_dispatch_svc "$(pw_for notification_dispatch_svc)" crm_db \
    "INSERT INTO audit_log (action, source, entity_type) VALUES ('_verify', '_verify', '_verify')" \
    'notification_dispatch_svc INSERT audit_log'

# ---------------------------------------------------------------------------
echo
printf 'isolation: %s passed, %s failed\n' "$PASSED" "$FAILED"
if [ "$FAILED" -ne 0 ]; then
    echo 'ISOLATION IS NOT PROVEN — do not repoint any service.'
    exit 1
fi
echo 'isolation proven.'
exit 0
