#!/usr/bin/env bash
# Pull the requested images from ECR and recreate the compose services.
# This is the SSM Run Command target for the GitHub Actions deploy pipeline.
#
# Usage: deploy.sh [service ...]
#   deploy.sh                 # pull + recreate the whole stack (runs migrations)
#   deploy.sh backend         # new backend image; postgres-migrate + module migrators run automatically
#   deploy.sh frontend        # deploy a new frontend image
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

cd "$INSTALL_DIR"

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null

BACKEND_IMAGE="${REGISTRY}/${APP_NAME}-backend:${IMAGE_TAG}"

# Extract deploy/ assets (compose file, Caddy template, scripts) from the
# backend image before recreating anything. The image is the single source
# of truth; the host never clones the repository.
$COMPOSE pull backend >/dev/null
CID="$(docker create "$BACKEND_IMAGE" true)"
trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT
# cp to a temp dir first so a failed extraction never leaves partial files.
rm -rf "${INSTALL_DIR}/.deploy-new"
mkdir -p "${INSTALL_DIR}/.deploy-new"
docker cp "${CID}:/deploy/." "${INSTALL_DIR}/.deploy-new/"
cp "${INSTALL_DIR}/.deploy-new/compose.framework.yml" "${INSTALL_DIR}/compose.framework.yml"
cp "${INSTALL_DIR}/.deploy-new/compose.modules.yml" "${INSTALL_DIR}/compose.modules.yml"
# Host-owned overlay: seed once, never overwritten (ADR-008 D1).
if [ ! -f "${INSTALL_DIR}/compose.application.yml" ]; then
  cp "${INSTALL_DIR}/.deploy-new/compose.application.yml" "${INSTALL_DIR}/compose.application.yml"
fi
cp "${INSTALL_DIR}/.deploy-new/Caddyfile.tmpl" "${INSTALL_DIR}/Caddyfile.tmpl"
rm -rf "${INSTALL_DIR}/scripts"
cp -R "${INSTALL_DIR}/.deploy-new/scripts" "${INSTALL_DIR}/scripts"
chmod 0755 "${INSTALL_DIR}/scripts/"*.sh
rm -rf "${INSTALL_DIR}/.deploy-new"

# Re-render in case the new image changed the Caddy template.
"${INSTALL_DIR}/scripts/render-env.sh"

if [ "$#" -eq 0 ]; then
  $COMPOSE pull
  $COMPOSE up -d
else
  $COMPOSE pull "$@"

  # A backend release must always run every one-shot migration service
  # (postgres-migrate plus each module's <key>-migrate, discovered from the
  # merged compose model so this script stays module-agnostic, ADR-008 D1)
  # against the new image before the backend container is recreated. They
  # share the backend image, so no extra pull is needed.
  services=("$@")
  if printf '%s\n' "$@" | grep -qx "backend"; then
    while IFS= read -r one_shot; do
      if ! printf '%s\n' "${services[@]}" | grep -qx "$one_shot"; then
        services+=("$one_shot")
      fi
    done < <($COMPOSE config --services | grep -- '-migrate$' || true)
  fi

  $COMPOSE up -d "${services[@]}"
fi

docker image prune -f >/dev/null
echo "deploy.sh completed: $*"
