#!/usr/bin/env bash
# Render .env and the Caddyfile at the install root.
#
# Inputs (ADR-006 — host values live only in the two host config files):
#   env.config.json     secretId -> AWS Secrets Manager secret holding the
#                       app env keys; siteDomain/acmeEmail -> Caddyfile render
#   deploy.config.json  ecrRepositoryPrefix/imageTag/region/appName ->
#                       deployment plumbing injected into .env for compose
#                       interpolation
# Safe to re-run; never prints secret values.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_CONFIG="$INSTALL_DIR/env.config.json"
DEPLOY_CONFIG="$INSTALL_DIR/deploy.config.json"

require_config "$ENV_CONFIG" "$ENV_CONFIG_SCHEMA" region secretId siteDomain acmeEmail
require_config "$DEPLOY_CONFIG" "$DEPLOY_CONFIG_SCHEMA" region imageTag ecrRepositoryPrefix appName

SECRET_ID="$(json_val "$ENV_CONFIG" secretId)"
SITE_DOMAIN="$(json_val "$ENV_CONFIG" siteDomain)"
ACME_EMAIL="$(json_val "$ENV_CONFIG" acmeEmail)"
IMAGE_TAG="$(json_val "$DEPLOY_CONFIG" imageTag)"
ECR_PREFIX="$(json_val "$DEPLOY_CONFIG" ecrRepositoryPrefix)"
APP_NAME="$(json_val "$DEPLOY_CONFIG" appName)"
REGION="$(resolve_region "$DEPLOY_CONFIG")"

mkdir -p "$INSTALL_DIR"
TMP_JSON="$(mktemp)"
trap 'rm -f "$TMP_JSON"' EXIT

aws --region "$REGION" secretsmanager get-secret-value \
  --secret-id "$SECRET_ID" --query SecretString --output text > "$TMP_JSON"

umask 077
# Render KEY=VALUE lines from the JSON secret. jq -R escapes newlines as \n
# and pipes/shell-special chars remain in value; the shell never re-parses
# these lines — they're written raw to .env, which compose reads line by
# line with "export KEY=VALUE" semantics.
jq -r 'to_entries[] | "\(.key)=\(.value | tostring | gsub("\n"; "\\n"))"' \
  "$TMP_JSON" > "$INSTALL_DIR/.env"

# Deployment plumbing injected from deploy.config.json, not the app secret:
# compose interpolates ${APP_NAME} into the project name and, together with
# ${ECR_REPOSITORY_PREFIX}/${IMAGE_TAG}, into image refs; ${AWS_REGION} goes
# into the backup container's S3 region.
cat >> "$INSTALL_DIR/.env" <<EOF
ECR_REPOSITORY_PREFIX=$ECR_PREFIX
IMAGE_TAG=$IMAGE_TAG
AWS_REGION=$REGION
APP_NAME=$APP_NAME
EOF
chmod 600 "$INSTALL_DIR/.env"

if [ ! -f "$INSTALL_DIR/Caddyfile.tmpl" ]; then
  echo "Caddyfile.tmpl missing; run start.sh first to extract deploy assets" >&2
  exit 1
fi

# The fallback route depends on whether a frontend exists (ADR-008 D1): UI-less
# hosts keep the framework's "ui" profile off, and proxying to the absent
# frontend service would answer 502 for every non-API path. Ask the merged
# compose model which services it actually enables; if compose cannot answer,
# keep the shipped frontend route so a UI host never loses its frontend.
FRONTEND_FALLBACK="reverse_proxy frontend:3001"
if SERVICES="$(docker compose --project-directory "$INSTALL_DIR" --env-file "$INSTALL_DIR/.env" \
  -f "$INSTALL_DIR/compose.framework.yml" \
  -f "$INSTALL_DIR/compose.modules.yml" \
  -f "$INSTALL_DIR/compose.application.yml" config --services 2>/dev/null)"; then
  printf '%s\n' "$SERVICES" | grep -qx frontend || FRONTEND_FALLBACK='respond "" 404'
else
  echo "compose model unavailable; keeping the frontend fallback route" >&2
fi

sed -e "s|__SITE_DOMAIN__|${SITE_DOMAIN}|g" \
  -e "s|__ACME_EMAIL__|${ACME_EMAIL}|g" \
  -e "s|__FRONTEND_FALLBACK__|${FRONTEND_FALLBACK}|g" \
  "$INSTALL_DIR/Caddyfile.tmpl" > "$INSTALL_DIR/Caddyfile"
chmod 644 "$INSTALL_DIR/Caddyfile"

echo "rendered .env ($(wc -l < "$INSTALL_DIR/.env") keys) and Caddyfile for ${SITE_DOMAIN}"
