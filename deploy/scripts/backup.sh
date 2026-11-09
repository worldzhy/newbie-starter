#!/usr/bin/env bash
# Nightly backup of every labelled datastore into S3.
#
# Runs from host cron (see provision.sh). S3 layout contract (ADR-013; the
# MongoDB layout is revised by ADR-020), where run-id is a UTC timestamp
# YYYYMMDDTHHMMSSZ generated once per run:
#   postgres/<run-id>/<app>.pgdump
#   mongodb/<run-id>/<db>.archive.gz
#   redis/<run-id>/dump.rdb
#   clickhouse/<run-id>/...      (clickhouse-backup backup name = run-id)
#   manifests/<run-id>.json      (written LAST; the UI reads only this prefix)
# Failed runs still upload a manifest with status=failed. On failure the
# script also emits the <app>/BackupFailure custom metric, which the
# CloudFormation stack alarms on. Output is appended to
# /var/log/<app>-backup.log by cron.
#
# Engine discovery (ADR-008 D5): every datastore service in the merged
# compose model carries a `newbie.backup-engine` label (rendered from the CLI
# datastore registry for module services; pinned on postgres in
# compose.framework.yml). This script holds no engine list — adding an engine
# is a registry mapping plus one backup_<engine>() function below, with zero
# changes to the discovery or dispatch logic.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="docker compose -f ${INSTALL_DIR}/compose.framework.yml -f ${INSTALL_DIR}/compose.modules.yml -f ${INSTALL_DIR}/compose.application.yml"
REGION="$(resolve_region "$INSTALL_DIR/deploy.config.json")"
cd "$INSTALL_DIR"

env_value() {
  grep -E "^$1=" .env | head -1 | sed "s/^$1=//"
}

BUCKET="$(env_value BACKUP_BUCKET)"
APP_NAME="$(env_value APP_NAME)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Ephemeral per-run temp dir; never persists past the script exit. Plaintext
# dumps only live here while being copied to S3.
WORKDIR="$(mktemp -d "${INSTALL_DIR}/.backup-tmp.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

now_ms() { date +%s%3N; }

# --- manifest accumulation ---------------------------------------------------
# ENGINES_JSON collects one fragment per engine; CURRENT_* tracks the engine
# in flight so the ERR trap can record it as failed before exiting.
ENGINES_JSON=""
CURRENT_ENGINE=""
CURRENT_ENGINE_KEY=""
CURRENT_ENGINE_START=0

record_engine() {
  # $1 engine, $2 status (success|failed|skipped), $3 bytes, $4 durationMs, $5 key
  local fragment="\"$1\": {\"status\": \"$2\", \"bytes\": $3, \"durationMs\": $4, \"key\": \"$5\"}"
  if [ -n "$ENGINES_JSON" ]; then
    ENGINES_JSON="${ENGINES_JSON}, ${fragment}"
  else
    ENGINES_JSON="$fragment"
  fi
}

write_manifest() {
  # $1 overall status (success|failed)
  printf '{"runId": "%s", "startedAt": "%s", "finishedAt": "%s", "status": "%s", "engines": {%s}}\n' \
    "$RUN_ID" "$STARTED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$ENGINES_JSON" \
    > "$WORKDIR/manifest.json"
  # S3 upload failure: surface as a distinct error (manifest lost) so the
  # cron log and the trailing BackupFailure metric both fire. Previously
  # `|| true` swallowed both channels simultaneously.
  if ! aws --region "$REGION" s3 cp --quiet \
    "$WORKDIR/manifest.json" "s3://${BUCKET}/manifests/${RUN_ID}.json"; then
    echo "[$(date -Is)] WARNING: manifest S3 upload failed for run ${RUN_ID}" >&2
    return 1
  fi
}

signal_failure() {
  local failed_engine="${CURRENT_ENGINE:-unknown}"
  if [ -n "$CURRENT_ENGINE" ]; then
    record_engine "$CURRENT_ENGINE" failed 0 "$(( $(now_ms) - CURRENT_ENGINE_START ))" "$CURRENT_ENGINE_KEY"
    CURRENT_ENGINE=""
  fi
  write_manifest failed
  # CloudWatch metric failure: log explicitly instead of `|| true` so the
  # cron log still carries the alarm signal when AWS is rate-limiting.
  if ! aws --region "$REGION" cloudwatch put-metric-data \
    --namespace "$APP_NAME" \
    --metric-data "MetricName=BackupFailure,Value=1,Unit=Count,Timestamp=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"; then
    echo "[$(date -Is)] WARNING: BackupFailure metric emit failed" >&2
  fi
  echo "[$(date -Is)] BACKUP FAILED (engine: ${failed_engine})" >&2
}
trap signal_failure ERR

