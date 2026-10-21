#!/usr/bin/env bash
# Shared helpers for the deploy scripts. Sourced, never executed.
#
# Host config contract (ADR-006 C1): two host-owned JSON files live at the
# install root, created once by the operator and never overwritten by
# deploys. Framework scripts read them and fail fast on anything missing:
#
#   deploy.config.json  {"region", "imageTag", "ecrRepositoryPrefix", "appName"}
#   env.config.json     {"region", "secretId", "siteDomain", "acmeEmail"}
#
# Schema examples use placeholders on purpose: no host literals may appear
# in framework files.

DEPLOY_CONFIG_SCHEMA='{"region": "<aws-region>", "imageTag": "<image tag, e.g. prod>", "ecrRepositoryPrefix": "<account>.dkr.ecr.<region>.amazonaws.com", "appName": "<app name, e.g. myapp>"}'
ENV_CONFIG_SCHEMA='{"region": "<aws-region>", "secretId": "<stack>/<env>/env", "siteDomain": "<public domain>", "acmeEmail": "<letsencrypt contact>"}'

die() { echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] ERROR: $*" >&2; exit 1; }

# require_config FILE SCHEMA KEY... — die unless the file exists and every
# listed key resolves to a non-empty value.
require_config() {
  local file="$1" schema="$2"; shift 2
  if [ ! -f "$file" ]; then
    die "host config not found: $file
Expected schema: $schema
Create it once on this host; deploys never overwrite it."
  fi
  local k v missing=""
  for k in "$@"; do
    v="$(jq -r --arg k "$k" '.[$k] // ""' "$file" 2>/dev/null || true)"
    [ -n "$v" ] || missing="$missing $k"
  done
  [ -z "$missing" ] || die "host config $file has empty key(s):$missing
Expected schema: $schema"
}

# json_val FILE KEY — echo the (already validated) key's value.
json_val() { jq -r --arg k "$2" '.[$k] // ""' "$1"; }

# extract_deploy_assets BACKEND_IMAGE INSTALL_DIR — copy the deploy/ payload
# (compose layers, Caddy template, scripts) out of the backend image into the
# install root. The image is the single source of truth; the host never
# clones the repository. Framework files are refreshed on every call; the
# host-owned compose.application.yml is only seeded once, never overwritten
# (ADR-008 D1). cp goes through a temp dir so a failed extraction never
# leaves partial files.
extract_deploy_assets() {
  local image="$1" install_dir="$2" cid
  cid="$(docker create "$image" true)"
  trap "docker rm -f '$cid' >/dev/null 2>&1 || true" EXIT
  rm -rf "${install_dir}/.deploy-new"
  mkdir -p "${install_dir}/.deploy-new"
  docker cp "${cid}:/deploy/." "${install_dir}/.deploy-new/"
  cp "${install_dir}/.deploy-new/compose.framework.yml" "${install_dir}/compose.framework.yml"
  cp "${install_dir}/.deploy-new/compose.modules.yml" "${install_dir}/compose.modules.yml"
  # Host-owned overlay: seed once, never overwritten (ADR-008 D1).
  if [ ! -f "${install_dir}/compose.application.yml" ]; then
    cp "${install_dir}/.deploy-new/compose.application.yml" "${install_dir}/compose.application.yml"
  fi
  cp "${install_dir}/.deploy-new/Caddyfile.tmpl" "${install_dir}/Caddyfile.tmpl"
  rm -rf "${install_dir}/scripts"
  cp -R "${install_dir}/.deploy-new/scripts" "${install_dir}/scripts"
  chmod 0755 "${install_dir}/scripts/"*.sh
  rm -rf "${install_dir}/.deploy-new"
  docker rm -f "$cid" >/dev/null
  trap - EXIT
}

# resolve_region CONFIG_FILE — echo the AWS region. Precedence: the config
# file's "region" key (if present and non-empty), then the EC2 instance
# metadata service, then a hard error.
resolve_region() {
  local file="$1" region="" token
  if [ -f "$file" ]; then
    region="$(jq -r '.region // ""' "$file" 2>/dev/null || true)"
  fi
  if [ -z "$region" ]; then
    token="$(curl -sf -X PUT http://169.254.169.254/latest/api/token \
      -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' || true)"
    if [ -n "$token" ]; then
      region="$(curl -sf -H "X-aws-ec2-metadata-token: $token" \
        http://169.254.169.254/latest/meta-data/placement/region || true)"
    fi
  fi
  [ -n "$region" ] || die "region unresolved: set \"region\" in $file (IMDS unavailable)"
  echo "$region"
}
