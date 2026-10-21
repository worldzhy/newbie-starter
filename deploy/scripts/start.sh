#!/usr/bin/env bash
# Extract deploy assets from the backend image and bring the stack up.
# Runs after provision.sh on first boot; re-run via SSM once the first
# images have been pushed to ECR. Idempotent.
#
# On a first boot before any image exists in ECR this logs a warning and
# exits 0 (user-data must not fail-loop); re-run it once CI has published
# the backend image. First boot also requires the two host config
# files at INSTALL_DIR (schema in lib.sh); create them before running.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_CONFIG="$INSTALL_DIR/deploy.config.json"
require_config "$DEPLOY_CONFIG" "$DEPLOY_CONFIG_SCHEMA" region imageTag ecrRepositoryPrefix appName
REGION="$(resolve_region "$DEPLOY_CONFIG")"
IMAGE_TAG="$(json_val "$DEPLOY_CONFIG" imageTag)"
REGISTRY="$(json_val "$DEPLOY_CONFIG" ecrRepositoryPrefix)"
APP_NAME="$(json_val "$DEPLOY_CONFIG" appName)"
COMPOSE="docker compose -f ${INSTALL_DIR}/compose.framework.yml -f ${INSTALL_DIR}/compose.modules.yml -f ${INSTALL_DIR}/compose.application.yml"

log() { echo "[start $(date -Is)] $*"; }
mkdir -p "$INSTALL_DIR"

BACKEND_IMAGE="${REGISTRY}/${APP_NAME}-backend:${IMAGE_TAG}"
FRONTEND_IMAGE="${REGISTRY}/${APP_NAME}-frontend:${IMAGE_TAG}"

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null 2>&1 || true

if ! docker pull "$BACKEND_IMAGE"; then
  log "WARNING: ${BACKEND_IMAGE} not available yet; run start.sh again after CI has published images"
  exit 0
fi

# Extract the deploy/ payload (compose layers, Caddy template, scripts).
extract_deploy_assets "$BACKEND_IMAGE" "$INSTALL_DIR"

# Render .env + Caddyfile from Secrets Manager.
"${INSTALL_DIR}/scripts/render-env.sh"

# Frontend may lag the backend publish; pull but do not fail hard.
docker pull "$FRONTEND_IMAGE" || log "WARNING: ${FRONTEND_IMAGE} not available yet"

cd "$INSTALL_DIR"
$COMPOSE pull
$COMPOSE up -d
log "stack started"
