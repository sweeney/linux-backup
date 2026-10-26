#!/usr/bin/env bash
# install.sh — set up linux-backup on a Debian host
#
# Run as root on the target machine, from a copy of this repo:
#   sudo bash install.sh
#
# Installs the scripts to /opt/linux-backup and a systemd timer. If a
# backup.conf sits next to this script it is installed; otherwise
# backup.conf.example is, for you to edit. An existing config is never
# overwritten.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/linux-backup"
TIMER_SCHEDULE="daily"   # systemd OnCalendar value — change to e.g. "daily" or "*-*-* 02:00:00"

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root" >&2; exit 1; }

echo "=== linux-backup installer ==="
echo

# ── Install dependencies ──────────────────────────────────────────────────────

echo "--- Installing dependencies ---"
apt-get update -qq
apt-get install -y --no-install-recommends \
    awscli \
    tar \
    gzip \
    curl \
    mariadb-client

# ── Deploy scripts ────────────────────────────────────────────────────────────

echo "--- Deploying to $INSTALL_DIR ---"
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/backup.sh"  "$INSTALL_DIR/"
cp "$SCRIPT_DIR/restore.sh" "$INSTALL_DIR/"

if [[ ! -f "$INSTALL_DIR/backup.conf" ]]; then
    if [[ -f "$SCRIPT_DIR/backup.conf" ]]; then
        cp "$SCRIPT_DIR/backup.conf" "$INSTALL_DIR/backup.conf"
        echo "  Installed backup.conf"
    else
        cp "$SCRIPT_DIR/backup.conf.example" "$INSTALL_DIR/backup.conf"
        echo "  Installed backup.conf.example as backup.conf — edit it before first run"
    fi
else
    echo "  backup.conf already exists, not overwriting"
fi

chmod 700 "$INSTALL_DIR/backup.sh" "$INSTALL_DIR/restore.sh"
chmod 600 "$INSTALL_DIR/backup.conf"

# ── Create systemd service ────────────────────────────────────────────────────

echo "--- Creating systemd service and timer ---"

cat > /etc/systemd/system/linux-backup.service <<EOF
[Unit]
Description=Linux backup to S3
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/backup.sh $INSTALL_DIR/backup.conf
StandardOutput=journal
StandardError=journal
EOF

cat > /etc/systemd/system/linux-backup.timer <<EOF
[Unit]
Description=Run linux-backup $TIMER_SCHEDULE

[Timer]
OnCalendar=$TIMER_SCHEDULE
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now linux-backup.timer

echo
echo "=== Installation complete ==="
echo
echo "Next steps:"
echo "  1. Edit $INSTALL_DIR/backup.conf"
echo "     — set S3_BUCKET, AWS_REGION, and review BACKUP_PATHS and PRE_BACKUP_HOOKS_DIR"
echo "  2. Configure AWS credentials (one of):"
echo "     a) IAM instance role (recommended if on EC2)"
echo "     b) aws configure  (writes to /root/.aws/credentials)"
echo "     c) Environment variables AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY"
echo "  3. Test: bash $INSTALL_DIR/backup.sh"
echo "  4. Check timer: systemctl list-timers linux-backup.timer"
echo "  5. Restore test: bash $INSTALL_DIR/restore.sh"
