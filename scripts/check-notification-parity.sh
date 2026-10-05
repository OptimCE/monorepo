#!/usr/bin/env bash
#
# The byte-identity gate for the shared notification package
# (IMPLEMENTATION_PLAN.md §1.8).
#
# `core/notifications/{__init__,contract,dedupe,repository,service}.py` and
# `shared/models/crm_notification_models.py` are byte-identical across every
# producer. That is not tidiness: it is the entire reason Phase 2's extraction
# is a `git mv` of six files plus a swap of two method bodies, rather than a
# rewrite of four services. `types.py` is the ONLY per-service module.
#
# Nothing enforces this at the language level and no single service's CI can see
# its siblings, so it lives here, at the monorepo root, and has to be run by
# hand or from a monorepo-level job.
#
#   ./scripts/check-notification-parity.sh
#
# Exits non-zero and prints the diff on any drift.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

REFERENCE="news-board"
# notification-dispatch carries contract.py only: it is a CONSUMER of the queue,
# so importing the producer-side service/repository would invert the dependency.
# It still shares the contract because `Channel.INAPP = 1 / EMAIL = 2` is an
# on-disk encoding, and a second definition of it is a second source of truth.
PRODUCERS=(billing administrative-document)
CONSUMERS=(notification-dispatch)

SHARED_FILES=(
  core/notifications/__init__
  core/notifications/contract
  core/notifications/dedupe
  core/notifications/repository
  core/notifications/service
  shared/models/crm_notification_models
)
CONTRACT_ONLY=(core/notifications/contract)

status=0

check() {
  local reference="$1" other="$2" file="$3"
  if [ ! -f "$other/$file.py" ]; then
    echo "MISSING: $other/$file.py"
    status=1
    return
  fi
  # --strip-trailing-cr: administrative-document is checked out with
  # core.autocrlf=true, so on Windows every shared file differs from its LF
  # sibling in the working tree while being byte-identical in git. Without this
  # the gate is unrunnable locally and only ever green in CI.
  if ! diff -u --strip-trailing-cr "$reference/$file.py" "$other/$file.py"; then
    echo "DRIFT:   $file.py ($other vs $reference)"
    status=1
  fi
}

for file in "${SHARED_FILES[@]}"; do
  for service in "${PRODUCERS[@]}"; do
    check "$REFERENCE" "$service" "$file"
  done
done

for file in "${CONTRACT_ONLY[@]}"; do
  for service in "${CONSUMERS[@]}"; do
    check "$REFERENCE" "$service" "$file"
  done
done

if [ $status -eq 0 ]; then
  echo "notification parity: OK (${#SHARED_FILES[@]} files across $((${#PRODUCERS[@]} + 1)) producers)"
else
  echo
  echo "The shared notification package has drifted. Fix by making the change in"
  echo "$REFERENCE and copying it out — not by editing each copy."
fi
exit $status
