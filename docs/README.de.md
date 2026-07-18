<p align="center">
  <img src="logo.svg" alt="OptimCE-Logo" width="160">
</p>

# OptimCE

[![Website](https://img.shields.io/badge/Website-optimce.be-2e7d32.svg)](https://www.optimce.be/de/)
[![Lizenz](https://img.shields.io/badge/Lizenz-Apache%202.0-blue.svg)](../LICENSE)
[![en](https://img.shields.io/badge/lang-en-lightgrey.svg)](../README.md)
[![fr](https://img.shields.io/badge/lang-fr-lightgrey.svg)](README.fr.md)
[![de](https://img.shields.io/badge/lang-de-43a047.svg)](README.de.md)
[![nl](https://img.shields.io/badge/lang-nl-lightgrey.svg)](README.nl.md)

OptimCE ist eine Open-Source-Plattform für die Verwaltung von
Erneuerbare-Energie-Gemeinschaften, entwickelt für den belgischen
Energy-Sharing-Kontext. Sie vereint ein Mitglieder-CRM, Verteilungsschlüssel
und Simulationen für das Energieteilen, Rechnungsstellung,
Dokumentenerzeugung und ein Community-Nachrichtenboard hinter einer einzigen
authentifizierten Webanwendung. Mehr über das Projekt erfahren Sie auf
[www.optimce.be](https://www.optimce.be/de/).

Dieses Repository ist das **Entwicklungs-Monorepo**: Es bündelt alle
OptimCE-Dienste als Git-Submodule und stellt die Docker-Compose-Umgebung
bereit, um die gesamte Plattform lokal auszuführen. Ein Beispiel für ein
Produktions-Deployment finden Sie unter
[OptimCE/production](https://github.com/OptimCE/production).

## Repository-Struktur

Der Code der Dienste liegt in den einzelnen Repositories, die hier als
Submodule eingebunden sind:

| Pfad | Repository | Beschreibung |
|---|---|---|
| `crm-backend/` | [OptimCE/crm-backend](https://github.com/OptimCE/crm-backend) | CRM-Backend-API (Node.js / TypeScript) |
| `crm-frontend/` | [OptimCE/crm-frontend](https://github.com/OptimCE/crm-frontend) | Weboberfläche (Angular) |
| `allocation-key-generation/` | [OptimCE/allocation-key-generation](https://github.com/OptimCE/allocation-key-generation) | Dienst zur Erzeugung der Verteilungsschlüssel für das Energieteilen (Python) |
| `simulation-key/` | [OptimCE/allocation-key-simulation](https://github.com/OptimCE/allocation-key-simulation) | Simulationsdienst für Verteilungsschlüssel (Python) |
| `billing/` | [OptimCE/billing](https://github.com/OptimCE/billing) | Rechnungsdienst (Python) |
| `document-generation/` | [OptimCE/document-generation](https://github.com/OptimCE/document-generation) | Dienst zur Dokumentenerzeugung (Python) |
| `news-board/` | [OptimCE/news-board](https://github.com/OptimCE/news-board) | Community-Nachrichtenboard (Python) |
| `keycloak/kc-groupid-mapper/` | [OptimCE/kc-groupid-mapper](https://github.com/OptimCE/kc-groupid-mapper) | Keycloak-Mapper, der Gruppeninformationen zu Tokens hinzufügt |
| `keycloak/optimce-keycloak-theme/` | [OptimCE/optimce-keycloak-theme](https://github.com/OptimCE/optimce-keycloak-theme) | Keycloak-Login-Theme (Keycloakify) |
| `krakend/swagger2krakend/` | [OptimCE/swagger2krakend](https://github.com/OptimCE/swagger2krakend) | OpenAPI → KrakenD-Konfigurationsgenerator (Python) |

Die übrigen Verzeichnisse enthalten die Orchestrierungs- und
Infrastrukturkonfiguration dieses Repositories:

| Pfad | Beschreibung |
|---|---|
| `krakend/` | Konfiguration des API-Gateways (generierte `krakend.json` und OpenAPI-Quellen) |
| `keycloak/` | Keycloak-Image, Realm-Konfiguration und Provider |
| `nginx/` | Reverse-Proxy-Konfiguration und Zertifikate |
| `crm-frontend-config/` | Generierte Laufzeitkonfiguration des Frontends |
| `reference/` | Gemeinsame Referenzdaten (z. B. `regulators.json`) |

## Architektur

Der Entwicklungs-Stack (`docker-compose.dev.yml`) führt folgende Dienste aus:

**Anwendungen**
- **crm-frontend**: Angular-Benutzeroberfläche
- **crm-backend**: CRM-Backend-API
- **allocation-key-generation** (+ Worker): Berechnung der Verteilungsschlüssel
- **simulation-key** (+ Worker): Energy-Sharing-Simulationen
- **billing** (+ Worker): Rechnungsstellung
- **document-generation**: Worker für die Dokumentenerzeugung
- **optimce-news-board**: Community-Nachrichtenboard

**Datenbanken** (PostgreSQL, eine pro Dienst)
- **crm-database**, **keycloak-db**, **allocation-key-db**,
  **simulation-key-db**, **news-board-db**, **billing-db**

**Plattform**
- **keycloak**: Authentifizierungsserver
- **krakend**: API-Gateway
- **reverse-proxy**: Nginx-Reverse-Proxy, zentraler Einstiegspunkt der Anwendung
- **minio**: S3-kompatibler Objektspeicher
- **nats**: Messaging zwischen den Diensten und ihren Workern
- **jaeger**: verteiltes Tracing (OpenTelemetry)

**Konfigurationsgenerierung** (Profil `init`, einmalig laufende Container)
- **swagger-doc-gen**, **generation-doc-gen**, **simulation-doc-gen**,
  **news-doc-gen**, **billing-doc-gen**: sammeln die OpenAPI-Spezifikation der
  einzelnen Dienste
- **krakend-config**, **keycloak-config**, **nginx-config**,
  **crm-frontend-config**: erzeugen die Konfiguration von Gateway,
  Authentifizierung, Proxy und Frontend aus Vorlagen

## Erste Schritte

### Voraussetzungen

- Docker
- Docker Compose
- Git

### Klonen

Die Dienste sind Git-Submodule, klonen Sie daher rekursiv:

```bash
git clone --recurse-submodules https://github.com/OptimCE/monorepo.git
cd monorepo
```

Falls Sie bereits ohne Submodule geklont haben:

```bash
git submodule update --init --recursive
```

### Umgebungsvariablen

Bevor Sie die Anwendung starten, konfigurieren Sie die Datei `.env.dev` mit den
passenden Umgebungsvariablen, insbesondere den Passwörtern:

```bash
# Passwörter in .env.dev anpassen
DB_PASSWORD=changeme_db_password
KEYCLOAK_DB_PASSWORD=changeme_keycloak_db_password
KEYCLOAK_ADMIN_PASSWORD=changeme_keycloak_admin_password
```

### Datenbank-Initialisierung

Die CRM-Datenbank wird beim ersten Start über ein SQL-Skript initialisiert:

- **CRM-Datenbank**: `crm-backend/database_script/init.sql`

Für Keycloak initialisiert die Datei `keycloak/dev-config.json` einen
Basis-Realm.

⚠️ **Wichtig**: Die Datenbanken **sind nicht persistent**. Die Daten gehen bei
jedem Neustart der Container verloren. Diese Konfiguration ist für Entwicklung
und Tests geeignet.

Wenn Sie das Datenbankschema ändern möchten, bearbeiten Sie die entsprechenden
SQL-Dateien, bevor Sie die Dienste starten.

### Konfigurationsgenerierung

Einige Konfigurationen werden automatisch über die Dienste des Profils `init`
generiert (siehe [Architektur](#architektur)), zum Beispiel:

- `swagger-doc-gen`: erzeugt `./krakend/config/swagger.yaml`
- `krakend-config`: erzeugt `./krakend/config/krakend.json`
- `crm-frontend-config`: erzeugt `./crm-frontend-config/config.json`

Um nur die Konfigurationsgenerierung auszuführen:

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile init up --build
```

Wenn die Container des Profils `init` fertig sind, können Sie sie stoppen mit:

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile init down
```

Starten Sie anschließend den vollständigen Stack wie gewohnt.

## Betrieb

### Empfohlener Wrapper

Ein Wrapper steht zur Verfügung, um den gesamten Stack mit den
Docker-Compose-Profilen `init` und `dev` zu steuern: `./docker-stack.sh`
(bzw. `docker-stack.bat` unter Windows).

Falls nötig, machen Sie ihn ausführbar:

```bash
chmod +x ./docker-stack.sh
```

Hauptbefehle:

```bash
./docker-stack.sh start
./docker-stack.sh stop
./docker-stack.sh restart
```

Der Ablauf führt automatisch aus:

1. das Profil `init` zur Generierung der Konfigurationen
2. das Stoppen des Profils `init`
3. den Start des Profils `dev` im Detached-Modus

Mit `--skip-init` überspringt das Skript die `init`-Schritte und startet direkt
das Profil `dev`.

Verfügbare Optionen für `start` und `restart`:

```bash
./docker-stack.sh start --no-pull
./docker-stack.sh start --no-build
./docker-stack.sh start --build
./docker-stack.sh start --skip-init
```

Verfügbare Optionen für `start`, `stop` und `restart`:

```bash
./docker-stack.sh start -s swagger-doc-gen
./docker-stack.sh stop --service krakend
./docker-stack.sh restart -s keycloak
```

Mit `-s` / `--service` zielt der Wrapper nur auf den angegebenen Dienst statt
auf den gesamten Stack. Bei `stop` wird ein `docker compose stop <service>`
ausgeführt.

Verhalten des Wrappers:

- Erkennt automatisch `docker-compose` oder `docker compose`
- Prüft, ob der Docker-Dienst läuft
- Führt das Profil `init` aus (Konfigurationsgenerierung) und stoppt es
  anschließend, außer bei `--skip-init`
- Führt das Profil `dev` im Detached-Modus aus
- Verwendet `.env.dev` und `docker-compose.dev.yml`

Dieses Skript ist die empfohlene Methode für standardmäßige
Start-/Stopp-/Neustart-Vorgänge.

### Dienste manuell starten

Um alle Dienste zu starten, verwenden Sie folgenden Befehl:

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev up
```

Für den Detached-Modus (Hintergrund):

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev up -d
```

Um die Images vor dem Start neu zu bauen:

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev up --build
```

### Dienste manuell stoppen

Um alle Dienste zu stoppen:

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev down
```

Um die Datenbanken vollständig zurückzusetzen, stoppen und entfernen Sie die
Container:

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev down
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev up
```

Die Initialisierungsskripte werden beim nächsten Start automatisch erneut
ausgeführt.

## Zugriff auf die Dienste

| Dienst | Host-Port | Container-Port | Protokoll | Verwendung |
|---|---:|---:|---|---|
| `allocation-key-generation` | `8002` | `8000` | `tcp` | API für Verteilungsschlüssel |
| `simulation-key` | `8003` | `8000` | `tcp` | Simulations-API |
| `optimce-news-board` | `8004` | `8000` | `tcp` | News-Board-API |
| `billing` | `8005` | `8000` | `tcp` | Rechnungs-API |
| `crm-database` | `8080` | `5432` | `tcp` | PostgreSQL CRM |
| `keycloak-db` | `8081` | `5432` | `tcp` | PostgreSQL Keycloak |
| `keycloak` | `8082` | `8080` | `tcp` | Keycloak-Authentifizierung |
| `jaeger` | `8084` | `6831` | `udp` | Jaeger-Collector |
| `jaeger` | `8085` | `16686` | `tcp` | Jaeger-UI |
| `krakend` | `8086` | `8080` | `tcp` | API-Gateway |
| `reverse-proxy` | `8087` | `80` | `tcp` | HTTP-Reverse-Proxy |
| `reverse-proxy` | `8088` | `443` | `tcp` | HTTPS-Reverse-Proxy |
| `crm-backend` | `8089` | `80` | `tcp` | Backend-API |
| `crm-frontend` | `8090` | `80` | `tcp` | Frontend-Oberfläche |
| `minio` | `8091` | `9000` | `tcp` | MinIO-API |
| `minio` | `8092` | `9001` | `tcp` | MinIO-Konsole |
| `allocation-key-db` | `8093` | `5432` | `tcp` | PostgreSQL Verteilungsschlüssel |
| `nats` | `8094` | `4222` | `tcp` | NATS-Client |
| `nats` | `8095` | `8222` | `tcp` | NATS-Monitoring |
| `simulation-key-db` | `8096` | `5432` | `tcp` | PostgreSQL Simulation |
| `news-board-db` | `8097` | `5432` | `tcp` | PostgreSQL News-Board |
| `billing-db` | `8098` | `5432` | `tcp` | PostgreSQL Rechnungsstellung |

## Mitwirken

Beiträge sind willkommen! Bitte lesen Sie die
[Contributing-Richtlinien](../CONTRIBUTING.md) und unseren
[Verhaltenskodex](../CODE_OF_CONDUCT.md) (auf Englisch), bevor Sie ein Issue
oder einen Pull Request eröffnen.

## Sicherheit

Um eine Sicherheitslücke zu melden, folgen Sie bitte der
[Sicherheitsrichtlinie](../SECURITY.md) — eröffnen Sie kein öffentliches Issue.

## Lizenz

Dieses Projekt ist unter der [Apache-Lizenz 2.0](../LICENSE) lizenziert.
