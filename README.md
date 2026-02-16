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

## Lancement

Pour démarrer tous les services, utilisez la commande suivante :

```bash
docker-compose -f docker-compose.dev.yml --env-file .env.dev up
```

Pour lancer en mode détaché (background) :

```bash
docker-compose -f docker-compose.dev.yml --env-file .env.dev up -d
```

Pour reconstruire les images avant de lancer :

```bash
docker-compose -f docker-compose.dev.yml --env-file .env.dev up --build
```

## Arrêt des services

Pour arrêter tous les services :

```bash
docker-compose -f docker-compose.dev.yml down
```

Pour réinitialiser complètement les bases de données, arrêtez et supprimez les conteneurs :

```bash
docker-compose -f docker-compose.dev.yml down
docker-compose -f docker-compose.dev.yml --env-file .env.dev up
```

Les scripts d'initialisation seront réexécutés automatiquement au prochain démarrage.

## Accès aux services

### Services Web
- **CRM Frontend** : http://localhost:4200
- **CRM Backend API** : http://localhost:3000
- **Keycloak** : http://localhost:8080
- **OpenFiles** : http://localhost:8001
- **Jaeger UI** : http://localhost:16686
- **KraKend API Gateway** : http://localhost:8090
- **Reverse Proxy (Nginx)** : http://localhost (80) / https://localhost (443)

### Bases de données
- **CRM Database (PostgreSQL)** : localhost:5432
- **Keycloak Database (PostgreSQL)** : localhost:5433

### Ports de monitoring
- **Jaeger Collector (UDP)** : localhost:6831

## Note importante

⚠️ **Il est essentiel d'utiliser l'option `--env-file .env.dev`** lors du lancement avec `docker-compose` pour que les substitutions de variables `${VAR}` dans le fichier docker-compose.dev.yml soient correctement résolues.
