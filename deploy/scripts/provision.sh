#!/usr/bin/env bash
# Host provisioning for the production EC2 instance.
# Idempotent: safe to re-run via SSM.
#
# Usage: provision.sh <app-name>
#   <app-name> derives the host-side names created here (backup log file,
#   cron file, CloudWatch agent config, log group). It is a required
#   argument: on first boot the host config files may not exist yet.
set -euo pipefail

APP_NAME="${1:-}"
if [ -z "$APP_NAME" ]; then
  echo "usage: $0 <app-name>" >&2
  exit 1
fi

# INSTALL_DIR is derived from this script's location (ADR-006 C1): the host
# layout is <install>/scripts/provision.sh, so the install root is the
# script's parent directory.
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="$(TOKEN=$(curl -sf -X PUT http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60') && \
  curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)"

log() { echo "[provision $(date -Is)] $*"; }

# First-boot runbook (ADR-006 C1): after provisioning, create the two host
# config files at INSTALL_DIR before running start.sh — deploy.config.json
# and env.config.json (schema: scripts/lib.sh). Deploys never overwrite them.

# --- Base packages ------------------------------------------------------------
dnf install -y dnf-utils device-mapper-persistent-data lvm2 jq aws-cli cronie
systemctl enable --now crond

# --- Docker -------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  dnf config-manager --add-repo \
    https://download.docker.com/linux/centos/docker-ce.repo
  # AL2023 sets $releasever to its own full version, which the docker-ce
  # repo does not serve; AL2023 is RHEL9-compatible, so pin to 9.
  sed -i 's/\$releasever/9/g' /etc/yum.repos.d/docker-ce.repo
  dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "default-address-pools": [{ "base": "10.77.0.0/16", "size": 24 }]
}
JSON
systemctl enable --now docker

# --- Data directories (container image UIDs: postgres 70, redis 999,
#     mongo 999, clickhouse 1001) ----------------------------------------------
mkdir -p "$INSTALL_DIR"/data/{postgres,redis,mongo,clickhouse}
chown -R 70:70 "$INSTALL_DIR/data/postgres"
chown -R 999:999 "$INSTALL_DIR/data/redis" "$INSTALL_DIR/data/mongo"
chown -R 1001:1001 "$INSTALL_DIR/data/clickhouse"
chmod 750 "$INSTALL_DIR"/data/*

# --- CloudWatch agent (memory/disk metrics + backup log) ----------------------
CW_AGENT_RPM="/tmp/amazon-cloudwatch-agent.rpm"
if ! rpm -q amazon-cloudwatch-agent >/dev/null 2>&1; then
  # The agent publishes per-arch RPM paths; map uname to its naming.
  case "$(uname -m)" in
    aarch64) CW_AGENT_ARCH=arm64 ;;
    *) CW_AGENT_ARCH=amd64 ;;
  esac
  curl -sf -o "$CW_AGENT_RPM" \
    "https://s3.${REGION}.amazonaws.com/amazoncloudwatch-agent/amazon_linux/${CW_AGENT_ARCH}/latest/amazon-cloudwatch-agent.rpm"
  rpm -U "$CW_AGENT_RPM"
fi
mkdir -p /opt/aws/amazon-cloudwatch-agent/etc
# __APP_NAME__ is substituted after the heredoc (quoted heredoc = no shell
# expansion, so the CloudWatch ${aws:InstanceId} placeholder survives).
cat > /opt/aws/amazon-cloudwatch-agent/etc/${APP_NAME}-cw-config.json <<'JSON'
{
  "agent": { "metrics_collection_interval": 60 },
  "metrics": {
    "namespace": "CWAgent",
    "append_dimensions": { "InstanceId": "${aws:InstanceId}" },
    "aggregation_dimensions": [["InstanceId"]],
    "metrics_collected": {
      "mem": { "measurement": ["mem_used_percent"] },
      "disk": {
        "resources": ["/"],
        "ignore_file_system_types": ["tmpfs", "devtmpfs", "overlay"],
        "measurement": ["used_percent"]
      }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/__APP_NAME__-backup.log",
            "log_group_name": "__APP_NAME__-prod",
            "log_stream_name": "backup"
          }
        ]
      }
    }
  }
}
JSON
sed -i "s|__APP_NAME__|${APP_NAME}|g" \
  /opt/aws/amazon-cloudwatch-agent/etc/${APP_NAME}-cw-config.json
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/${APP_NAME}-cw-config.json >/dev/null

# --- Backup cron --------------------------------------------------------------
touch "/var/log/${APP_NAME}-backup.log"
cat > "/etc/cron.d/${APP_NAME}-backup" <<CRON
7 3 * * * root ${INSTALL_DIR}/scripts/backup.sh >> "/var/log/${APP_NAME}-backup.log" 2>&1
CRON
chmod 0644 "/etc/cron.d/${APP_NAME}-backup"

log "provisioning complete"