# --- Engine backup functions -------------------------------------------------
# Each takes the compose service name as $1 and records exactly one engine
# fragment. Data paths follow the registry convention ./data/<service>.

backup_postgres() {
  local service="$1"
  local user db key
  user="$(env_value POSTGRES_USER)"
  db="$(env_value POSTGRES_DB)"
  key="postgres/${RUN_ID}/${APP_NAME}.pgdump"
  CURRENT_ENGINE="postgres"; CURRENT_ENGINE_KEY="$key"; CURRENT_ENGINE_START="$(now_ms)"
  $COMPOSE exec -T "$service" \
    pg_dump -U "$user" -d "$db" -Fc --no-owner --no-privileges \
    > "$WORKDIR/${APP_NAME}.pgdump"
  aws --region "$REGION" s3 cp --quiet \
    "$WORKDIR/${APP_NAME}.pgdump" "s3://${BUCKET}/${key}"
  record_engine postgres success "$(stat -c%s "$WORKDIR/${APP_NAME}.pgdump")" "$(( $(now_ms) - CURRENT_ENGINE_START ))" "$key"
  CURRENT_ENGINE=""
}

backup_mongodb() {
  # Single database: the whole app shares one Mongoose connection whose URI
  # selects the database (MONGO_URL), and modules reuse that connection, so
  # every collection lives in that one database. The database name is parsed
  # from MONGO_URL — the secret owns it. The engine key is the run prefix
  # (trailing slash); the archive file name is fixed (<db>.archive.gz) so
  # restore runbooks can expand the prefix without listing the bucket.
  #
  # The URI is injected via the container's MONGODB_URI env var — never on
  # the command line, which would leak through `ps aux` to any process that
  # can enumerate its children.
  local service="$1"
  local url db_name prefix
  url="$(env_value MONGO_URL)"
  db_name="${url##*/}"
  db_name="${db_name%%\?*}"
  prefix="mongodb/${RUN_ID}"
  CURRENT_ENGINE="mongodb"; CURRENT_ENGINE_KEY="${prefix}/"; CURRENT_ENGINE_START="$(now_ms)"
  $COMPOSE exec -T -e MONGODB_URI="$url" "$service" \
    bash -c 'mongodump --uri "$MONGODB_URI" --archive --gzip' \
    > "$WORKDIR/${db_name}.archive.gz"
  aws --region "$REGION" s3 cp --quiet \
    "$WORKDIR/${db_name}.archive.gz" "s3://${BUCKET}/${prefix}/${db_name}.archive.gz"
  record_engine mongodb success "$(stat -c%s "$WORKDIR/${db_name}.archive.gz")" "$(( $(now_ms) - CURRENT_ENGINE_START ))" "${prefix}/"
  CURRENT_ENGINE=""
}

backup_redis() {
  # RDB snapshot: trigger BGSAVE, wait for LASTSAVE to advance, then copy the
  # dump out of the service's data directory (volume ./data/<service>).
  # Password injected via REDISCLI_AUTH env — never on the -a argv flag, which
  # would leak through `ps aux`.
  local service="$1"
  local pass key before now
  pass="$(env_value REDIS_PASSWORD)"
  key="redis/${RUN_ID}/dump.rdb"
  CURRENT_ENGINE="redis"; CURRENT_ENGINE_KEY="$key"; CURRENT_ENGINE_START="$(now_ms)"
  # $COMPOSE is a multi-word string; expand it unquoted so the array holds one
  # word per argument (quoting would make the whole string the command name).
  local redis_exec=( $COMPOSE exec -T -e REDISCLI_AUTH="$pass" "$service" )
  before="$("${redis_exec[@]}" redis-cli LASTSAVE | tr -d '[:space:]')"
  "${redis_exec[@]}" redis-cli BGSAVE >/dev/null
  now="$before"
  for _ in $(seq 1 60); do
    now="$("${redis_exec[@]}" redis-cli LASTSAVE | tr -d '[:space:]')"
    [ "$now" != "$before" ] && break
    sleep 1
  done
  if [ "$now" = "$before" ]; then
    echo "redis BGSAVE did not complete within 60s" >&2
    return 1
  fi
  cp "$INSTALL_DIR/data/${service}/dump.rdb" "$WORKDIR/dump.rdb"
  aws --region "$REGION" s3 cp --quiet \
    "$WORKDIR/dump.rdb" "s3://${BUCKET}/${key}"
  record_engine redis success "$(stat -c%s "$WORKDIR/dump.rdb")" "$(( $(now_ms) - CURRENT_ENGINE_START ))" "$key"
  CURRENT_ENGINE=""
}

