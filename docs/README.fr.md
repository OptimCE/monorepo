<p align="center">
  <img src="logo.svg" alt="Logo OptimCE" width="160">
</p>

# OptimCE

[![Site web](https://img.shields.io/badge/Site%20web-optimce.be-2e7d32.svg)](https://www.optimce.be)
[![Licence](https://img.shields.io/badge/Licence-Apache%202.0-blue.svg)](../LICENSE)
[![en](https://img.shields.io/badge/lang-en-lightgrey.svg)](../README.md)
[![fr](https://img.shields.io/badge/lang-fr-43a047.svg)](README.fr.md)
[![de](https://img.shields.io/badge/lang-de-lightgrey.svg)](README.de.md)
[![nl](https://img.shields.io/badge/lang-nl-lightgrey.svg)](README.nl.md)

OptimCE est une plateforme open source de gestion des communautés d'énergie
renouvelable, conçue pour le contexte belge du partage d'énergie. Elle réunit
un CRM des membres, les clés de répartition et les simulations de partage
d'énergie, la facturation, la génération de documents et un tableau
d'actualités communautaire, derrière une application web unique et
authentifiée. Pour en savoir plus sur le projet, consultez
[www.optimce.be](https://www.optimce.be).

Ce dépôt est le **monorepo de développement** : il agrège tous les services
OptimCE sous forme de sous-modules git et fournit l'environnement Docker
Compose pour exécuter la plateforme complète en local. Pour un exemple de
déploiement en production, voir
[OptimCE/production](https://github.com/OptimCE/production).

## Structure du dépôt

Le code des services se trouve dans les dépôts individuels, inclus ici comme
sous-modules :

| Chemin | Dépôt | Description |
|---|---|---|
| `crm-backend/` | [OptimCE/crm-backend](https://github.com/OptimCE/crm-backend) | API backend du CRM (Node.js / TypeScript) |
| `crm-frontend/` | [OptimCE/crm-frontend](https://github.com/OptimCE/crm-frontend) | Interface web (Angular) |
| `allocation-key-generation/` | [OptimCE/allocation-key-generation](https://github.com/OptimCE/allocation-key-generation) | Service de génération des clés de répartition du partage d'énergie (Python) |
| `simulation-key/` | [OptimCE/allocation-key-simulation](https://github.com/OptimCE/allocation-key-simulation) | Service de simulation des clés de répartition (Python) |
| `administrative-document/` | [OptimCE/administrative-document](https://github.com/OptimCE/administrative-document) | Service de suivi des dossiers réglementaires et de génération des formulaires CWaPE (Python) |
| `billing/` | [OptimCE/billing](https://github.com/OptimCE/billing) | Service de facturation (Python) |
| `document-generation/` | [OptimCE/document-generation](https://github.com/OptimCE/document-generation) | Service de génération de documents (Python) |
| `news-board/` | [OptimCE/news-board](https://github.com/OptimCE/news-board) | Service de tableau d'actualités communautaire (Python) |
| `notification-dispatch/` | [OptimCE/notification-dispatch](https://github.com/OptimCE/notification-dispatch) | Worker d'envoi des e-mails sortants (Python) |
| `keycloak/kc-groupid-mapper/` | [OptimCE/kc-groupid-mapper](https://github.com/OptimCE/kc-groupid-mapper) | Mapper Keycloak ajoutant les informations de groupe aux jetons |
| `keycloak/optimce-keycloak-theme/` | [OptimCE/optimce-keycloak-theme](https://github.com/OptimCE/optimce-keycloak-theme) | Thème de connexion Keycloak (Keycloakify) |
| `krakend/swagger2krakend/` | [OptimCE/swagger2krakend](https://github.com/OptimCE/swagger2krakend) | Générateur de configuration OpenAPI → KrakenD (Python) |

Les autres répertoires contiennent la configuration d'orchestration et
d'infrastructure propre à ce dépôt :

| Chemin | Description |
|---|---|
| `krakend/` | Configuration de la passerelle API (`krakend.json` généré et sources OpenAPI) |
| `keycloak/` | Image Keycloak, configuration du realm et providers |
| `nginx/` | Configuration du reverse proxy et certificats |
| `postgres/` | Provisionnement et vérification de l'instance de base de données unifiée — rôles, bases, droits ([README](../postgres/README.md)) |
| `crm-frontend-config/` | Configuration d'exécution du frontend (générée) |
| `reference/` | Données de référence partagées (p. ex. `regulators.json`) |
| `docs/runbooks/` | Procédures opérationnelles, p. ex. [la consolidation des bases de production](runbooks/database-consolidation.md) |

## Architecture

La stack de développement (`docker-compose.dev.yml`) exécute les services
suivants :

**Applications**
- **crm-frontend** : interface utilisateur Angular
- **crm-backend** : API backend du CRM
- **allocation-key-generation** (+ worker) : calcul des clés de répartition
- **simulation-key** (+ worker) : simulations de partage d'énergie
- **administrative-document** (+ worker) : dossiers réglementaires, échéances
  CWaPE et génération des formulaires
- **billing** (+ worker) : facturation
- **document-generation** : worker de génération de documents
- **notification-dispatch** : worker d'envoi des e-mails sortants
- **optimce-news-board** : tableau d'actualités communautaire

**Bases de données** (PostgreSQL)
- **postgres** : une seule instance, six bases logiques — `crm_db`,
  `allocation_key_local`, `simulation_key_local`, `news_board_local`,
  `billing_local`, `administrative_document_local` — chacune appartenant à son
  propre rôle de connexion. Voir [postgres/README.md](../postgres/README.md).
- **keycloak-db** : une instance distincte ; Keycloak gère son propre schéma.

**Plateforme**
- **keycloak** : serveur d'authentification
- **krakend** : passerelle API
- **reverse-proxy** : reverse proxy Nginx, point d'entrée unique de l'application
- **minio** : stockage objet compatible S3
- **nats** : messagerie entre les services et leurs workers
- **jaeger** : traçage distribué (OpenTelemetry)

**Génération de configuration** (profil `init`, conteneurs à exécution unique)
- **swagger-doc-gen**, **generation-doc-gen**, **simulation-doc-gen**,
  **news-doc-gen**, **billing-doc-gen**, **administrative-document-doc-gen** :
  collectent la spécification OpenAPI de chaque service
- **krakend-config**, **keycloak-config**, **nginx-config**,
  **crm-frontend-config** : génèrent la configuration de la passerelle, de
  l'authentification, du proxy et du frontend à partir de modèles

## Prise en main

### Prérequis

- Docker
- Docker Compose
- Git

### Clonage

Les services sont des sous-modules git, clonez donc récursivement :

```bash
git clone --recurse-submodules https://github.com/OptimCE/monorepo.git
cd monorepo
```

Si vous avez déjà cloné sans les sous-modules :

```bash
git submodule update --init --recursive
```

### Variables d'environnement

Avant de démarrer l'application, veillez à configurer le fichier `.env.dev`
avec les variables d'environnement appropriées, en particulier les mots de
passe :

```bash
# Modifier les mots de passe dans .env.dev
DB_PASSWORD=changeme_db_password
KEYCLOAK_DB_PASSWORD=changeme_keycloak_db_password
KEYCLOAK_ADMIN_PASSWORD=changeme_keycloak_admin_password
```

### Initialisation de la base de données

Toutes les bases applicatives vivent dans **une seule** instance PostgreSQL (le
service `postgres`, port hôte 8080), à raison d'une base logique par service,
chacune appartenant à son propre rôle de connexion. Le sidecar `postgres-init`
provisionne les rôles, les bases, les schémas, les données de départ et les
droits à **chaque** démarrage — voir [postgres/README.md](../postgres/README.md)
pour le détail, y compris la matrice de droits au moindre privilège qui régit ce
que chaque service peut faire dans `crm_db`.

Le fichier de schéma existant de chaque service est réutilisé tel quel :

| Base de données | Schéma appliqué |
|---|---|
| `crm_db` | `crm-backend/tests/sql/init.sql` (DDL + données de départ) |
| `allocation_key_local` | `allocation-key-generation/scripts/sql/schema.sql` |
| `simulation_key_local` | `simulation-key/scripts/sql/schema.sql` |
| `news_board_local` | `news-board/scripts/sql/schema.sql` |
| `billing_local` | `billing/scripts/sql/schema.sql` |
| `administrative_document_local` | `administrative-document/scripts/sql/schema.sql` + ses seeds |

`crm-backend/database_script/init.sql` en est l'équivalent purement DDL, utilisé
en production ; il n'est pas appliqué par la stack de développement.

Keycloak conserve sa **propre** instance (`keycloak-db`, port 8081) et initialise
un realm de base à partir de `keycloak/dev-config.json`.

⚠️ **Important** : les bases de données **ne sont pas persistantes**. Les
données seront perdues à chaque redémarrage des conteneurs. Cette configuration
convient au développement et aux tests.

Si vous souhaitez modifier le schéma de la base de données, éditez les fichiers
SQL correspondants avant de démarrer les services.

### Génération de la configuration

Certaines configurations sont générées automatiquement via les services du
profil `init` (voir [Architecture](#architecture)), par exemple :

- `swagger-doc-gen` : génère `./krakend/config/swagger.yaml`
- `krakend-config` : génère `./krakend/config/krakend.json`
- `crm-frontend-config` : génère `./crm-frontend-config/config.json`

Pour exécuter uniquement la génération de configuration :

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile init up --build
```

Une fois les conteneurs du profil `init` terminés, vous pouvez les arrêter
avec :

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile init down
```

Puis démarrez la stack complète normalement.

## Exécution

### Wrapper recommandé

Un wrapper est disponible pour contrôler la stack complète avec les profils
Docker Compose `init` et `dev` : `./docker-stack.sh` (ou `docker-stack.bat`
sous Windows).

Si nécessaire, rendez-le exécutable :

```bash
chmod +x ./docker-stack.sh
```

Commandes principales :

```bash
./docker-stack.sh start
./docker-stack.sh stop
./docker-stack.sh restart
```

Le flux exécute automatiquement :

1. le profil `init` pour générer les configurations
2. l'arrêt du profil `init`
3. le démarrage du profil `dev` en mode détaché

Avec `--skip-init`, le script saute les étapes `init` et démarre directement le
profil `dev`.

Options disponibles pour `start` et `restart` :

```bash
./docker-stack.sh start --no-pull
./docker-stack.sh start --no-build
./docker-stack.sh start --build
./docker-stack.sh start --skip-init
```

Options disponibles pour `start`, `stop` et `restart` :

```bash
./docker-stack.sh start -s swagger-doc-gen
./docker-stack.sh stop --service krakend
./docker-stack.sh restart -s keycloak
```

Avec `-s` / `--service`, le wrapper cible uniquement le service demandé au lieu
de la stack complète. Pour `stop`, cela exécute un
`docker compose stop <service>`.

Comportement du wrapper :

- Détecte automatiquement `docker-compose` ou `docker compose`
- Vérifie que le service Docker est en cours d'exécution
- Exécute le profil `init` (génération de configuration), puis l'arrête, sauf
  si `--skip-init` est utilisé
- Exécute le profil `dev` en mode détaché
- Utilise `.env.dev` et `docker-compose.dev.yml`

Ce script est la méthode recommandée pour les opérations standard de
démarrage/arrêt/redémarrage.

### Démarrer les services manuellement

Pour démarrer tous les services, utilisez la commande suivante :

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev up
```

Pour exécuter en mode détaché (arrière-plan) :

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev up -d
```

Pour reconstruire les images avant le démarrage :

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev up --build
```

### Arrêter les services manuellement

Pour arrêter tous les services :

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev down
```

Pour réinitialiser complètement les bases de données, arrêtez et supprimez les
conteneurs :

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev down
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev up
```

Les scripts d'initialisation seront réexécutés automatiquement au prochain
démarrage.

## Accès aux services

| Service | Port hôte | Port conteneur | Protocole | Usage |
|---|---:|---:|---|---|
| `allocation-key-generation` | `8002` | `8000` | `tcp` | API des clés de répartition |
| `simulation-key` | `8003` | `8000` | `tcp` | API de simulation |
| `optimce-news-board` | `8004` | `8000` | `tcp` | API du tableau d'actualités |
| `billing` | `8005` | `8000` | `tcp` | API de facturation |
| `administrative-document` | `8006` | `8000` | `tcp` | API des documents administratifs |
| `mailpit` | `8007` | `8025` | `tcp` | Collecteur d'e-mails de développement (interface web) |
| `postgres` | `8080` | `5432` | `tcp` | PostgreSQL — six bases logiques (crm_db, billing_local, …) |
| `keycloak-db` | `8081` | `5432` | `tcp` | PostgreSQL Keycloak |
| `keycloak` | `8082` | `8080` | `tcp` | Authentification Keycloak |
| `jaeger` | `8084` | `6831` | `udp` | Collecteur Jaeger |
| `jaeger` | `8085` | `16686` | `tcp` | Interface Jaeger |
| `krakend` | `8086` | `8080` | `tcp` | Passerelle API |
| `reverse-proxy` | `8087` | `80` | `tcp` | Reverse proxy HTTP |
| `reverse-proxy` | `8088` | `443` | `tcp` | Reverse proxy HTTPS |
| `crm-backend` | `8089` | `80` | `tcp` | API backend |
| `crm-frontend` | `8090` | `80` | `tcp` | Interface frontend |
| `minio` | `8091` | `9000` | `tcp` | API MinIO |
| `minio` | `8092` | `9001` | `tcp` | Console MinIO |
| `nats` | `8094` | `4222` | `tcp` | Client NATS |
| `nats` | `8095` | `8222` | `tcp` | Monitoring NATS |

## Contribuer

Les contributions sont les bienvenues ! Merci de lire le
[guide de contribution](../CONTRIBUTING.md) et notre
[code de conduite](../CODE_OF_CONDUCT.md) (en anglais) avant d'ouvrir une issue
ou une pull request.

## Sécurité

Pour signaler une faille de sécurité, veuillez suivre la
[politique de sécurité](../SECURITY.md) — n'ouvrez pas d'issue publique.

## Licence

Ce projet est distribué sous la [licence Apache 2.0](../LICENSE).
