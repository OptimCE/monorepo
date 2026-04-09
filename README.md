/!\ This repo is still subject to major changes.

# CRM Deployment

This project contains the Docker Compose configuration to deploy the CRM application with all its services.

## Architecture

The application includes the following services:
- **crm-frontend**: User interface
- **crm-backend**: Backend API
- **crm-database**: PostgreSQL database for the CRM
- **keycloak**: Authentication server
- **keycloak-db**: PostgreSQL database for Keycloak
- **openfiles**: File management service
- **jaeger**: Distributed tracing (OpenTelemetry)
- **krakend**: API Gateway
- **reverse-proxy**: Nginx reverse proxy

## Prerequisites

- Docker
- Docker Compose

## Configuration

### Environment Variables

Before starting the application, make sure to configure the `.env.dev` file with the appropriate environment variables, particularly the passwords:

```bash
# Modify passwords in .env.dev
DB_PASSWORD=changeme_db_password
KEYCLOAK_DB_PASSWORD=changeme_keycloak_db_password
KEYCLOAK_ADMIN_PASSWORD=changeme_keycloak_admin_password
```

### Database Initialization

The CRM database is initialized via an SQL script on the first startup:

- **CRM Database**: `crm-backend/database_script/init.sql`

For Keycloak, the `keycloak/dev-config.json` file is responsible for initializing a base realm.

⚠️ **Important**: The databases **are not persistent**. Data will be lost every time the containers are restarted. This configuration is suitable for development and testing.

If you want to modify the database schema, edit the corresponding SQL files before starting the services.

## Configuration Generation

Some configurations are generated automatically via the `init` profile services:

- `swagger-doc-gen`: generates `./krakend/config/swagger.yaml`
- `krakend-config`: generates `./krakend/config/krakend.json`
- `crm-frontend-config`: generates `./crm-frontend-config/config.json`

To only run the configuration generation:

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile init up --build
```

When the `init` profile containers have finished, you can stop them with:

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile init down
```

Then, start the full stack normally.

## Running

### Recommended Wrapper

A wrapper is available to control the full stack with the Docker Compose `init` and `dev` profiles: `./docker-stack.sh`.

If needed, make it executable:

```bash
chmod +x ./docker-stack.sh
```

Main commands:

```bash
./docker-stack.sh start
./docker-stack.sh stop
./docker-stack.sh restart
```

The flow automatically executes:

1. the `init` profile to generate configurations
2. stopping the `init` profile
3. starting the `dev` profile in detached mode

With `--skip-init`, the script skips the `init` steps and starts the `dev` profile directly.

Available options for `start` and `restart`:

```bash
./docker-stack.sh start --no-pull
./docker-stack.sh start --no-build
./docker-stack.sh start --build
./docker-stack.sh start --skip-init
```

Available options for `start`, `stop`, and `restart`:

```bash
./docker-stack.sh start -s swagger-doc-gen
./docker-stack.sh stop --service krakend
./docker-stack.sh restart -s keycloak
```

With `-s` / `--service`, the wrapper targets only the requested service instead of the entire stack.
For `stop`, this executes a `docker compose stop <service>`.

Wrapper behavior:

- Automatically detects `docker-compose` or `docker compose`
- Checks that the Docker service is running
- Runs the `init` profile (configuration generation), then stops it, unless `--skip-init` is used
- Runs the `dev` profile in detached mode
- Uses `.env.dev` and `docker-compose.dev.yml`

This script is the recommended method for standard start/stop/restart operations.
### Starting Services Manually
To start all services, use the following command:

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev up
```

To run in detached mode (background):

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev up -d
```

To rebuild the images before starting:

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev up --build
```

### Stopping Services Manually

To stop all services:

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev down
```

To completely reset the databases, stop and remove the containers:

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev down
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev up
```

The initialization scripts will be re-executed automatically on the next startup.

## Accessing Services

| Service | Host Port | Container Port | Protocol | Usage |
|---|---:|---:|---|---|
| `crm-database` | `8080` | `5432` | `tcp` | PostgreSQL CRM |
| `keycloak-db` | `8081` | `5432` | `tcp` | PostgreSQL Keycloak |
| `keycloak` | `8082` | `8080` | `tcp` | Keycloak Authentication |
| `openfiles` | `8083` | `8001` | `tcp` | File service |
| `jaeger` | `8085` | `16686` | `tcp` | Jaeger UI |
| `jaeger` | `8084` | `6831` | `udp` | Jaeger Collector |
| `krakend` | `8086` | `8080` | `tcp` | API Gateway |
| `reverse-proxy` | `8087` | `80` | `tcp` | HTTP reverse proxy |
| `reverse-proxy` | `8088` | `443` | `tcp` | HTTPS reverse proxy |
| `crm-backend` | `8089` | `80` | `tcp` | Backend API |
| `crm-frontend` | `8090` | `80` | `tcp` | Frontend interface |