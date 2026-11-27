#!/usr/bin/env bash
#
# The byte-identity gate for the data-export contract (contracts/export/README.md).
#
# The schemas and the Python export-handler-kit live once, in contracts/export/, and are COPIED
# into every service, because a submodule's CI cannot see the monorepo root:
#
#   contracts/export/schemas/                  -> crm-backend/assets/export/schemas/
#                                                 contracts/export/python/core/export/schemas/
#                                                 <annexe>/core/export/schemas/   (with the kit)
#   contracts/export/python/core/export/       -> <annexe>/core/export/
#   contracts/export/python/tests/export_kit/  -> <annexe>/tests/export_kit/
#
# A copy that drifts is a second contract. This script fails on any difference, in either
# direction (a file missing from the copy, or an extra one in it). Nothing runs it automatically:
# run it by hand before committing a change to the contract or the kit.
#
#   ./scripts/check-export-parity.sh
#
# To adopt the kit in a new annexe: copy both directories, then add the annexe to PY_ADOPTERS.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

REF_SCHEMAS="contracts/export/schemas"
REF_KIT="contracts/export/python/core/export"
REF_KIT_TESTS="contracts/export/python/tests/export_kit"

SCHEMA_COPIES=(
  "crm-backend/assets/export/schemas"
  "$REF_KIT/schemas"
)
# Annexes that carry the Python kit (core/export + tests/export_kit). Grows with phase 6.
PY_ADOPTERS=(
  "signature"
  "administrative-document"
  "billing"
  "news-board"
  "simulation-key"
  "allocation-key-generation"
  "live-data"
)

status=0

listing() {
  (cd "$1" && find . -type f -not -path '*/__pycache__/*' -not -name '*.pyc' | LC_ALL=C sort)
}

compare_tree() {
  local reference="$1" copy="$2"
  if [ ! -d "$copy" ]; then
    echo "MISSING: $copy/"
    status=1
    return
  fi
  local ref_files copy_files
  ref_files="$(listing "$reference")"
  copy_files="$(listing "$copy")"
  if [ "$ref_files" != "$copy_files" ]; then
    echo "FILE SET DIFFERS: $copy vs $reference"
    diff <(echo "$ref_files") <(echo "$copy_files") | sed 's/^/    /'
    status=1
  fi
  local file
  while IFS= read -r file; do
    [ -f "$copy/$file" ] || continue
    # --strip-trailing-cr: submodules are checked out with core.autocrlf=true on Windows, so a
    # copy can differ from its LF reference in the working tree while being identical in git.
    if ! diff -u --strip-trailing-cr "$reference/$file" "$copy/$file" >/dev/null; then
      echo "DRIFT:   $copy/${file#./} (vs $reference)"
      diff -u --strip-trailing-cr "$reference/$file" "$copy/$file" | head -20 | sed 's/^/    /'
      status=1
    fi
  done <<<"$ref_files"
}

for copy in "${SCHEMA_COPIES[@]}"; do
  compare_tree "$REF_SCHEMAS" "$copy"
done

if [ "${#PY_ADOPTERS[@]}" -eq 0 ]; then
  echo "note: no annexe carries the Python kit yet (PY_ADOPTERS is empty)"
fi
for annexe in "${PY_ADOPTERS[@]}"; do
  compare_tree "$REF_KIT" "$annexe/core/export"
  compare_tree "$REF_KIT_TESTS" "$annexe/tests/export_kit"
done

if [ "$status" -eq 0 ]; then
  echo "export parity OK: ${#SCHEMA_COPIES[@]} schema copies, ${#PY_ADOPTERS[@]} Python adopter(s)"
fi
exit "$status"
