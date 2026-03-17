#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="./docker-compose.dev.yml"
ENV_FILE="./.env.dev"
PULL_IMAGES=true
BUILD_IMAGES=true

usage() {
    cat <<'EOF'
Usage: ./docker-stack.sh <command> [options]

Commands:
    start      Pull/build (optional), run init profile, then start dev profile
    stop       Stop and remove init/dev profiles
    restart    Stop then start
    help       Show this help message

Options (for start/restart):
    --no-pull                  Skip image pull before starting
    --build                    Force build before starting (default: enabled)
    --no-build                 Skip build before starting
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

start_stack() {
    check_docker_service

    if [ "$PULL_IMAGES" = true ]; then
        compose -f "$COMPOSE_FILE" --profile init --profile dev pull
    fi

    echo "Running init profile..."
    if [ "$BUILD_IMAGES" = true ]; then
        compose -f "$COMPOSE_FILE" --profile init --env-file "$ENV_FILE" up --build --abort-on-container-exit --remove-orphans
    else
        compose -f "$COMPOSE_FILE" --profile init --env-file "$ENV_FILE" up --abort-on-container-exit --remove-orphans
    fi

    compose -f "$COMPOSE_FILE" --profile init --env-file "$ENV_FILE" down --remove-orphans

    echo "Starting dev profile..."
    if [ "$BUILD_IMAGES" = true ]; then
        compose -f "$COMPOSE_FILE" --profile dev --env-file "$ENV_FILE" up -d --build --remove-orphans
    else
        compose -f "$COMPOSE_FILE" --profile dev --env-file "$ENV_FILE" up -d --remove-orphans
    fi
}

stop_stack() {
    compose -f "$COMPOSE_FILE" --profile init --profile dev --env-file "$ENV_FILE" down --remove-orphans
}

parse_start_options() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --no-pull)
                PULL_IMAGES=false
                ;;
            --build)
                BUILD_IMAGES=true
                ;;
            --no-build)
                BUILD_IMAGES=false
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
            stop_stack
            ;;
        restart)
            parse_start_options "$@"
            stop_stack
            start_stack
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