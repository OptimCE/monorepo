# DevOps Notes

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
- `crm-frontend-config/config.json` - Frontend runtime config

## Reverse Proxy Configuration

The reverse proxy (nginx) exposes services on port 8087:
- Frontend: http://localhost:8087
- API: http://localhost:8087/api
- Keycloak: http://localhost:8087/keycloak

### Keycloak Nginx Config
Keycloak requires special handling due to its context path and URL rewriting:
```nginx
location /keycloak/ {
    proxy_pass http://keycloak;
    proxy_redirect ~^http://localhost(/.*)$ http://localhost:8087$1;
    sub_filter 'http://localhost/keycloak' 'http://localhost:8087/keycloak';
    sub_filter_once off;
    proxy_set_header Host $http_host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host:$server_port;
    proxy_set_header X-Forwarded-Port $server_port;
    proxy_set_header Forwarded "host=$host:$server_port;proto=$scheme";
}
```

## Keycloak Configuration

### Docker Compose Environment Variables
```yaml
environment:
  - KC_HOSTNAME=localhost
  - KC_HOSTNAME_PORT=8087
  - KC_HTTP_ENABLED=true
  - KC_HTTP_RELATIVE_PATH=/keycloak
  - KC_PROXY_HEADERS=forwarded
```

### Critical: `basic` Client Scope
The `basic` client scope contains the `sub` claim protocol mapper which is required for JWT tokens to include the user ID. Without it, tokens will be missing the `sub` claim.

Required in `dev-config.json`:
```json
{
  "clientScopes": [
    {
      "name": "basic",
      "protocol": "openid-connect",
      "protocolMappers": [
        {
          "name": "sub",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-sub-mapper",
          "consentRequired": false,
          "config": {
            "introspection.token.claim": "true",
            "access.token.claim": "true"
          }
        }
      ]
    }
  ]
}
```

The `basic` scope must be added to the `optimce-backend` client's `defaultClientScopes`.

### Custom Protocol Mapper Extension
The Keycloak image `ghcr.io/optimce/kc-groupid-mapper:main` includes a custom protocol mapper that adds organization/group information to JWT tokens.

**Source code**: https://github.com/OptimCE/kc-groupid-mapper

**Protocol Mapper ID**: `oidc-orgs-with-roles-mapper`

**Output structure**:
```json
{
  "orgs": [
    {
      "orgId": "<group-uuid>",
      "orgPath": "/group-name",
      "roles": ["ADMIN"]
    }
  ]
}
```

**Configuration**:
- `claimName`: JWT claim name (default: "orgs")
- `orgsRootPath`: Root path for org groups (default: "/")
- `rolesMode`: "strict" or "loose"

### Service Account
The `optimce-backend` client uses `serviceAccountsEnabled: true` with client credentials grant. The service account user `service-account-optimce-backend` needs the `admin` realm role to manage groups.

**Required client settings**:
- `directAccessGrantsEnabled: true` - for password grant flow
- `serviceAccountsEnabled: true` - for service accounts

### Role Hierarchy (from backend)
```typescript
enum Role {
  MEMBER = 'MEMBER',
  GESTIONNAIRE = 'GESTIONNAIRE',
  ADMIN = 'ADMIN'
}

const ROLE_HIERARCHY = {
  MEMBER: 0,
  GESTIONNAIRE: 1,
  ADMIN: 2
}
```

### Known Issues / TODOs
- **TODO-LIMIT-RIGHTS**: The `optimce-backend` service account currently uses `admin` realm role. Consider switching to `manage-groups` for production with limited permissions.
- When resetting Keycloak, clear the volumes: `docker volume rm $(docker volume ls -q | grep keycloak)`

## Database Volumes
If Keycloak fails to import with duplicate key errors, clear the keycloak database volumes:
```bash
docker-compose -f docker-compose.dev.yml --profile dev down -v
```

## KrakenD Configuration
The KrakenD gateway validates JWT tokens against Keycloak. The issuer must match the token's `iss` claim exactly:
- Token issuer: `http://localhost/keycloak/realms/optimce-realm`
- KrakenD issuer config: `http://localhost/keycloak/realms/optimce-realm`
- JWK URL: `http://keycloak:8080/keycloak/realms/optimce-realm/protocol/openid-connect/certs`

### Regenerate KrakenD Config
After updating Keycloak realm, regenerate krakend.json from swagger.yaml:
```bash
docker-compose -f docker-compose.dev.yml --profile dev up -d --build krakend-config
```

## Original Test Realm Export
For reference, the original test realm configuration is available at `keycloak/realm-export.json`. It contains:
- Full authentication flows
- All realm roles and role composites
- Client scopes with protocol mappers
- Event listeners and security headers
- Keycloak components (keys, client registration policies)
