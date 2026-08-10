#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="./docker-compose.dev.yml"
ENV_FILE="./.env.dev"
PULL_IMAGES=false
BUILD_IMAGES=true
SKIP_INIT=false
TARGET_SERVICE=""

usage() {
    cat <<'EOF'
Usage: ./docker-stack.sh <command> [options]

Commands:
    start      Run init profile (build theme), then start dev profile
    stop       Stop and remove init/dev profiles
    restart    Stop then start (does not pull images by default)
    verify     Prove the database isolation and the CRM grants (see postgres/)
    help       Show this help message

Options (for start):
    --pull                     Pull images before starting (not default for start)
    --build                    Force build before starting (default: enabled)
    --no-build                 Skip build before starting
    --skip-init                Skip init profile and start dev profile directly

Options (for restart):
    --pull                     Pull images before starting
    --build                    Force build before starting (default: enabled)
    --no-build                 Skip build before starting

Options (for start/stop/restart):
    -s, --service <name>       Target a specific service instead of the full stack
EOF
}

resolve_compose_cmd() {
    if command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD=(docker-compose)
        echo "Docker Compose detected: docker-compose"
        return
    fi

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD=(docker compose)
        echo "Docker Compose detected: docker compose"
        return
    fi

    echo "Docker Compose is not installed."
    exit 1
}

check_docker_service() {
    if ! systemctl is-active --quiet docker; then
        echo "Docker service is not active."
        exit 1
    fi
    echo "Docker service is active."
}

compose() {
    "${DOCKER_COMPOSE_CMD[@]}" "$@"
}

set_target_service_from_option() {
    local option_name="$1"
    local option_value="${2:-}"

    if [ -z "$option_value" ]; then
        echo "Missing value for $option_name"
        usage
        exit 1
    fi

    TARGET_SERVICE="$option_value"
}

start_stack() {
    check_docker_service

    if [ -n "$TARGET_SERVICE" ]; then
        if [ "$PULL_IMAGES" = true ]; then
            compose -f "$COMPOSE_FILE" --profile dev --env-file "$ENV_FILE" pull "$TARGET_SERVICE"
        fi

        echo "Starting service '$TARGET_SERVICE'..."
        if [ "$BUILD_IMAGES" = true ]; then
            compose -f "$COMPOSE_FILE" --profile dev --env-file "$ENV_FILE" up -d --build --remove-orphans "$TARGET_SERVICE"
        else
            compose -f "$COMPOSE_FILE" --profile dev --env-file "$ENV_FILE" up -d --remove-orphans "$TARGET_SERVICE"
        fi
        return
    fi

    if [ "$PULL_IMAGES" = true ]; then
        compose -f "$COMPOSE_FILE" --profile init --profile dev pull
    fi

    # `run --rm` per one-shot, NOT `up --abort-on-container-exit`.
    #
    # --abort-on-container-exit tears the whole init profile down the moment the FIRST
    # container exits. The three envsubst services finish in ~0.3s, and that starts a
    # 10s `docker stop` clock on everything else. Every container here is PID 1 with no
    # SIGTERM handler, and Linux ignores an unhandled SIGTERM sent to PID 1, so they all
    # just keep running to the deadline: the Python doc-gens happen to finish inside the
    # window, swagger-doc-gen (npx tsx over the whole crm-backend TS project) does not
    # and takes the SIGKILL at 137. krakend-config's service_completed_successfully gate
    # then fails and krakend.json is silently left stale.
    #
    # This form was the more dangerous of the two wrappers: with no --exit-code-from,
    # compose sources the exit status from the first container to exit — keycloak-config,
    # which exits 0 — so the failure could return success and start the dev profile
    # against a stale gateway config.
    #
    # `run` has no cascade and exits with the container's own code (the same contract
    # verify_stack below already relies on). krakend-config still pulls in the six
    # doc-gens through its depends_on and still gates on each completing successfully,
    # so a genuine generation failure is still loud.
    if [ "$SKIP_INIT" = false ]; then
        echo "Running init profile..."
        if [ "$BUILD_IMAGES" = true ]; then
            compose -f "$COMPOSE_FILE" --profile init --env-file "$ENV_FILE" build
        fi

        compose -f "$COMPOSE_FILE" --profile init --env-file "$ENV_FILE" run --rm -T keycloak-config
        compose -f "$COMPOSE_FILE" --profile init --env-file "$ENV_FILE" run --rm -T nginx-config
        compose -f "$COMPOSE_FILE" --profile init --env-file "$ENV_FILE" run --rm -T crm-frontend-config
        compose -f "$COMPOSE_FILE" --profile init --env-file "$ENV_FILE" run --rm -T krakend-config

        compose -f "$COMPOSE_FILE" --profile init --env-file "$ENV_FILE" down --remove-orphans
    else
        echo "Skipping init profile."
    fi

    echo "Starting dev profile..."
    if [ "$BUILD_IMAGES" = true ]; then
        compose -f "$COMPOSE_FILE" --profile dev --env-file "$ENV_FILE" up -d --build --remove-orphans
    else
        compose -f "$COMPOSE_FILE" --profile dev --env-file "$ENV_FILE" up -d --remove-orphans
    fi
}

verify_stack() {
    # Runs both scripts inside the postgres-init image, so no psql is needed on
    # the host and all seven role passwords come from the environment compose
    # already assembles.
    #
    # MSYS_NO_PATHCONV=1 is not optional under Git Bash on Windows: it would
    # otherwise rewrite /postgres/verify/... into a C:\ path before Docker ever
    # sees it, and the container fails with `stat C:/Program: no such file`.
    local status=0

    echo "Proving database isolation..."
    if ! MSYS_NO_PATHCONV=1 compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" \
        run --rm --no-deps --entrypoint /postgres/verify/isolation.sh postgres-init; then
        status=1
    fi

    echo
    echo "Proving every granted CRM write lands..."
    if ! MSYS_NO_PATHCONV=1 compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" \
        run --rm --no-deps --entrypoint /postgres/verify/positive-writes.sh postgres-init; then
        status=1
    fi

    if [ "$status" -ne 0 ]; then
        echo
        echo "Verification FAILED. See postgres/README.md."
        exit 1
    fi
}

stop_stack() {
    if [ -n "$TARGET_SERVICE" ]; then
        compose -f "$COMPOSE_FILE" --profile dev --env-file "$ENV_FILE" stop "$TARGET_SERVICE"
    else
        compose -f "$COMPOSE_FILE" --profile init --profile dev --env-file "$ENV_FILE" down --remove-orphans
    fi
}

parse_start_options() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --pull)
                PULL_IMAGES=true
                ;;
            --build)
                BUILD_IMAGES=true
                ;;
            --no-build)
                BUILD_IMAGES=false
                ;;
            --skip-init)
                SKIP_INIT=true
                ;;
            -s|--service)
                set_target_service_from_option "$1" "${2:-}"
                shift
                ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
        shift
    done
}

parse_stop_options() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -s|--service)
                set_target_service_from_option "$1" "${2:-}"
                shift
                ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
        shift
    done
}

main() {
    if [ "$#" -lt 1 ]; then
        usage
        exit 1
    fi

    local command="$1"
    shift

    resolve_compose_cmd

    case "$command" in
        start)
            parse_start_options "$@"
            start_stack
            ;;
        stop)
            parse_stop_options "$@"
            stop_stack
            ;;
        restart)
            parse_start_options "$@"
            stop_stack
            start_stack
            ;;
        verify)
            verify_stack
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            echo "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

main "$@"