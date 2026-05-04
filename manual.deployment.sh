#!/usr/bin/env bash
set -e

# === LOAD ENV ===
set -a
source .env
set +a

echo "Starting full stack manually..."

# ==================== BUILD ====================

echo "Building images..."

docker build \
  --network=host \
  -t backend-app \
  -f backend/Dockerfile \
  .

docker build \
  --network=host \
  -t frontend-app \
  -f frontend/Dockerfile \
  .

NETWORK=traefik-public
VOLUME=app-db-data

echo "Creating network..."
docker network create $NETWORK 2>/dev/null || true

echo "Creating volume..."
docker volume create $VOLUME 2>/dev/null || true

echo "Cleaning old containers..."
docker rm -f postgres-db backend-app frontend-app db-adminer traefik-router 2>/dev/null || true

# ==================== Traefik ====================
echo "Starting Traefik..."
docker run -d \
  --name traefik-router \
  --network $NETWORK \
  -p 80:80 \
  -p 8081:8080 \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -e DOCKER_API_VERSION=1.53 \
  traefik:latest \
  --api.insecure=true \
  --log.level=INFO \
  --providers.docker=true \
  --providers.docker.exposedbydefault=false \
  --providers.docker.watch=true \
  --providers.docker.network=$NETWORK

# ==================== Database ====================
echo "Starting database..."
docker run -d \
  --name postgres-db \
  --network $NETWORK \
  --env-file .env \
  -e PGDATA=/var/lib/postgresql/data/pgdata \
  -v $VOLUME:/var/lib/postgresql/data/pgdata \
  postgres:18

echo "Waiting for database..."
until docker exec postgres-db pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; do
  sleep 2
done
echo "Database ready"

# ==================== Prestart ====================
echo "Running prestart..."
docker run --rm \
  --name prestart-check \
  --network $NETWORK \
  --env-file .env \
  -e POSTGRES_SERVER=postgres-db \
  backend-app bash scripts/prestart.sh

# ==================== Backend ====================
echo "Starting backend..."
docker run -d \
  --name backend-app \
  --network $NETWORK \
  --env-file .env \
  -e POSTGRES_SERVER=postgres-db \
  --label "traefik.enable=true" \
  --label "traefik.docker.network=$NETWORK" \
  --label 'traefik.http.routers.backend.rule=Host(`api.localhost`)' \
  --label "traefik.http.routers.backend.entrypoints=http" \
  --label "traefik.http.services.backend.loadbalancer.server.port=8000" \
  backend-app

# ==================== Frontend ====================
echo "Starting frontend..."
docker run -d \
  --name frontend-app \
  --network $NETWORK \
  --label "traefik.enable=true" \
  --label "traefik.docker.network=$NETWORK" \
  --label 'traefik.http.routers.frontend.rule=Host(`dashboard.localhost`)' \
  --label "traefik.http.routers.frontend.entrypoints=http" \
  --label "traefik.http.services.frontend.loadbalancer.server.port=80" \
  frontend-app

# ==================== Adminer ====================
echo "Starting Adminer..."
docker run -d \
  --name db-adminer \
  --network $NETWORK \
  -e ADMINER_DESIGN=pepa-linha-dark \
  --label "traefik.enable=true" \
  --label "traefik.docker.network=$NETWORK" \
  --label 'traefik.http.routers.adminer.rule=Host(`adminer.localhost`)' \
  --label "traefik.http.routers.adminer.entrypoints=http" \
  --label "traefik.http.services.adminer.loadbalancer.server.port=8080" \
  adminer

echo "All services are up!"
echo ""
echo "Frontend: http://dashboard.localhost/"
echo "Backend:  http://api.localhost/docs"
echo "Adminer:  http://adminer.localhost/"
echo "Traefik Dashboard: http://localhost:8081"