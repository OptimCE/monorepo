@echo off
setlocal enabledelayedexpansion

rem ===== Defaults =====
set "COMPOSE_FILE=.\docker-compose.dev.yml"
set "ENV_FILE=.\.env.dev"
set "PULL_IMAGES=false"
set "BUILD_IMAGES=true"
set "SKIP_INIT=false"
set "TARGET_SERVICE="
set "DOCKER_COMPOSE_CMD="

if "%~1"=="" goto :usage_exit

set "COMMAND=%~1"
shift

if /i "%COMMAND%"=="help"   goto :usage
if /i "%COMMAND%"=="-h"     goto :usage
if /i "%COMMAND%"=="--help" goto :usage

call :resolve_compose_cmd
if errorlevel 1 exit /b 1

if /i "%COMMAND%"=="start"   goto :parse_start
if /i "%COMMAND%"=="restart" goto :parse_start
if /i "%COMMAND%"=="stop"    goto :parse_stop
if /i "%COMMAND%"=="verify"  goto :run_verify

echo Unknown command: %COMMAND%
call :usage
exit /b 1

rem ===================================================================
rem Start / Restart argument parsing
rem ===================================================================
:parse_start
if "%~1"=="" goto :parse_start_done
if /i "%~1"=="--pull"      ( set "PULL_IMAGES=true"   & shift & goto :parse_start )
if /i "%~1"=="--build"     ( set "BUILD_IMAGES=true"  & shift & goto :parse_start )
if /i "%~1"=="--no-build"  ( set "BUILD_IMAGES=false" & shift & goto :parse_start )
if /i "%~1"=="--skip-init" ( set "SKIP_INIT=true"     & shift & goto :parse_start )
if /i "%~1"=="-s"          goto :parse_start_service
if /i "%~1"=="--service"   goto :parse_start_service
echo Unknown option: %~1
call :usage
exit /b 1
:parse_start_service
if "%~2"=="" (
    echo Missing value for %~1
    call :usage
    exit /b 1
)
set "TARGET_SERVICE=%~2"
shift
shift
goto :parse_start
:parse_start_done
if /i "%COMMAND%"=="restart" (
    call :stop_stack
    if errorlevel 1 exit /b 1
)
call :start_stack
exit /b %errorlevel%

rem ===================================================================
rem Stop argument parsing
rem ===================================================================
:parse_stop
if "%~1"=="" goto :parse_stop_done
if /i "%~1"=="-s"        goto :parse_stop_service
if /i "%~1"=="--service" goto :parse_stop_service
echo Unknown option: %~1
call :usage
exit /b 1
:parse_stop_service
if "%~2"=="" (
    echo Missing value for %~1
    call :usage
    exit /b 1
)
set "TARGET_SERVICE=%~2"
shift
shift
goto :parse_stop
:parse_stop_done
call :stop_stack
exit /b %errorlevel%

rem ===================================================================
:usage
echo Usage: docker-stack.bat ^<command^> [options]
echo.
echo Commands:
echo     start      Run init profile (build theme), then start dev profile
echo     stop       Stop and remove init/dev profiles
echo     restart    Stop then start (does not pull images by default)
echo     verify     Prove the database isolation and the CRM grants (see postgres\)
echo     help       Show this help message
echo.
echo Options (for start):
echo     --pull                     Pull images before starting (not default for start)
echo     --build                    Force build before starting (default: enabled)
echo     --no-build                 Skip build before starting
echo     --skip-init                Skip init profile and start dev profile directly
echo.
echo Options (for restart):
echo     --pull                     Pull images before starting
echo     --build                    Force build before starting (default: enabled)
echo     --no-build                 Skip build before starting
echo.
echo Options (for start/stop/restart):
echo     -s, --service ^<name^>       Target a specific service instead of the full stack
exit /b 0

:usage_exit
call :usage
exit /b 1

rem ===================================================================
:resolve_compose_cmd
where docker-compose >nul 2>&1
if not errorlevel 1 (
    set "DOCKER_COMPOSE_CMD=docker-compose"
    echo Docker Compose detected: docker-compose
    exit /b 0
)
where docker >nul 2>&1
if not errorlevel 1 (
    docker compose version >nul 2>&1
    if not errorlevel 1 (
        set "DOCKER_COMPOSE_CMD=docker compose"
        echo Docker Compose detected: docker compose
        exit /b 0
    )
)
echo Docker Compose is not installed.
exit /b 1

