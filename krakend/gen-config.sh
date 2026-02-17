#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME=${IMAGE_NAME:-swagger2krakend}
WORKDIR=${WORKDIR:-"$(pwd)/.."}

INPUT_YAML=${1:-krakend/config/swagger.yaml}
OUTPUT_JSON=${2:-krakend/config/krakend.json}

KEYCLOAK_URL=${KEYCLOAK_URL:-http://keycloak:8080}
REALM_NAME=${REALM_NAME:-optimce-realm}
BACKEND_HOST=${BACKEND_HOST:-http://host.docker.internal:3000}
ISSUER=${ISSUER:-http://localhost:8081/realms/${REALM_NAME}}

#Update the swagger.yaml with the provided parameters
if docker image inspect deployement-crm-backend &>/dev/null; then
    echo "Image found"
else
    echo "Neither image is available"
    docker compose -f "$WORKDIR/docker-compose.dev.yml" build crm-backend
fi

docker run --rm \
    -v "$WORKDIR/krakend/config:/work" \
    -v "$WORKDIR/crm-backend:/app" \
    -v /app/node_modules \
    -w /app \
    deployement-crm-backend \
    sh -c "npx tsx src/swagger/generate-openfile.autogen.ts && cp /app/docs/openapi/swagger.yaml /work/swagger.yaml"


#Update the krakend.json with the provided parameters
docker build -t "$IMAGE_NAME" .

docker run --rm \
	-v "$WORKDIR:/work" -w /work \
	"$IMAGE_NAME" \
	"$INPUT_YAML" -o "$OUTPUT_JSON" \
	--keycloak-url "$KEYCLOAK_URL" \
	--realm-name "$REALM_NAME" \
	--backend-host "$BACKEND_HOST" \
	--issuer "$ISSUER"
