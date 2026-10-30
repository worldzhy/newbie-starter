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

# Extract deploy/ assets (compose layers, Caddy template, scripts) from the
# backend image before recreating anything. The image is the single source
# of truth; the host never clones the repository.
$COMPOSE pull backend >/dev/null
extract_deploy_assets "$BACKEND_IMAGE" "$INSTALL_DIR"

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

    # db-seed is not a migrator (it does not match the -migrate$ pattern) but
    # it must also run on every backend release so its idempotent seed
    # converges. Projects that do not declare the service are unaffected.
    if $COMPOSE config --services | grep -qx "db-seed"; then
      if ! printf '%s\n' "${services[@]}" | grep -qx "db-seed"; then
        services+=("db-seed")
      fi
    fi
  fi

  $COMPOSE up -d "${services[@]}"
fi

docker image prune -f >/dev/null
echo "deploy.sh completed: $*"
