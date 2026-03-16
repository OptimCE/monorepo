/!\ Ce repo est toujours sujet à de gros changement.

# Déploiement CRM

Ce projet contient la configuration Docker Compose pour déployer l'application CRM avec tous ses services.

## Architecture

L'application comprend les services suivants :
- **crm-frontend** : Interface utilisateur
- **crm-backend** : API backend
- **crm-database** : Base de données PostgreSQL pour le CRM
- **keycloak** : Serveur d'authentification
- **keycloak-db** : Base de données PostgreSQL pour Keycloak
- **openfiles** : Service de gestion de fichiers
- **jaeger** : Traçage distribué (OpenTelemetry)
- **krakend** : API Gateway
- **reverse-proxy** : Nginx reverse proxy
- **letsencrypt** : Gestion des certificats SSL

## Prérequis

- Docker
- Docker Compose

## Configuration

### Variables d'environnement

Avant de lancer l'application, assurez-vous de configurer le fichier `.env.dev` avec les variables d'environnement appropriées, notamment les mots de passe :

```bash
# Modifier les mots de passe dans .env.dev
DB_PASSWORD=changeme_db_password
KEYCLOAK_DB_PASSWORD=changeme_keycloak_db_password
KEYCLOAK_ADMIN_PASSWORD=changeme_keycloak_admin_password
```

### Initialisation des bases de données

Les bases de données sont initialisées via des scripts SQL au premier démarrage :

- **CRM Database** : `crm-backend/database_script/init.sql`
- **Keycloak Database** : `database_init/keycloak-init.sql`

⚠️ **Important** : Les bases de données **ne sont pas persistantes**. Les données seront perdues à chaque redémarrage des conteneurs. Cette configuration est adaptée pour le développement et les tests.

Si vous souhaitez modifier le schéma de base de données, éditez les fichiers SQL correspondants avant de démarrer les services.

## Generation des configurations

Certaines configurations sont generees automatiquement via les services du profil `init` :

- `swagger-doc-gen` : genere `./krakend/config/swagger.yaml`
- `krakend-config` : genere `./krakend/config/krakend.json`
- `crm-frontend-config` : genere `./crm-frontend-config/config.json`

Pour lancer uniquement la generation des configurations :

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile init up --build
```

Quand les conteneurs du profil `init` ont termine, vous pouvez les arreter avec :

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile init down
```

Ensuite, demarrez la stack complete normalement.

## Lancement

Pour démarrer tous les services, utilisez la commande suivante :

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev up
```

Pour lancer en mode détaché (background) :

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev up -d
```

Pour reconstruire les images avant de lancer :

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev up --build
```

## Arrêt des services

Pour arrêter tous les services :

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev down
```

Pour réinitialiser complètement les bases de données, arrêtez et supprimez les conteneurs :

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev down
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile dev up
```

Les scripts d'initialisation seront réexécutés automatiquement au prochain démarrage.

## Accès aux services

| Service | Port hote | Port conteneur | Protocole | Usage |
|---|---:|---:|---|---|
| `crm-database` | `8080` | `5432` | `tcp` | PostgreSQL CRM |
| `keycloak-db` | `8081` | `5432` | `tcp` | PostgreSQL Keycloak |
| `keycloak` | `8082` | `8080` | `tcp` | Authentification Keycloak |
| `openfiles` | `8083` | `8001` | `tcp` | Service de fichiers |
| `jaeger` | `8085` | `16686` | `tcp` | Interface Jaeger |
| `jaeger` | `8084` | `6831` | `udp` | Collecteur Jaeger |
| `krakend` | `8086` | `8080` | `tcp` | API Gateway |
| `reverse-proxy` | `8087` | `80` | `tcp` | HTTP reverse proxy |
| `reverse-proxy` | `8088` | `443` | `tcp` | HTTPS reverse proxy |
| `crm-backend` | `8089` | `80` | `tcp` | API backend |
| `crm-frontend` | `8090` | `80` | `tcp` | Interface frontend |

## Note importante

⚠️ **Il est essentiel d'utiliser l'option `--env-file .env.dev`** lors du lancement avec `docker-compose` pour que les substitutions de variables `${VAR}` dans le fichier docker-compose.dev.yml soient correctement résolues.
