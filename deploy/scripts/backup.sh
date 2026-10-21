#!/usr/bin/env bash
# Nightly backup of all four stateful stores into S3.
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
WORKDIR="${INSTALL_DIR}/backup-tmp"
mkdir -p "$WORKDIR"

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
  aws --region "$REGION" s3 cp --quiet \
    "$WORKDIR/manifest.json" "s3://${BUCKET}/manifests/${RUN_ID}.json" || true
}

signal_failure() {
  local failed_engine="${CURRENT_ENGINE:-unknown}"
  if [ -n "$CURRENT_ENGINE" ]; then
    record_engine "$CURRENT_ENGINE" failed 0 "$(( $(now_ms) - CURRENT_ENGINE_START ))" "$CURRENT_ENGINE_KEY"
    CURRENT_ENGINE=""
  fi
  write_manifest failed
  aws --region "$REGION" cloudwatch put-metric-data \
    --namespace "$APP_NAME" \
    --metric-data "MetricName=BackupFailure,Value=1,Unit=Count,Timestamp=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" || true
  echo "[$(date -Is)] BACKUP FAILED (engine: ${failed_engine})" >&2
}
trap signal_failure ERR

# --- PostgreSQL --------------------------------------------------------------
PG_USER="$(env_value POSTGRES_USER)"
PG_DB="$(env_value POSTGRES_DB)"
PG_KEY="postgres/${RUN_ID}/${APP_NAME}.pgdump"
CURRENT_ENGINE="postgres"; CURRENT_ENGINE_KEY="$PG_KEY"; CURRENT_ENGINE_START="$(now_ms)"
$COMPOSE exec -T postgres \
  pg_dump -U "$PG_USER" -d "$PG_DB" -Fc --no-owner --no-privileges \
  > "$WORKDIR/${APP_NAME}.pgdump"
aws --region "$REGION" s3 cp --quiet \
  "$WORKDIR/${APP_NAME}.pgdump" "s3://${BUCKET}/${PG_KEY}"
record_engine postgres success "$(stat -c%s "$WORKDIR/${APP_NAME}.pgdump")" "$(( $(now_ms) - CURRENT_ENGINE_START ))" "$PG_KEY"
CURRENT_ENGINE=""

# --- MongoDB -----------------------------------------------------------------
# Single database: the whole app shares one Mongoose connection whose URI
# selects the database (MONGO_URL), and modules reuse that connection, so
# every collection lives in that one database. The database name is parsed
# from MONGO_URL — the secret owns it. The engine key is the run prefix
# (trailing slash); the archive file name is fixed (<db>.archive.gz) so
# restore runbooks can expand the prefix without listing the bucket.
MONGO_USER="$(env_value MONGO_INITDB_ROOT_USERNAME)"
MONGO_PASS="$(env_value MONGO_INITDB_ROOT_PASSWORD)"
MONGO_URL_VALUE="$(env_value MONGO_URL)"
MONGO_DB_NAME="${MONGO_URL_VALUE##*/}"
MONGO_DB_NAME="${MONGO_DB_NAME%%\?*}"
MONGO_PREFIX="mongodb/${RUN_ID}"
CURRENT_ENGINE="mongodb"; CURRENT_ENGINE_KEY="${MONGO_PREFIX}/"; CURRENT_ENGINE_START="$(now_ms)"
$COMPOSE exec -T mongo mongodump \
  --uri "mongodb://${MONGO_USER}:${MONGO_PASS}@127.0.0.1:27017/${MONGO_DB_NAME}?authSource=admin" \
  --archive --gzip > "$WORKDIR/${MONGO_DB_NAME}.archive.gz"
aws --region "$REGION" s3 cp --quiet \
  "$WORKDIR/${MONGO_DB_NAME}.archive.gz" "s3://${BUCKET}/${MONGO_PREFIX}/${MONGO_DB_NAME}.archive.gz"
record_engine mongodb success "$(stat -c%s "$WORKDIR/${MONGO_DB_NAME}.archive.gz")" "$(( $(now_ms) - CURRENT_ENGINE_START ))" "${MONGO_PREFIX}/"
CURRENT_ENGINE=""

