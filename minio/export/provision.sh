#!/bin/bash
#
# Provisions the data-export storage (contracts/export/README.md §4) on a MinIO
# the `local` mc alias already points at. Run by `minio-init` after the other
# buckets; safe to rerun: every step is an upsert.
#
#   - bucket `exports`, private, unversioned;
#   - lifecycle: `parts/` expire after 2 days, `archives/` after 8 (a safety net:
#     the worker deletes both itself, at assembly and at expires_at);
#   - one account per producing service, allowed to write and delete under
#     `parts/*/<service>/` only;
#   - `export-worker`: reads and deletes everything in `exports`, writes
#     `archives/` only, reads the two document buckets it copies references from;
#   - `export-download`: reads `archives/` only, used to sign download URLs.
#
# Each account's secret comes from EXPORT_<NAME>_SECRET (NAME = the account name
# after `export-`, upper-cased, dashes to underscores). A missing secret aborts:
# an account created with an empty or default secret would be worse than none.
#
# Bash, not sh, and no sed/grep/awk: the pgsty/mc image ships bash and coreutils
# only, so templating uses ${var//pattern/replacement}.

set -euo pipefail

BUCKET="${EXPORT_BUCKET:-exports}"
DOCUMENT_BUCKETS="${EXPORT_DOCUMENT_BUCKETS:-crm-files optimce-documents}"
SERVICES="${EXPORT_SERVICE_ACCOUNTS:-crm signature administrative-document billing news-board simulation-key allocation-key-generation live-data}"
HERE="$(dirname "$0")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

secret_for() {
  local name var
  name="$(tr 'a-z-' 'A-Z_' <<<"$1")"
  var="EXPORT_${name}_SECRET"
  if [ -z "${!var:-}" ]; then
    echo "provision-exports: $var is not set; refusing to create export-$1" >&2
    return 1
  fi
  printf '%s' "${!var}"
}

render() {
  # render <template> <output> [@KEY@=value ...]
  local template output text pair
  template="$1"; output="$2"; shift 2
  text="$(cat "$template")"
  text="${text//@BUCKET@/$BUCKET}"
  for pair in "$@"; do
    text="${text//${pair%%=*}/${pair#*=}}"
  done
  printf '%s\n' "$text" > "$output"
}

# `policy attach` fails when the policy is already attached; that is the only
# failure acceptable on a rerun, so check first instead of swallowing errors.
account() {
  local user policy_file secret info
  user="export-$1"
  policy_file="$2"
  secret="$(secret_for "$1")"
  mc admin user add local "$user" "$secret" >/dev/null
  mc admin policy create local "$user" "$policy_file" >/dev/null
  info="$(mc admin user info local "$user" --json)"
  if [[ "$info" != *"\"policyName\":\"$user\""* ]]; then
    mc admin policy attach local "$user" --user "$user" >/dev/null
  fi
  echo "provision-exports: account $user ready"
}

mc mb --ignore-existing "local/$BUCKET"
mc anonymous set none "local/$BUCKET" >/dev/null
mc ilm import "local/$BUCKET" < "$HERE/lifecycle.json" >/dev/null
echo "provision-exports: bucket $BUCKET ready, lifecycle imported"

for svc in $SERVICES; do
  render "$HERE/policies/service.json.tmpl" "$WORK/$svc.json" "@SERVICE@=$svc"
  account "$svc" "$WORK/$svc.json"
done

document_resources=""
for b in $DOCUMENT_BUCKETS; do
  document_resources+="\"arn:aws:s3:::$b/*\", "
done
render "$HERE/policies/worker.json.tmpl" "$WORK/worker.json" "@DOCUMENT_RESOURCES@=${document_resources%, }"
account worker "$WORK/worker.json"

render "$HERE/policies/download.json.tmpl" "$WORK/download.json"
account download "$WORK/download.json"
