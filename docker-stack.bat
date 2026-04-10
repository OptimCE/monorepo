@echo off
setlocal enabledelayedexpansion

rem ===== Defaults =====
set "COMPOSE_FILE=.\docker-compose.dev.yml"
set "ENV_FILE=.\.env.dev"
set "PULL_IMAGES=true"
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

echo Unknown command: %COMMAND%
call :usage
exit /b 1

rem ===================================================================
rem Start / Restart argument parsing
rem ===================================================================
:parse_start
if "%~1"=="" goto :parse_start_done
if /i "%~1"=="--no-pull"   ( set "PULL_IMAGES=false"  & shift & goto :parse_start )
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
echo     start      Pull/build (optional), run init profile, then start dev profile
echo     stop       Stop and remove init/dev profiles
echo     restart    Stop then start
echo     help       Show this help message
echo.
echo Options (for start/restart):
echo     --no-pull                  Skip image pull before starting
echo     --build                    Force build before starting (default: enabled)
echo     --no-build                 Skip build before starting
echo     --skip-init                Skip init profile and start dev profile directly
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

if "%SKIP_INIT%"=="false" (
    echo Running init profile...
    if "%BUILD_IMAGES%"=="true" (
        %DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile init --env-file "%ENV_FILE%" up --build --abort-on-container-exit --remove-orphans || exit /b 1
    ) else (
        %DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile init --env-file "%ENV_FILE%" up --abort-on-container-exit --remove-orphans || exit /b 1
    )
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
:stop_stack
if not "%TARGET_SERVICE%"=="" (
    %DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile dev --env-file "%ENV_FILE%" stop "%TARGET_SERVICE%" || exit /b 1
) else (
    %DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile init --profile dev --env-file "%ENV_FILE%" down --remove-orphans || exit /b 1
)
exit /b 0