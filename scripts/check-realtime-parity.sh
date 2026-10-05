#!/usr/bin/env bash
#
# The byte-identity gate for the shared realtime package.
#
# `core/realtime/{__init__,channels,envelope,bus}.py` is byte-identical across
# every producing service. Unlike the notification package there is no
# per-service module at all: the topic list lives in `envelope.py` and is shared,
# because a topic crm-backend does not know is dropped at the hub rather than
# forwarded — so a service inventing its own would publish into a black hole.
#
# `channels.py` is the one that MUST NOT drift: it is the only place a channel
# string is built, and a producer that publishes a per-user thing onto a
# community tier is a cross-tenant leak. See its module docstring.
#
# Nothing enforces this at the language level and no single service's CI can see
# its siblings, so it lives here, at the monorepo root, and has to be run by hand
# or from a monorepo-level job.
#
#   ./scripts/check-realtime-parity.sh
#
# Exits non-zero and prints the diff on any drift.
#
# SOURCE PARITY IS NOT IMAGE PARITY. This script reads the working tree and
# cannot see what is actually running. It stayed green for three days while four
# worker containers ran images built before this package existed and published
# nothing at all. Pair it with:
#
#   ./scripts/check-realtime-images.sh

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

REFERENCE="news-board"
# Every service that PUBLISHES. notification-dispatch is deliberately absent: its
# outbound_message poll is a durability backstop for email, and realtime is
# at-most-once — it must not grow a dependency on a broker it does not need.
# document-generation is absent too: it is stateless and its terminal state lands
# in the calling service's worker.
PRODUCERS=(billing administrative-document allocation-key-generation simulation-key)

SHARED_FILES=(
  core/realtime/__init__
  core/realtime/channels
  core/realtime/envelope
  core/realtime/bus
)

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

# The channel grammar must exist in exactly one module per service. A literal
# `notify:v1:` anywhere else means someone hand-built a channel and bypassed the
# tier argument, which is how a cross-tenant leak gets written.
for service in "$REFERENCE" "${PRODUCERS[@]}"; do
  # --exclude-dir, not a post-filter: these trees hold tens of thousands of
  # files and the naive version takes minutes.
  offenders=$(grep -rl --include='*.py' \
    --exclude-dir='.venv' --exclude-dir='venv' --exclude-dir='.mypy_cache' \
    --exclude-dir='__pycache__' --exclude-dir='tests' --exclude-dir='test' \
    'notify:v1:' "$service" 2>/dev/null \
    | grep -v "^$service/core/realtime/channels.py$")
  if [ -n "$offenders" ]; then
    echo "HARDCODED CHANNEL in $service:"
    echo "$offenders" | sed 's/^/  /'
    status=1
  fi
done

if [ $status -eq 0 ]; then
  echo "realtime parity: OK (${#SHARED_FILES[@]} files across $((${#PRODUCERS[@]} + 1)) producers)"
else
  echo
  echo "The shared realtime package has drifted. Fix by making the change in"
  echo "$REFERENCE and copying it out — not by editing each copy."
fi
exit $status