# --- Redis (RDB snapshot) ----------------------------------------------------
REDIS_PASS="$(env_value REDIS_PASSWORD)"
REDIS_KEY="redis/${RUN_ID}/dump.rdb"
CURRENT_ENGINE="redis"; CURRENT_ENGINE_KEY="$REDIS_KEY"; CURRENT_ENGINE_START="$(now_ms)"
LASTSAVE_BEFORE="$($COMPOSE exec -T redis redis-cli -a "$REDIS_PASS" --no-auth-warning LASTSAVE | tr -d '[:space:]')"
$COMPOSE exec -T redis redis-cli -a "$REDIS_PASS" --no-auth-warning BGSAVE >/dev/null
for _ in $(seq 1 60); do
  LASTSAVE_NOW="$($COMPOSE exec -T redis redis-cli -a "$REDIS_PASS" --no-auth-warning LASTSAVE | tr -d '[:space:]')"
  [ "$LASTSAVE_NOW" != "$LASTSAVE_BEFORE" ] && break
  sleep 1
done
cp "$INSTALL_DIR/data/redis/dump.rdb" "$WORKDIR/dump.rdb"
aws --region "$REGION" s3 cp --quiet \
  "$WORKDIR/dump.rdb" "s3://${BUCKET}/${REDIS_KEY}"
record_engine redis success "$(stat -c%s "$WORKDIR/dump.rdb")" "$(( $(now_ms) - CURRENT_ENGINE_START ))" "$REDIS_KEY"
CURRENT_ENGINE=""

# --- ClickHouse (direct-to-S3 via ephemeral backup container) ----------------
# A fresh deployment has no application tables yet; clickhouse-backup fails
# on an empty server ("no tables for backup"). Distinguish that from a broken
# ClickHouse: the exec below already fails the script when the server is
# unreachable, so an empty-but-healthy server skips instead of false-failing.
CH_USER="$(env_value CLICKHOUSE_USER)"
CH_PASS="$(env_value CLICKHOUSE_PASSWORD)"
CH_PREFIX="clickhouse/${RUN_ID}/"
CURRENT_ENGINE="clickhouse"; CURRENT_ENGINE_KEY="$CH_PREFIX"; CURRENT_ENGINE_START="$(now_ms)"
CH_TABLES="$($COMPOSE exec -T clickhouse clickhouse-client \
  --user "$CH_USER" --password "$CH_PASS" \
  --query "SELECT count() FROM system.tables WHERE database NOT IN ('system', 'INFORMATION_SCHEMA', 'information_schema')")"
if [ "$CH_TABLES" -gt 0 ]; then
  $COMPOSE --profile backup run --rm clickhouse-backup create_remote "$RUN_ID" >/dev/null
  $COMPOSE --profile backup run --rm clickhouse-backup delete_remote older-than 14d >/dev/null || true
  CH_BYTES="$(aws --region "$REGION" s3 ls --recursive --summarize "s3://${BUCKET}/${CH_PREFIX}" | awk '/Total Size/{print $3}')"
  record_engine clickhouse success "${CH_BYTES:-0}" "$(( $(now_ms) - CURRENT_ENGINE_START ))" "$CH_PREFIX"
else
  echo "clickhouse has no application tables yet; skipped"
  record_engine clickhouse skipped 0 0 ""
fi
CURRENT_ENGINE=""

# --- Manifest (last write wins the run) --------------------------------------
write_manifest success

# --- Local cleanup (S3 retention is enforced by bucket lifecycle rules) -----
find "$WORKDIR" -type f -mtime +7 -delete

aws --region "$REGION" cloudwatch put-metric-data \
  --namespace "$APP_NAME" \
  --metric-data "MetricName=BackupFailure,Value=0,Unit=Count,Timestamp=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
trap - ERR
echo "[$(date -Is)] backup completed (run ${RUN_ID}): postgres, mongodb, redis, clickhouse -> s3://${BUCKET}"
