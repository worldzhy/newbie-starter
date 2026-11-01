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

# compose.application.yml zone markers (ADR-032): the block between them is
# repository-managed orchestration, refreshed from the image on every deploy;
# everything outside is instance-private and only seeded once. Markers live
# inside the `services:` mapping, so matching tolerates leading indentation.
APP_BLOCK_START='# @@newbie-framework-start'
APP_BLOCK_END='# @@newbie-framework-end'

marker_re() { printf '^[[:space:]]*%s[[:space:]]*$' "$1"; }

has_marker() { grep -qE "$(marker_re "$1")" "$2"; }

# install_compose_application IMAGE_COPY HOST_COPY — converge the host's
# compose.application.yml with the image's copy per ADR-032:
#   - host file absent          → seed the whole file (first install);
#   - image copy lacks markers  → die (framework defect; fail closed so a
#                                 silent no-op cannot reintroduce drift);
#   - host copy lacks markers   → pre-ADR-032 install: back up to
#                                 .pre-framework-block and replace wholesale
#                                 (operator edits merge back by hand);
#   - host copy has one marker  → die (ambiguous state, never guessed at);
#   - both carry markers        → splice the image's framework block into the
#                                 host file, leaving instance-private content
#                                 outside the markers untouched.
install_compose_application() {
  local image_file="$1" host_file="$2"
  if [ ! -f "$host_file" ]; then
    cp "$image_file" "$host_file"
    return
  fi
  if ! has_marker "$APP_BLOCK_START" "$image_file" || ! has_marker "$APP_BLOCK_END" "$image_file"; then
    die "image compose.application.yml is missing the @@newbie-framework markers"
  fi
  local host_missing_start=0 host_missing_end=0
  has_marker "$APP_BLOCK_START" "$host_file" || host_missing_start=1
  has_marker "$APP_BLOCK_END" "$host_file" || host_missing_end=1
  if [ "$host_missing_start" -eq 1 ] && [ "$host_missing_end" -eq 1 ]; then
    cp "$host_file" "${host_file}.pre-framework-block"
    cp "$image_file" "$host_file"
    return
  fi
  if [ "$host_missing_start" -ne "$host_missing_end" ]; then
    die "host compose.application.yml carries only one @@newbie-framework marker; merge ${host_file} by hand"
  fi
  local block_file tmp_file
  block_file="$(mktemp)"
  tmp_file="$(mktemp)"
  sed -n "/$(marker_re "$APP_BLOCK_START")/,/$(marker_re "$APP_BLOCK_END")/p" "$image_file" >"$block_file"
  [ -s "$block_file" ] || die "image compose.application.yml has a malformed @@newbie-framework block"
  awk -v block="$block_file" \
    -v "start_re=$(marker_re "$APP_BLOCK_START")" \
    -v "end_re=$(marker_re "$APP_BLOCK_END")" '
    $0 ~ start_re {
      while ((getline line < block) > 0) print line
      close(block)
      inblock = 1
      next
    }
    inblock && $0 ~ end_re { inblock = 0; next }
    inblock { next }
    { print }
  ' "$host_file" >"$tmp_file"
  # cat-preserves the inode out of habit (bind-mount single files read by
  # inode); compose files are host-CLI inputs, so this is belt and braces.
  cat "$tmp_file" >"$host_file"
  rm -f "$tmp_file" "$block_file"
}

# extract_deploy_assets BACKEND_IMAGE INSTALL_DIR — copy the deploy/ payload
# (compose layers, Caddy template, scripts) out of the backend image into the
# install root. The image is the single source of truth; the host never
# clones the repository. Framework files are refreshed on every call;
# compose.application.yml converges per the two-zone contract (ADR-032). cp
# goes through a temp dir so a failed extraction never leaves partial files.
extract_deploy_assets() {
  local image="$1" install_dir="$2" cid
  cid="$(docker create "$image" true)"
  trap "docker rm -f '$cid' >/dev/null 2>&1 || true" EXIT
  rm -rf "${install_dir}/.deploy-new"
  mkdir -p "${install_dir}/.deploy-new"
  docker cp "${cid}:/deploy/." "${install_dir}/.deploy-new/"
  cp "${install_dir}/.deploy-new/compose.framework.yml" "${install_dir}/compose.framework.yml"
  cp "${install_dir}/.deploy-new/compose.modules.yml" "${install_dir}/compose.modules.yml"
  install_compose_application "${install_dir}/.deploy-new/compose.application.yml" \
    "${install_dir}/compose.application.yml"
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
