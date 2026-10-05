#!/usr/bin/env bash
#
# Does the RUNNING IMAGE actually contain the realtime publisher?
#
# `check-realtime-parity.sh` next door compares SOURCE TREES. It was green
# throughout a three-day outage in which four worker containers ran images built
# before the feature existed: `core/realtime/` was absent, and so were the emit
# call sites, so `generation.finished`, `simulation.finished` and
# `billing_run.finished` were published by nothing at all. The e2e hub scenario
# passed too — it converged on its 20s safety poll instead of push, which is
# indistinguishable from success unless you are watching the bus.
#
# The trap that produced it, and the reason this script exists:
#
#     docker compose up -d --force-recreate <service>
#
# recreates the container from the EXISTING image. Compose re-reads the
# environment, so REALTIME_REDIS_URL duly appeared and it read as a successful
# deploy — while the code was three days old. A producer deploy needs --build.
# Note that every producer carries REALTIME_REDIS_URL unconditionally, so the
# environment is never the signal here. Only code presence is.
#
#   ./scripts/check-realtime-images.sh
#
# Exits non-zero if any producer is stopped or its image predates the feature.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

# Git Bash on Windows rewrites POSIX-looking arguments into Windows paths before
# exec'ing, so `/app/core/realtime/bus.py` reaches the container as
# `C:/Program Files/Git/app/core/realtime/bus.py` and every probe fails. Without
# this the script reports all nine producers STALE on a perfectly healthy stack —
# and a guard that cries wolf gets switched off, which is worse than not having
# one. Harmless on Linux and macOS, where both variables are simply unused.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

DC="docker compose --env-file .env.dev -f docker-compose.dev.yml"

# Every compose service that must be able to PUBLISH — api and worker alike.
#
# `optimce-news-board` is the odd name (the directory is `news-board`) and has no
# worker at all. `document-generation` and `notification-dispatch` are absent on
# purpose: they are not producers, for the reasons given in
# check-realtime-parity.sh. crm-backend is the CONSUMER (the hub) and is checked
# by its own startup log, not here.
PRODUCERS=(
  allocation-key-generation
  allocation-key-generation-worker
  simulation-key
  simulation-key-worker
  optimce-news-board
  billing
  billing-worker
  administrative-document
  administrative-document-worker
)

status=0
stale=()

# Two assertions, both against the container filesystem rather than the repo.
#
# Deliberately NOT `python -c "import core.realtime"`: bus.py imports
# redis.asyncio and constructs Settings(), so an ImportError would conflate
# "files missing" with "dependency missing" with "environment invalid" — three
# very different problems with one exit code.
#
# The grep is generic rather than a per-service file map because
# administrative-document-worker has NO direct emit (its path is transitive via
# worker/sweeps.py -> api/.../service.py -> core/notifications/service.py) and
# optimce-news-board has no worker, so probing worker/persistence.py would
# false-fail both.
check() {
  local service="$1" container

  container=$($DC ps --status running -q "$service" 2>/dev/null)
  if [ -z "$container" ]; then
    # A stopped container must never report clean: an `exec` against it fails,
    # and a naive script would read that failure as "nothing to see here".
    echo "STOPPED:  $service (cannot verify — start it first)"
    status=1
    return
  fi

  if ! $DC exec -T "$service" test -f /app/core/realtime/bus.py 2>/dev/null; then
    echo "STALE:    $service (no /app/core/realtime — image predates the feature)"
    stale+=("$service")
    status=1
    return
  fi

  if ! $DC exec -T "$service" \
    grep -rlq "from core.realtime import" /app --include=*.py 2>/dev/null; then
    echo "STALE:    $service (package present but nothing imports it — emit call sites missing)"
    stale+=("$service")
    status=1
    return
  fi

  echo "OK:       $service"
}

for service in "${PRODUCERS[@]}"; do
  check "$service"
done

if [ $status -eq 0 ]; then
  echo "realtime images: OK (${#PRODUCERS[@]} producers)"
else
  echo
  if [ ${#stale[@]} -gt 0 ]; then
    echo "Producers are running pre-feature images. Rebuild them:"
    echo
    echo "  docker compose --env-file .env.dev -f docker-compose.dev.yml \\"
    echo "    up -d --build ${stale[*]}"
    echo
    echo "--force-recreate is NOT enough — it reuses the existing image."
  else
    echo "Start the stopped producers, then run this again."
  fi
fi
exit $status
