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
