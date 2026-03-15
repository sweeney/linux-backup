#!/usr/bin/env bash
# deploy.sh — push updated scripts to the target machine
#
# Usage:
#   ./deploy.sh                        # deploys to default host
#   ./deploy.sh user@192.168.1.10      # deploys to a specific host
set -euo pipefail

TARGET="${1:-100.122.159.5}"
REMOTE_DIR="/opt/linux-backup"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Deploying to $TARGET:$REMOTE_DIR ..."

scp "$SCRIPT_DIR/backup.sh" \
    "$SCRIPT_DIR/restore.sh" \
    "$SCRIPT_DIR/install.sh" \
    "${TARGET}:/tmp/"

ssh -t "$TARGET" "
    sudo cp /tmp/backup.sh /tmp/restore.sh /tmp/install.sh $REMOTE_DIR/ &&
    sudo chmod 700 $REMOTE_DIR/backup.sh $REMOTE_DIR/restore.sh $REMOTE_DIR/install.sh &&
    echo 'Done. Deployed:' &&
    sudo ls -la $REMOTE_DIR/*.sh
"
