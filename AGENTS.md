# DevOps Notes

## Context
This repo is the development monorepo, it uses git submodules to centralize all the content of the project and orchestrate a development environment to ease the testing development loop.

The app developed here is a classic nodeJS backend + Angular frontend with authentication managed by keycloak.

## Stack Management

Use `docker-stack.sh` to manage the CRM stack:
- `./docker-stack.sh start` - Start all services
- `./docker-stack.sh stop` - Stop all services
- `./docker-stack.sh restart` - Restart all services
- `./docker-stack.sh start --no-pull` - Start without pulling images
- `./docker-stack.sh start -s swagger-doc-gen` - Start only one service
- `./docker-stack.sh stop -s krakend` - Stop only one service
- `./docker-stack.sh restart -s keycloak` - Restart only one service

## Key Files

- `docker-compose.dev.yml` - Dev environment orchestration file
- `.env.dev` - Dev environment variables
- `docker-stack.sh` - Wrapper script for docker-compose
- `keycloak/dev-config.json` - Keycloak realm configuration (dev)
- `keycloak/realm-export.json` - Full Keycloak realm export (reference)
- `krakend/config/krakend.json` - KrakenD API gateway configuration
- `nginx/conf.d/default.conf` - Reverse proxy configuration
- `nginx/conf.d.proxy-common-header.conf` - Common configuration for service behind nginx
- `crm-frontend-config/config.json` - Frontend runtime config

### Docker image

- `crm-backend` - Backend api of the app
- `crm-frontend` - Angular interface to interact with the api
- `krakend/swagger2krakend` - Python parser translating yaml openapi file to krakend config file
- `keycloak/kc-groupid-mapper` - Keycloak + addons to add additional group info to the backend

