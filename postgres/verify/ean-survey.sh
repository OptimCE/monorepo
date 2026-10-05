#!/bin/sh
# ===========================================================================
# Survey every stored EAN against the platform rule: exactly 18 digits.
#
# READ-ONLY. Every statement is a SELECT; nothing is written, locked or
# migrated. Safe against production, and meant to be run there BEFORE anyone
# considers a database CHECK constraint on meter.ean.
#
#     ./docker-stack.sh survey-ean
#
# Runs as the SUPERUSER, unlike isolation.sh and positive-writes.sh, and it has
# to: the isolation those scripts prove means no service role can read more
# than one database, and a survey needs the cross-database view.
#
# EXIT CODES
#   0  every ENFORCED column conforms  -> a CHECK constraint would be safe
#   1  non-conforming rows found       -> report only; do NOT add a constraint
#   2  a probe could not run           -> result unknown, treat as not clean
#
# Only crm_db.meter.ean is ENFORCED. Everything else is reported for context:
#   * meter_data.ean / meter_consumption.ean are FKs to meter.ean and so cannot
#     be worse than it; surveyed as a cheap proof the FKs are intact.
#   * consumer.name is an EAN by CONVENTION only and is free text by design — a
#     manual allocation key legitimately names a consumer "Maison Dupont".
#   * audit_log.entity_id is scoped to entity_type='meter'; for every other
#     entity type it holds a UUID or an integer id, which is not a finding.
#   * billing's settlement_snapshot / invoice_line rows are frozen financial
#     evidence: a bad EAN there is history, not a defect to repair. And
#     tariff.scope_ean is legitimately NULL for GLOBAL and SEGMENT scopes,
#     which is why NULLs are counted separately and never flagged.
#   * live-data's columns are already validated against the CRM at enrolment,
#     so a bad one there mirrors a bad one in the CRM — the CRM row is the
#     finding.
#
# JSONB snapshots (administrative_document_local.document_version
# .data_snapshot_json) are DELIBERATELY not surveyed: a filed version is
# append-only evidence of what went to the regulator and there is no update
# path, so a finding there would be unactionable.
#
# Every probe is guarded on the database AND the table existing, because
# production runs a strict subset of dev — live_data_local is not deployed
# there at all.
# ===========================================================================
set -u

EAN_RE='^[0-9]{18}$'
GATE_BAD=0
PROBE_FAILED=0
SURVEYED=0
NOTED=0

PSQL="psql --no-psqlrc -qAt -v ON_ERROR_STOP=1"

db_exists() {
    $PSQL -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '$1'" 2>/dev/null | grep -q 1
}

# survey <db> <table> <column> <enforced|reported|info> [sql-predicate]
#
# The optional predicate narrows the rows considered. It exists for columns that
# hold an EAN only for SOME rows — audit_log.entity_id carries a meter's EAN for
# entity_type='meter' and a UUID or an integer id for everything else, so
# surveying it wholesale reports 144 findings that are all correct data. A
# survey that cries wolf gets ignored.
survey() {
    db=$1; table=$2; column=$3; class=$4; scope=${5:-}
    label="$db.$table.$column"
    if [ -n "$scope" ]; then
        where="WHERE $scope"
        label="$label [$scope]"
    else
        where=""
    fi

    if ! db_exists "$db"; then
        printf '  skip  %-50s (database not present)\n' "$label"
        return 0
    fi

    present=$($PSQL -d "$db" -c "SELECT to_regclass('public.$table') IS NOT NULL" 2>/dev/null)
    if [ "$present" != "t" ]; then
        printf '  skip  %-50s (table not present)\n' "$label"
        return 0
    fi

    if ! counts=$($PSQL -F '|' -d "$db" -c "
        SELECT count(*),
               count(*) FILTER (WHERE $column IS NULL),
               count(*) FILTER (WHERE $column IS NOT NULL AND $column !~ '$EAN_RE')
        FROM $table $where" 2>&1); then
        printf '  ERR   %-50s %s\n' "$label" "$counts"
        PROBE_FAILED=1
        return 0
    fi

    total=$(printf '%s' "$counts" | cut -d'|' -f1)
    nulls=$(printf '%s' "$counts" | cut -d'|' -f2)
    bad=$(printf '%s'  "$counts" | cut -d'|' -f3)
    SURVEYED=$((SURVEYED + 1))

    if [ "$bad" = "0" ]; then
        printf '  ok    %-50s %s row(s), %s null, 0 non-conforming\n' "$label" "$total" "$nulls"
        return 0
    fi

    if [ "$class" = "enforced" ]; then
        marker='FAIL '
        GATE_BAD=1
    else
        marker='note '
        NOTED=$((NOTED + 1))
    fi
    printf '  %s %-50s %s row(s), %s null, %s NON-CONFORMING\n' "$marker" "$label" "$total" "$nulls" "$bad"

    # Distinct samples, capped: enough to recognise the shape of the problem
    # (a 13-digit legacy EAN? a stray space? a person's name?) without dumping
    # the table into a log.
    $PSQL -d "$db" -c "
        SELECT DISTINCT $column FROM $table
        ${where:-WHERE TRUE} AND $column IS NOT NULL AND $column !~ '$EAN_RE'
        ORDER BY 1 LIMIT 10" 2>/dev/null | sed 's/^/          /'
    return 0
}

echo
echo 'A. crm_db — the source of truth (ENFORCED)'
survey crm_db meter             ean  enforced

echo
echo 'B. crm_db — FK children, should mirror meter.ean'
survey crm_db meter_data        ean  reported
survey crm_db meter_consumption ean  reported

echo
echo 'C. crm_db — EAN by convention only, free text by design'
survey crm_db consumer   name      info
survey crm_db audit_log  entity_id info "entity_type = 'meter'"

echo
echo 'D. billing_local — frozen financial records'
survey billing_local tariff              scope_ean info
survey billing_local settlement_snapshot ean       reported
survey billing_local invoice_line        ean       reported

echo
echo 'E. live_data_local — CRM-validated at enrolment'
survey live_data_local device              ean info
survey live_data_local device_owner_window ean info
survey live_data_local forecast_production ean info

echo
echo 'F. annexe key results — generated output'
survey allocation_key_local consumer_generated         name info
survey simulation_key_local simulation_consumer_result name info

echo
printf 'ean-survey: %s column(s) surveyed, %s informational finding(s)\n' "$SURVEYED" "$NOTED"

if [ "$PROBE_FAILED" -ne 0 ]; then
    echo 'SURVEY INCOMPLETE — a probe failed. Do not treat this as clean.'
    exit 2
fi
if [ "$GATE_BAD" -ne 0 ]; then
    echo
    echo 'crm_db.meter.ean has non-conforming rows.'
    echo 'Do NOT apply an 18-digit CHECK constraint. Postgres re-evaluates a CHECK'
    echo 'on every UPDATE of the row (NOT VALID included), so it would make each'
    echo 'of those meters read-only — and nothing in the platform can rewrite a'
    echo 'meter EAN, so the only remedy left would be DELETE, which cascades the'
    echo "meter's whole consumption history away."
    exit 1
fi
echo 'Every enforced EAN column conforms. An 18-digit CHECK on meter.ean is safe.'
exit 0
