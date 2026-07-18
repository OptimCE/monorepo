<p align="center">
  <img src="logo.svg" alt="OptimCE-logo" width="160">
</p>

# OptimCE

[![Website](https://img.shields.io/badge/Website-optimce.be-2e7d32.svg)](https://www.optimce.be/nl/)
[![Licentie](https://img.shields.io/badge/Licentie-Apache%202.0-blue.svg)](../LICENSE)
[![en](https://img.shields.io/badge/lang-en-lightgrey.svg)](../README.md)
[![fr](https://img.shields.io/badge/lang-fr-lightgrey.svg)](README.fr.md)
[![de](https://img.shields.io/badge/lang-de-lightgrey.svg)](README.de.md)
[![nl](https://img.shields.io/badge/lang-nl-43a047.svg)](README.nl.md)

OptimCE is een opensourceplatform voor het beheer van
hernieuwbare-energiegemeenschappen, gebouwd voor de Belgische context van
energiedelen. Het combineert een leden-CRM, verdeelsleutels en simulaties voor
energiedelen, facturatie, documentgeneratie en een communitynieuwsbord, achter
één geauthenticeerde webapplicatie. Meer informatie over het project vind je
op [www.optimce.be](https://www.optimce.be/nl/).

Deze repository is de **ontwikkelingsmonorepo**: ze bundelt alle
OptimCE-services als git-submodules en levert de Docker Compose-omgeving om
het volledige platform lokaal te draaien. Een voorbeeld van een
productiedeployment vind je in
[OptimCE/production](https://github.com/OptimCE/production).

## Repositorystructuur

De servicecode bevindt zich in de afzonderlijke repositories, hier opgenomen
als submodules:

| Pad | Repository | Beschrijving |
|---|---|---|
| `crm-backend/` | [OptimCE/crm-backend](https://github.com/OptimCE/crm-backend) | CRM-backend-API (Node.js / TypeScript) |
| `crm-frontend/` | [OptimCE/crm-frontend](https://github.com/OptimCE/crm-frontend) | Webinterface (Angular) |
| `allocation-key-generation/` | [OptimCE/allocation-key-generation](https://github.com/OptimCE/allocation-key-generation) | Service voor het genereren van verdeelsleutels voor energiedelen (Python) |
| `simulation-key/` | [OptimCE/allocation-key-simulation](https://github.com/OptimCE/allocation-key-simulation) | Simulatieservice voor verdeelsleutels (Python) |
| `billing/` | [OptimCE/billing](https://github.com/OptimCE/billing) | Facturatieservice (Python) |
| `document-generation/` | [OptimCE/document-generation](https://github.com/OptimCE/document-generation) | Documentgeneratieservice (Python) |
| `news-board/` | [OptimCE/news-board](https://github.com/OptimCE/news-board) | Communitynieuwsbord (Python) |
| `keycloak/kc-groupid-mapper/` | [OptimCE/kc-groupid-mapper](https://github.com/OptimCE/kc-groupid-mapper) | Keycloak-mapper die groepsinformatie aan tokens toevoegt |
| `keycloak/optimce-keycloak-theme/` | [OptimCE/optimce-keycloak-theme](https://github.com/OptimCE/optimce-keycloak-theme) | Keycloak-loginthema (Keycloakify) |
| `krakend/swagger2krakend/` | [OptimCE/swagger2krakend](https://github.com/OptimCE/swagger2krakend) | OpenAPI → KrakenD-configuratiegenerator (Python) |

De overige mappen bevatten de orkestratie- en infrastructuurconfiguratie van
deze repository:

| Pad | Beschrijving |
|---|---|
| `krakend/` | Configuratie van de API-gateway (gegenereerde `krakend.json` en OpenAPI-bronnen) |
| `keycloak/` | Keycloak-image, realmconfiguratie en providers |
| `nginx/` | Reverse-proxyconfiguratie en certificaten |
| `crm-frontend-config/` | Gegenereerde runtimeconfiguratie van de frontend |
| `reference/` | Gedeelde referentiegegevens (bv. `regulators.json`) |

## Architectuur

De ontwikkelingsstack (`docker-compose.dev.yml`) draait de volgende services:

**Applicaties**
- **crm-frontend**: Angular-gebruikersinterface
- **crm-backend**: CRM-backend-API
- **allocation-key-generation** (+ worker): berekening van verdeelsleutels
- **simulation-key** (+ worker): simulaties van energiedelen
- **billing** (+ worker): facturatie
- **document-generation**: worker voor documentgeneratie
- **optimce-news-board**: communitynieuwsbord

**Databases** (PostgreSQL, één per service)
- **crm-database**, **keycloak-db**, **allocation-key-db**,
  **simulation-key-db**, **news-board-db**, **billing-db**

**Platform**
- **keycloak**: authenticatieserver
- **krakend**: API-gateway
- **reverse-proxy**: Nginx-reverse-proxy, centraal toegangspunt van de applicatie
- **minio**: S3-compatibele objectopslag
- **nats**: messaging tussen de services en hun workers
- **jaeger**: gedistribueerde tracing (OpenTelemetry)

**Configuratiegeneratie** (profiel `init`, eenmalig draaiende containers)
- **swagger-doc-gen**, **generation-doc-gen**, **simulation-doc-gen**,
  **news-doc-gen**, **billing-doc-gen**: verzamelen de OpenAPI-specificatie van
  elke service
- **krakend-config**, **keycloak-config**, **nginx-config**,
  **crm-frontend-config**: genereren de configuratie van gateway,
  authenticatie, proxy en frontend op basis van sjablonen

## Aan de slag

### Vereisten

- Docker
- Docker Compose
- Git

### Klonen

De services zijn git-submodules, kloon dus recursief:

```bash
git clone --recurse-submodules https://github.com/OptimCE/monorepo.git
cd monorepo
```

Als je al zonder submodules hebt gekloond:

```bash
git submodule update --init --recursive
```

### Omgevingsvariabelen

Configureer vóór het starten van de applicatie het bestand `.env.dev` met de
juiste omgevingsvariabelen, in het bijzonder de wachtwoorden:

```bash
# Wachtwoorden aanpassen in .env.dev
DB_PASSWORD=changeme_db_password
KEYCLOAK_DB_PASSWORD=changeme_keycloak_db_password
KEYCLOAK_ADMIN_PASSWORD=changeme_keycloak_admin_password
```

### Database-initialisatie

De CRM-database wordt bij de eerste start geïnitialiseerd via een SQL-script:

- **CRM-database**: `crm-backend/database_script/init.sql`

Voor Keycloak initialiseert het bestand `keycloak/dev-config.json` een
basisrealm.

⚠️ **Belangrijk**: de databases **zijn niet persistent**. De gegevens gaan
verloren telkens wanneer de containers herstarten. Deze configuratie is
geschikt voor ontwikkeling en tests.

Wil je het databaseschema wijzigen, bewerk dan de bijbehorende SQL-bestanden
voordat je de services start.

### Configuratiegeneratie

Sommige configuraties worden automatisch gegenereerd via de services van het
profiel `init` (zie [Architectuur](#architectuur)), bijvoorbeeld:

- `swagger-doc-gen`: genereert `./krakend/config/swagger.yaml`
- `krakend-config`: genereert `./krakend/config/krakend.json`
- `crm-frontend-config`: genereert `./crm-frontend-config/config.json`

Om alleen de configuratiegeneratie uit te voeren:

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile init up --build
```

Wanneer de containers van het profiel `init` klaar zijn, kun je ze stoppen met:

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile init down
```

Start daarna de volledige stack zoals gewoonlijk.

## Uitvoeren

### Aanbevolen wrapper

Er is een wrapper beschikbaar om de volledige stack te beheren met de Docker
Compose-profielen `init` en `dev`: `./docker-stack.sh` (of `docker-stack.bat`
op Windows).

Maak hem indien nodig uitvoerbaar:

```bash
chmod +x ./docker-stack.sh
```

Belangrijkste commando's:

```bash
./docker-stack.sh start
./docker-stack.sh stop
./docker-stack.sh restart
```

De flow voert automatisch uit:

1. het profiel `init` om de configuraties te genereren
2. het stoppen van het profiel `init`
3. het starten van het profiel `dev` in detached modus

Met `--skip-init` slaat het script de `init`-stappen over en start het direct
het profiel `dev`.

Beschikbare opties voor `start` en `restart`:

```bash
./docker-stack.sh start --no-pull
./docker-stack.sh start --no-build
./docker-stack.sh start --build
./docker-stack.sh start --skip-init
```

Beschikbare opties voor `start`, `stop` en `restart`:

```bash
./docker-stack.sh start -s swagger-doc-gen
./docker-stack.sh stop --service krakend
./docker-stack.sh restart -s keycloak
```

Met `-s` / `--service` richt de wrapper zich alleen op de gevraagde service in
plaats van op de volledige stack. Bij `stop` wordt een
`docker compose stop <service>` uitgevoerd.

Gedrag van de wrapper:

- Detecteert automatisch `docker-compose` of `docker compose`
- Controleert of de Docker-service draait
- Voert het profiel `init` uit (configuratiegeneratie) en stopt het daarna,
  tenzij `--skip-init` wordt gebruikt
- Voert het profiel `dev` uit in detached modus
- Gebruikt `.env.dev` en `docker-compose.dev.yml`

Dit script is de aanbevolen methode voor standaard
start-/stop-/herstartbewerkingen.

### Services handmatig starten

Gebruik het volgende commando om alle services te starten:

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev up
```

Om in detached modus (achtergrond) te draaien:

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev up -d
```

Om de images opnieuw te bouwen vóór het starten:

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev up --build
```

### Services handmatig stoppen

Om alle services te stoppen:

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev down
```

Om de databases volledig te resetten, stop en verwijder de containers:

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev down
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev up
```

De initialisatiescripts worden bij de volgende start automatisch opnieuw
uitgevoerd.

## Toegang tot de services

| Service | Hostpoort | Containerpoort | Protocol | Gebruik |
|---|---:|---:|---|---|
| `allocation-key-generation` | `8002` | `8000` | `tcp` | API voor verdeelsleutels |
| `simulation-key` | `8003` | `8000` | `tcp` | Simulatie-API |
| `optimce-news-board` | `8004` | `8000` | `tcp` | Nieuwsbord-API |
| `billing` | `8005` | `8000` | `tcp` | Facturatie-API |
| `crm-database` | `8080` | `5432` | `tcp` | PostgreSQL CRM |
| `keycloak-db` | `8081` | `5432` | `tcp` | PostgreSQL Keycloak |
| `keycloak` | `8082` | `8080` | `tcp` | Keycloak-authenticatie |
| `jaeger` | `8084` | `6831` | `udp` | Jaeger-collector |
| `jaeger` | `8085` | `16686` | `tcp` | Jaeger-UI |
| `krakend` | `8086` | `8080` | `tcp` | API-gateway |
| `reverse-proxy` | `8087` | `80` | `tcp` | HTTP-reverse-proxy |
| `reverse-proxy` | `8088` | `443` | `tcp` | HTTPS-reverse-proxy |
| `crm-backend` | `8089` | `80` | `tcp` | Backend-API |
| `crm-frontend` | `8090` | `80` | `tcp` | Frontendinterface |
| `minio` | `8091` | `9000` | `tcp` | MinIO-API |
| `minio` | `8092` | `9001` | `tcp` | MinIO-console |
| `allocation-key-db` | `8093` | `5432` | `tcp` | PostgreSQL verdeelsleutels |
| `nats` | `8094` | `4222` | `tcp` | NATS-client |
| `nats` | `8095` | `8222` | `tcp` | NATS-monitoring |
| `simulation-key-db` | `8096` | `5432` | `tcp` | PostgreSQL simulatie |
| `news-board-db` | `8097` | `5432` | `tcp` | PostgreSQL nieuwsbord |
| `billing-db` | `8098` | `5432` | `tcp` | PostgreSQL facturatie |

## Bijdragen

Bijdragen zijn welkom! Lees de [bijdragerichtlijnen](../CONTRIBUTING.md) en
onze [gedragscode](../CODE_OF_CONDUCT.md) (in het Engels) voordat je een issue
of pull request opent.

## Beveiliging

Volg het [beveiligingsbeleid](../SECURITY.md) om een kwetsbaarheid te melden —
open geen publieke issue.

## Licentie

Dit project is gelicentieerd onder de [Apache-licentie 2.0](../LICENSE).
