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
jq -r 'to_entries | map("\(.key)=\(.value | tostring)") | join("\n")' \
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
sed -e "s|__SITE_DOMAIN__|${SITE_DOMAIN}|g" \
  -e "s|__ACME_EMAIL__|${ACME_EMAIL}|g" \
  "$INSTALL_DIR/Caddyfile.tmpl" > "$INSTALL_DIR/Caddyfile"
chmod 644 "$INSTALL_DIR/Caddyfile"

echo "rendered .env ($(wc -l < "$INSTALL_DIR/.env") keys) and Caddyfile for ${SITE_DOMAIN}"