rem ===================================================================
:check_docker_service
docker info >nul 2>&1
if errorlevel 1 (
    echo Docker service is not active.
    exit /b 1
)
echo Docker service is active.
exit /b 0

rem ===================================================================
:start_stack
call :check_docker_service
if errorlevel 1 exit /b 1

if not "%TARGET_SERVICE%"=="" goto :start_single_service

if "%PULL_IMAGES%"=="true" (
    %DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile init --profile dev pull || exit /b 1
)

rem `run --rm` per one-shot, NOT `up --exit-code-from krakend-config`.
rem
rem --exit-code-from implies --abort-on-container-exit, which tears the whole init
rem profile down the moment the FIRST container exits. The three envsubst services
rem finish in ~0.3s, and that starts a 10s `docker stop` clock on everything else.
rem Every container here is PID 1 with no SIGTERM handler, and Linux ignores an
rem unhandled SIGTERM sent to PID 1, so they all just keep running to the deadline:
rem the Python doc-gens happen to finish inside the window, swagger-doc-gen (npx tsx
rem over the whole crm-backend TS project) does not and takes the SIGKILL at 137.
rem krakend-config's service_completed_successfully gate then fails and krakend.json
rem is silently left stale. Rerunning "fixed" it only because a warm cache let
rem swagger-doc-gen fit inside the 10 seconds.
rem
rem `run` has no cascade and exits with the container's own code (the same contract
rem :run_verify below already relies on). krakend-config still pulls in the six
rem doc-gens through its depends_on and still gates on each completing successfully,
rem so a genuine generation failure is still loud.
if "%SKIP_INIT%"=="false" (
    echo Running init profile...
    if "%BUILD_IMAGES%"=="true" (
        %DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile init --env-file "%ENV_FILE%" build || exit /b 1
    )
    %DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile init --env-file "%ENV_FILE%" run --rm -T keycloak-config || exit /b 1
    %DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile init --env-file "%ENV_FILE%" run --rm -T nginx-config || exit /b 1
    %DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile init --env-file "%ENV_FILE%" run --rm -T crm-frontend-config || exit /b 1
    %DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile init --env-file "%ENV_FILE%" run --rm -T krakend-config || exit /b 1
    %DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile init --env-file "%ENV_FILE%" down --remove-orphans || exit /b 1
) else (
    echo Skipping init profile.
)

echo Starting dev profile...
if "%BUILD_IMAGES%"=="true" (
    %DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile dev --env-file "%ENV_FILE%" up -d --build --remove-orphans || exit /b 1
) else (
    %DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile dev --env-file "%ENV_FILE%" up -d --remove-orphans || exit /b 1
)
exit /b 0

:start_single_service
if "%PULL_IMAGES%"=="true" (
    %DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile dev --env-file "%ENV_FILE%" pull "%TARGET_SERVICE%" || exit /b 1
)
echo Starting service '%TARGET_SERVICE%'...
if "%BUILD_IMAGES%"=="true" (
    %DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile dev --env-file "%ENV_FILE%" up -d --build --remove-orphans "%TARGET_SERVICE%" || exit /b 1
) else (
    %DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile dev --env-file "%ENV_FILE%" up -d --remove-orphans "%TARGET_SERVICE%" || exit /b 1
)
exit /b 0

rem ===================================================================
rem Runs both verification scripts inside the postgres-init image, so no psql is
rem needed on the host and all seven role passwords come from the environment
rem compose already assembles. See postgres/README.md.
:run_verify
call :check_docker_service
if errorlevel 1 exit /b 1

set "VERIFY_STATUS=0"

echo Proving database isolation...
%DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --env-file "%ENV_FILE%" run --rm --no-deps --entrypoint /postgres/verify/isolation.sh postgres-init
if errorlevel 1 set "VERIFY_STATUS=1"

echo.
echo Proving every granted CRM write lands...
%DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --env-file "%ENV_FILE%" run --rm --no-deps --entrypoint /postgres/verify/positive-writes.sh postgres-init
if errorlevel 1 set "VERIFY_STATUS=1"

if not "%VERIFY_STATUS%"=="0" (
    echo.
    echo Verification FAILED. See postgres\README.md.
    exit /b 1
)
exit /b 0

rem ===================================================================
:stop_stack
if not "%TARGET_SERVICE%"=="" (
    %DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile dev --env-file "%ENV_FILE%" stop "%TARGET_SERVICE%" || exit /b 1
) else (
    %DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile init --profile dev --env-file "%ENV_FILE%" down --remove-orphans || exit /b 1
)
exit /b 0