backup_clickhouse() {
  # Direct-to-S3 via the ephemeral <service>-backup container. A fresh
  # deployment has no application tables yet; clickhouse-backup fails on an
  # empty server ("no tables for backup"). Distinguish that from a broken
  # ClickHouse: the exec below already fails the script when the server is
  # unreachable, so an empty-but-healthy server skips instead of
  # false-failing.
  local service="$1"
  local user pass prefix tables bytes
  user="$(env_value CLICKHOUSE_USER)"
  pass="$(env_value CLICKHOUSE_PASSWORD)"
  prefix="clickhouse/${RUN_ID}/"
  CURRENT_ENGINE="clickhouse"; CURRENT_ENGINE_KEY="$prefix"; CURRENT_ENGINE_START="$(now_ms)"
  # --password on the command line leaks through `ps`; use CLICKHOUSE_PASSWORD
  # env which clickhouse-client honours natively.
  tables="$($COMPOSE exec -T -e CLICKHOUSE_PASSWORD="$pass" "$service" \
    clickhouse-client --user "$user" --query \
    "SELECT count() FROM system.tables WHERE database NOT IN ('system', 'INFORMATION_SCHEMA', 'information_schema')")"
  if [ "$tables" -gt 0 ]; then
    $COMPOSE --profile backup run --rm "${service}-backup" create_remote "$RUN_ID" >/dev/null
    $COMPOSE --profile backup run --rm "${service}-backup" delete_remote older-than 14d >/dev/null || true
    bytes="$(aws --region "$REGION" s3 ls --recursive --summarize "s3://${BUCKET}/${prefix}" | awk '/Total Size/{print $3}')"
    record_engine clickhouse success "${bytes:-0}" "$(( $(now_ms) - CURRENT_ENGINE_START ))" "$prefix"
  else
    echo "clickhouse has no application tables yet; skipped"
    record_engine clickhouse skipped 0 0 ""
  fi
  CURRENT_ENGINE=""
}

# --- Discovery and dispatch --------------------------------------------------
ENGINE_SERVICES="$($COMPOSE config --format json | jq -r '
  .services | to_entries[]
  | select(.value.labels["newbie.backup-engine"] != null)
  | "\(.key)\t\(.value.labels["newbie.backup-engine"])"')"
[ -n "$ENGINE_SERVICES" ] || die "no services carry the newbie.backup-engine label"

COMPLETED_ENGINES=""
while IFS=$'\t' read -r service engine; do
  if ! declare -F "backup_${engine}" >/dev/null; then
    die "label newbie.backup-engine=${engine} on service ${service} has no backup_${engine}() function"
  fi
  # < /dev/null: compose run/exec forward stdin by default, which would
  # consume the loop's remaining service list after the first engine.
  "backup_${engine}" "$service" < /dev/null
  COMPLETED_ENGINES="${COMPLETED_ENGINES:+$COMPLETED_ENGINES, }${engine}"
done <<< "$ENGINE_SERVICES"

# --- Manifest (last write wins the run) --------------------------------------
write_manifest success

# No local cleanup needed — the EXIT trap already rm -rf'd the temp WORKDIR.
# S3 retention (7d default) is enforced by the bucket lifecycle rules.

aws --region "$REGION" cloudwatch put-metric-data \
  --namespace "$APP_NAME" \
  --metric-data "MetricName=BackupFailure,Value=0,Unit=Count,Timestamp=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
trap - ERR
echo "[$(date -Is)] backup completed (run ${RUN_ID}): ${COMPLETED_ENGINES} -> s3://${BUCKET}"
