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

# die MESSAGE — fail fast with one line of context. Before install_failure_trap
# runs (the host config checks) that line is all there is; afterwards it also
# routes through report_deploy_failure, because an explicit `exit` never fires
# the ERR trap and framework-integrity failures would otherwise stay bare
# (R37-03). BASH_LINENO[0] keeps the reported line at die's caller.
die() {
  echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] ERROR: $*" >&2
  if [ "${DEPLOY_FAILURE_TRAP:-0}" -eq 1 ]; then
    report_deploy_failure 1 "${BASH_LINENO[0]:-?}"
  fi
  exit 1
}

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

# --- Deployment readiness and failure diagnostics (ADR-047) ---
#
# `docker compose up -d` returning 0 only proves the containers were created;
# it says nothing about whether they came up. These helpers turn the exit code
# into an actual readiness judgement and make a failure explain itself instead
# of leaving a bare exit status behind.

# container_probe CONTAINER_ID — echo "<state> <health|none> <exit code>".
container_probe() {
  docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.State.ExitCode}}' \
    "$1" 2>/dev/null || echo "missing none 0"
}

# is_one_shot SERVICE — the same `*-migrate` / db-seed convention deploy.sh
# uses to discover migrators; such a container is expected to exit, not run.
is_one_shot() {
  case "$1" in
    *-migrate | db-seed) return 0 ;;
  esac
  return 1
}

# newest_container SERVICE — echo the id of the most recently created
# container for a service, exited ones included (a one-shot that already
# finished is exactly what the readiness gate needs to inspect).
newest_container() {
  local svc="$1" id ts best="" best_ts=""
  for id in $($COMPOSE ps -aq "$svc" 2>/dev/null); do
    ts="$(docker inspect --format '{{.Created}}' "$id" 2>/dev/null || true)"
    [ -n "$ts" ] || continue
    if [ -z "$best_ts" ] || [[ "$ts" > "$best_ts" ]]; then
      best="$id"
      best_ts="$ts"
    fi
  done
  echo "$best"
}

# ready_fail MESSAGE [EXIT_CODE] — fail the readiness gate with diagnostics.
# Plain `die` would exit without the ERR trap firing, so the one-shot logs that
# explain the failure would be lost. The exit code defaults to 1; callers pass
# the container's real code so CI can tell "migration failed" (1) apart from
# OOM-killed (137) or SIGTERM (143) (R37-02). BASH_LINENO[0] keeps the reported
# line pointing at the caller, not at this function.
ready_fail() {
  local code="${2:-1}"
  echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] ERROR: $1" >&2
  report_deploy_failure "$code" "${BASH_LINENO[0]:-?}"
}

# wait_for_services_ready SERVICE... — block until every service is ready:
# healthcheck → healthy, long-running → running, one-shot → exited(0).
# Polls every 5s up to DEPLOY_HEALTH_TIMEOUT (default 180s, which covers the
# framework healthcheck's start_period 40s + interval 30s x retries 3).
# unhealthy / dead / non-zero one-shot exits fail immediately.
wait_for_services_ready() {
  local timeout="${DEPLOY_HEALTH_TIMEOUT:-180}"
  local deadline=$((SECONDS + timeout))
  local pending svc cid state health code
  while :; do
    pending=""
    for svc in "$@"; do
      cid="$(newest_container "$svc")"
      if [ -z "$cid" ]; then
        pending="$pending $svc(no-container)"
        continue
      fi
      read -r state health code <<<"$(container_probe "$cid")"
      if is_one_shot "$svc"; then
        case "$state" in
          exited) [ "${code:-1}" -eq 0 ] || ready_fail "one-shot service $svc exited ${code}" "${code:-1}" ;;
          running | created) pending="$pending $svc($state)" ;;
          *) ready_fail "one-shot service $svc is $state (exit $code)" ;;
        esac
      else
        case "$state" in
          running)
            case "$health" in
              healthy | none) ;;
              starting) pending="$pending $svc(starting)" ;;
              *) ready_fail "service $svc is $health" ;;
            esac
            ;;
          created | restarting | paused) pending="$pending $svc($state)" ;;
          *) ready_fail "service $svc is $state (exit $code)" ;;
        esac
      fi
    done
    if [ -z "$pending" ]; then
      echo "readiness gate passed: $*"
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      ready_fail "readiness gate timed out after ${timeout}s:$pending"
    fi
    echo "waiting for readiness:$pending"
    sleep 5
  done
}

# report_deploy_failure CODE LINE — print the failing context plus the tail of
# every one-shot container's log, then exit with the original code. Output is
# bounded (40 + 80 lines per service) because SSM truncates plugin output at
# roughly 24k, and an unbounded dump would cut the root cause off again.
report_deploy_failure() {
  local code="${1:-1}" line="${2:-?}" svc cid state health exit_code shown=0
  trap - ERR
  {
    echo
    echo "=== deploy failed: exit $code (${BASH_SOURCE[1]:-deploy.sh}:$line) ==="
  } >&2
  if [ -n "${COMPOSE:-}" ]; then
    {
      echo "--- compose ps -a ---"
      $COMPOSE ps -a 2>&1 | tail -n 40 || true
    } >&2
    for svc in $($COMPOSE config --services 2>/dev/null || true); do
      cid="$(newest_container "$svc")"
      [ -n "$cid" ] || continue
      read -r state health exit_code <<<"$(container_probe "$cid")"
      if is_one_shot "$svc"; then
        # Migration/seed one-shots only matter when they failed.
        [ "$state" = "exited" ] && [ "${exit_code:-0}" -ne 0 ] || continue
      else
        # Long-running services only matter when they are not serving.
        [ "$state" = "running" ] && [ "$health" != "unhealthy" ] && continue
      fi
      [ "$shown" -lt 5 ] || break
      shown=$((shown + 1))
      {
        echo "--- logs: $svc ($state/${health}, exit $exit_code) ---"
        docker logs --tail 80 "$cid" 2>&1 || true
      } >&2
    done
    {
      echo "--- recovery ---"
      echo "  1. docker compose logs <service>   # confirm the failing statement"
      echo "  2. select * from _prisma_migrations where finished_at is null and rolled_back_at is null;"
      echo "  3. fix the data/guard cause, then mark the failed row rolled back:"
      echo "     docker compose run --rm --no-deps -T postgres-migrate npx prisma migrate resolve --rolled-back <migration_name>"
      echo "  4. rerun: ${INSTALL_DIR:-<install dir>}/scripts/deploy.sh <services>"
      echo "do not drop or rewrite data to get past a guard; it is protecting existing rows."
    } >&2
  fi
  exit "$code"
}

# install_failure_trap — route any non-zero exit through report_deploy_failure.
# Call once, after COMPOSE / INSTALL_DIR are set. Requires `set -E` so the trap
# also fires inside functions.
install_failure_trap() {
  DEPLOY_FAILURE_TRAP=1
  trap 'report_deploy_failure "$?" "$LINENO"' ERR
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
    token="$(curl -sf --max-time 60 -X PUT http://169.254.169.254/latest/api/token \
      -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' || true)"
    if [ -n "$token" ]; then
      region="$(curl -sf --max-time 60 -H "X-aws-ec2-metadata-token: $token" \
        http://169.254.169.254/latest/meta-data/placement/region || true)"
    fi
  fi
  [ -n "$region" ] || die "region unresolved: set \"region\" in $file (IMDS unavailable)"
  echo "$region"
}
