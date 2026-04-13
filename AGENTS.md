# DevOps Notes

## Context
This repo is the development monorepo, it uses git submodules to centralize all the content of the project and orchestrate a development environment to ease the testing development loop.

The app developed here is a classic nodeJS backend + Angular frontend with authentication managed by keycloak.

## Stack Management

Use `docker-stack.sh` to manage the CRM stack:
- `./docker-stack.sh start` - Start all services (automatically builds keycloakify theme)
- `./docker-stack.sh stop` - Stop all services
- `./docker-stack.sh restart` - Restart all services
- `./docker-stack.sh start --no-pull` - Start without pulling images
- `./docker-stack.sh start --skip-theme` - Start without rebuilding keycloakify theme
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

### Keycloakify Theme

Custom Keycloak login theme built with Keycloakify, styled with CRM branding (green `#43a047`, DM Sans font).

**Location:** `keycloakify/`

**Build:** The theme is automatically built during `./docker-stack.sh start` via `keycloakify/Dockerfile`.

**Key files:**
- `keycloakify/src/login/main.css` - Custom CRM styling
- `keycloakify/src/login/KcPage.tsx` - Login page React component
- `keycloakify/index.html` - HTML template with font imports

**Testing the theme:**
```bash
# After starting the stack, open the login page:
open "http://localhost:8082/keycloak/realms/optimce-realm/login-actions/authenticate?client_id=optimce-frontend&redirect_uri=http%3A%2F%2Flocalhost%3A8087%2F&response_type=code&scope=openid"

# Or go to the frontend login:
open http://localhost:8087
```

**Making CSS changes:**
1. Edit `keycloakify/src/login/main.css`
2. Run `./docker-stack.sh start` to rebuild the theme
3. The theme JAR is built via `keycloakify/Dockerfile` and deployed to `keycloak/providers/`

