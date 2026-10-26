#!/usr/bin/env bash
# deploy.sh — push updated scripts to a host that already ran install.sh
#
# Usage:
#   ./deploy.sh user@host
#
# Only the scripts are pushed. The host's backup.conf and hooks are left alone:
# they belong to the host's own repo and deploy.
set -euo pipefail

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "Usage: $0 user@host" >&2; exit 2; }

REMOTE_DIR="/opt/linux-backup"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Deploying to $TARGET:$REMOTE_DIR ..."

scp "$SCRIPT_DIR/backup.sh" \
    "$SCRIPT_DIR/restore.sh" \
    "$SCRIPT_DIR/install.sh" \
    "${TARGET}:/tmp/"

ssh -t "$TARGET" "
    sudo test -d $REMOTE_DIR || { echo 'ERROR: $REMOTE_DIR missing; run install.sh first' >&2; exit 1; } &&
    sudo cp /tmp/backup.sh /tmp/restore.sh /tmp/install.sh $REMOTE_DIR/ &&
    sudo chmod 700 $REMOTE_DIR/backup.sh $REMOTE_DIR/restore.sh $REMOTE_DIR/install.sh &&
    echo 'Done. Deployed:' &&
    sudo ls -la $REMOTE_DIR/
"
