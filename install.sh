#!/usr/bin/env bash
# install.sh — set up linux-backup on a Debian host
#
# Run as root on the target machine:
#   curl -fsSL https://... | bash    (or just: sudo bash install.sh)
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
    cp "$SCRIPT_DIR/backup.conf" "$INSTALL_DIR/"
    echo "  Copied default backup.conf — edit $INSTALL_DIR/backup.conf before first run"
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
echo "     — set S3_BUCKET, AWS_REGION, and review BACKUP_PATHS"
echo "  2. Configure AWS credentials (one of):"
echo "     a) IAM instance role (recommended if on EC2)"
echo "     b) aws configure  (writes to /root/.aws/credentials)"
echo "     c) Environment variables AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY"
echo "  3. Test: bash $INSTALL_DIR/backup.sh"
echo "  4. Check timer: systemctl list-timers linux-backup.timer"
echo "  5. Restore test: bash $INSTALL_DIR/restore.sh"
