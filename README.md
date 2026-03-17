/!\ Ce repo est toujours sujet à de gros changements.

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

La base CRM est initialisée via un script SQL au premier démarrage :

- **CRM Database** : `crm-backend/database_script/init.sql`

Pour Keycloak, le fichier `keycloak/dev-config.json` est responsable de l'initiation d'un realm de base.

⚠️ **Important** : Les bases de données **ne sont pas persistantes**. Les données seront perdues à chaque redémarrage des conteneurs. Cette configuration est adaptée pour le développement et les tests.

Si vous souhaitez modifier le schéma de base de données, éditez les fichiers SQL correspondants avant de lancer les services.

## Génération des configurations

Certaines configurations sont générées automatiquement via les services du profil `init` :

- `swagger-doc-gen` : génère `./krakend/config/swagger.yaml`
- `krakend-config` : génère `./krakend/config/krakend.json`
- `crm-frontend-config` : génère `./crm-frontend-config/config.json`

Pour lancer uniquement la génération des configurations :

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile init up --build
```

Quand les conteneurs du profil `init` ont terminé, vous pouvez les arrêter avec :

```bash
docker compose --env-file .env.dev -f docker-compose.dev.yml --profile init down
```

Ensuite, démarrez la stack complète normalement.

## Lancement

### Wrapper recommandé

Un wrapper est disponible pour piloter la stack complète avec les profils Docker Compose `init` puis `dev` : `./docker-stack.sh`.

Si besoin, rendez-le exécutable :

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
3. le démarrage du profil `dev` en détaché

Avec `--skip-init`, le script ignore les étapes `init` et démarre directement le profil `dev`.

Options disponibles pour `start` et `restart` :

```bash
./docker-stack.sh start --no-pull
./docker-stack.sh start --no-build
./docker-stack.sh start --build
./docker-stack.sh start --skip-init
```

Comportement du wrapper :

- Détecte automatiquement `docker-compose` ou `docker compose`
- Vérifie que le service Docker est actif
- Lance le profil `init` (génération de configuration), puis le stoppe, sauf avec `--skip-init`
- Lance le profil `dev` en détaché
- Utilise `.env.dev` et `docker-compose.dev.yml`

Ce script est la méthode conseillée pour les opérations courantes de démarrage/arrêt/redémarrage.

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