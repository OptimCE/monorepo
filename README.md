<p align="center">
  <img src="docs/logo.svg" alt="OptimCE logo" width="160">
</p>

# OptimCE

[![Website](https://img.shields.io/badge/Website-optimce.be-2e7d32.svg)](https://www.optimce.be/en/)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![en](https://img.shields.io/badge/lang-en-43a047.svg)](README.md)
[![fr](https://img.shields.io/badge/lang-fr-lightgrey.svg)](docs/README.fr.md)
[![de](https://img.shields.io/badge/lang-de-lightgrey.svg)](docs/README.de.md)
[![nl](https://img.shields.io/badge/lang-nl-lightgrey.svg)](docs/README.nl.md)

OptimCE is an open-source platform for managing renewable energy communities,
built for the Belgian energy-sharing context. It brings together a member CRM,
energy-sharing allocation keys and simulations, invoicing, document generation,
and a community news board, behind a single authenticated web application.
To learn more about the project, visit
[www.optimce.be](https://www.optimce.be/en/).

This repository is the **development monorepo**: it aggregates all OptimCE
services as git submodules and provides the Docker Compose environment to run
the full platform locally. For an example of a production deployment, see
[OptimCE/production](https://github.com/OptimCE/production).

## Repository Structure

Service code lives in the individual repositories, included here as submodules:

| Path | Repository | Description |
|---|---|---|
| `crm-backend/` | [OptimCE/crm-backend](https://github.com/OptimCE/crm-backend) | CRM backend API (Node.js / TypeScript) |
| `crm-frontend/` | [OptimCE/crm-frontend](https://github.com/OptimCE/crm-frontend) | Web interface (Angular) |
| `allocation-key-generation/` | [OptimCE/allocation-key-generation](https://github.com/OptimCE/allocation-key-generation) | Energy-sharing allocation key generation service (Python) |
| `simulation-key/` | [OptimCE/allocation-key-simulation](https://github.com/OptimCE/allocation-key-simulation) | Allocation key simulation service (Python) |
| `billing/` | [OptimCE/billing](https://github.com/OptimCE/billing) | Invoicing service (Python) |
| `document-generation/` | [OptimCE/document-generation](https://github.com/OptimCE/document-generation) | Document generation service (Python) |
| `news-board/` | [OptimCE/news-board](https://github.com/OptimCE/news-board) | Community news board service (Python) |
| `keycloak/kc-groupid-mapper/` | [OptimCE/kc-groupid-mapper](https://github.com/OptimCE/kc-groupid-mapper) | Keycloak mapper adding group information to tokens |
| `keycloak/optimce-keycloak-theme/` | [OptimCE/optimce-keycloak-theme](https://github.com/OptimCE/optimce-keycloak-theme) | Keycloak login theme (Keycloakify) |
| `krakend/swagger2krakend/` | [OptimCE/swagger2krakend](https://github.com/OptimCE/swagger2krakend) | OpenAPI → KrakenD configuration generator (Python) |

The remaining directories hold the orchestration and infrastructure
configuration that belongs to this repository:

| Path | Description |
|---|---|
| `krakend/` | API gateway configuration (generated `krakend.json` and OpenAPI sources) |
| `keycloak/` | Keycloak image build, realm configuration, and providers |
| `nginx/` | Reverse proxy configuration and certificates |
| `crm-frontend-config/` | Generated frontend runtime configuration |
| `reference/` | Shared reference data (e.g. `regulators.json`) |

## Architecture

The development stack (`docker-compose.dev.yml`) runs the following services:

**Applications**
- **crm-frontend**: Angular user interface
- **crm-backend**: CRM backend API
- **allocation-key-generation** (+ worker): allocation key computation
- **simulation-key** (+ worker): energy-sharing simulations
- **billing** (+ worker): invoicing
- **document-generation**: document generation worker
- **optimce-news-board**: community news board

**Databases** (PostgreSQL, one per service)
- **crm-database**, **keycloak-db**, **allocation-key-db**,
  **simulation-key-db**, **news-board-db**, **billing-db**

**Platform**
- **keycloak**: authentication server
- **krakend**: API gateway
- **reverse-proxy**: Nginx reverse proxy, single entry point for the app
- **minio**: S3-compatible object storage
- **nats**: messaging between services and their workers
- **jaeger**: distributed tracing (OpenTelemetry)

**Configuration generation** (`init` profile, run-once containers)
- **swagger-doc-gen**, **generation-doc-gen**, **simulation-doc-gen**,
  **news-doc-gen**, **billing-doc-gen**: collect each service's OpenAPI
  specification
- **krakend-config**, **keycloak-config**, **nginx-config**,
  **crm-frontend-config**: render the gateway, auth, proxy, and frontend
  configuration from templates

## Getting Started

### Prerequisites

- Docker
- Docker Compose
- Git

### Cloning

The services are git submodules, so clone recursively:

```bash
git clone --recurse-submodules https://github.com/OptimCE/monorepo.git
cd monorepo
```

If you already cloned without submodules:

```bash
git submodule update --init --recursive
```

### Environment Variables

Before starting the application, make sure to configure the `.env.dev` file
with the appropriate environment variables, particularly the passwords:

```bash
# Modify passwords in .env.dev
DB_PASSWORD=changeme_db_password
KEYCLOAK_DB_PASSWORD=changeme_keycloak_db_password
KEYCLOAK_ADMIN_PASSWORD=changeme_keycloak_admin_password
```

### Database Initialization

The CRM database is initialized via an SQL script on the first startup:

- **CRM Database**: `crm-backend/database_script/init.sql`

For Keycloak, the `keycloak/dev-config.json` file is responsible for
initializing a base realm.

⚠️ **Important**: The databases **are not persistent**. Data will be lost every
time the containers are restarted. This configuration is suitable for
development and testing.

If you want to modify the database schema, edit the corresponding SQL files
before starting the services.

### Configuration Generation

Some configurations are generated automatically via the `init` profile services
(see [Architecture](#architecture)), for example:

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

A wrapper is available to control the full stack with the Docker Compose `init`
and `dev` profiles: `./docker-stack.sh` (or `docker-stack.bat` on Windows).

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

With `--skip-init`, the script skips the `init` steps and starts the `dev`
profile directly.

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

With `-s` / `--service`, the wrapper targets only the requested service instead
of the entire stack. For `stop`, this executes a `docker compose stop <service>`.

Wrapper behavior:

- Automatically detects `docker-compose` or `docker compose`
- Checks that the Docker service is running
- Runs the `init` profile (configuration generation), then stops it, unless
  `--skip-init` is used
- Runs the `dev` profile in detached mode
- Uses `.env.dev` and `docker-compose.dev.yml`

This script is the recommended method for standard start/stop/restart
operations.

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

The initialization scripts will be re-executed automatically on the next
startup.

## Accessing Services

| Service | Host Port | Container Port | Protocol | Usage |
|---|---:|---:|---|---|
| `allocation-key-generation` | `8002` | `8000` | `tcp` | Allocation key API |
| `simulation-key` | `8003` | `8000` | `tcp` | Simulation API |
| `optimce-news-board` | `8004` | `8000` | `tcp` | News board API |
| `billing` | `8005` | `8000` | `tcp` | Billing API |
| `crm-database` | `8080` | `5432` | `tcp` | PostgreSQL CRM |
| `keycloak-db` | `8081` | `5432` | `tcp` | PostgreSQL Keycloak |
| `keycloak` | `8082` | `8080` | `tcp` | Keycloak Authentication |
| `jaeger` | `8084` | `6831` | `udp` | Jaeger Collector |
| `jaeger` | `8085` | `16686` | `tcp` | Jaeger UI |
| `krakend` | `8086` | `8080` | `tcp` | API Gateway |
| `reverse-proxy` | `8087` | `80` | `tcp` | HTTP reverse proxy |
| `reverse-proxy` | `8088` | `443` | `tcp` | HTTPS reverse proxy |
| `crm-backend` | `8089` | `80` | `tcp` | Backend API |
| `crm-frontend` | `8090` | `80` | `tcp` | Frontend interface |
| `minio` | `8091` | `9000` | `tcp` | MinIO API |
| `minio` | `8092` | `9001` | `tcp` | MinIO Console |
| `allocation-key-db` | `8093` | `5432` | `tcp` | PostgreSQL allocation keys |
| `nats` | `8094` | `4222` | `tcp` | NATS client |
| `nats` | `8095` | `8222` | `tcp` | NATS monitoring |
| `simulation-key-db` | `8096` | `5432` | `tcp` | PostgreSQL simulation |
| `news-board-db` | `8097` | `5432` | `tcp` | PostgreSQL news board |
| `billing-db` | `8098` | `5432` | `tcp` | PostgreSQL billing |

## Contributing

Contributions are welcome! Please read the
[contributing guidelines](CONTRIBUTING.md) and our
[Code of Conduct](CODE_OF_CONDUCT.md) before opening an issue or pull request.

## Security

To report a security vulnerability, please follow the
[security policy](SECURITY.md) — do not open a public issue.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
