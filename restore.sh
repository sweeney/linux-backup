#!/usr/bin/env bash
# restore.sh — list or restore a backup from S3
#
# Usage:
#   restore.sh                    — list available backups
#   restore.sh latest             — restore the most recent backup
#   restore.sh <backup-filename>  — restore a specific backup by name
#   restore.sh --dest /target     — restore to a specific root (default: /)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG:-$SCRIPT_DIR/backup.conf}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: config file not found: $CONFIG_FILE" >&2
    exit 1
fi

# shellcheck source=backup.conf
source "$CONFIG_FILE"

HOSTNAME_TARGET="$(hostname -s)"
DEST_ROOT="/"
SELECTED=""

# ── Parse args ────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dest)
            DEST_ROOT="$2"
            shift 2
            ;;
        --host)
            # restore backups from a different hostname (e.g. when replacing hardware)
            HOSTNAME_TARGET="$2"
            shift 2
            ;;
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            SELECTED="$1"
            shift
            ;;
    esac
done

S3_PREFIX_PATH="${S3_PREFIX}/${HOSTNAME_TARGET}/"

# ── List mode ─────────────────────────────────────────────────────────────────

list_backups() {
    echo "Available backups for host '${HOSTNAME_TARGET}':"
    echo
    aws s3api list-objects-v2 \
        --bucket "$S3_BUCKET" \
        --prefix "$S3_PREFIX_PATH" \
        ${AWS_REGION:+--region "$AWS_REGION"} \
        --query 'sort_by(Contents, &LastModified)[].{Key:Key,Size:Size,Date:LastModified}' \
        --output table 2>/dev/null \
    || echo "  (none found, or bucket not accessible)"
}

if [[ -z "$SELECTED" ]]; then
    list_backups
    echo
    echo "To restore: $0 latest"
    echo "       or:  $0 <filename>"
    echo "       or:  $0 latest --dest /mnt/restore"
    exit 0
fi

# ── Resolve 'latest' ──────────────────────────────────────────────────────────

if [[ "$SELECTED" == "latest" ]]; then
    SELECTED="$(
        aws s3api list-objects-v2 \
            --bucket "$S3_BUCKET" \
            --prefix "$S3_PREFIX_PATH" \
            ${AWS_REGION:+--region "$AWS_REGION"} \
            --query 'sort_by(Contents, &LastModified)[-1].Key' \
            --output text
    )"
    [[ -n "$SELECTED" && "$SELECTED" != "None" ]] || { echo "No backups found." >&2; exit 1; }
    # SELECTED is now the full S3 key; extract filename
    FILENAME="$(basename "$SELECTED")"
else
    FILENAME="$SELECTED"
    SELECTED="${S3_PREFIX_PATH}${FILENAME}"
fi

# ── Preflight ─────────────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || { echo "ERROR: must run as root" >&2; exit 1; }
command -v aws &>/dev/null || { echo "ERROR: aws CLI not found" >&2; exit 1; }

S3_URI="s3://${S3_BUCKET}/${SELECTED}"
STAGING_FILE="${STAGING_DIR}/${FILENAME}"

# ── Confirm ───────────────────────────────────────────────────────────────────

echo "Restore source : $S3_URI"
echo "Restore target : $DEST_ROOT"
echo
read -r -p "Proceed? Files will be overwritten. [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── Download ──────────────────────────────────────────────────────────────────

mkdir -p "$STAGING_DIR"
echo "Downloading $FILENAME ..."
aws s3 cp "$S3_URI" "$STAGING_FILE" \
    ${AWS_REGION:+--region "$AWS_REGION"} \
|| { echo "ERROR: download failed" >&2; exit 1; }

# ── Decrypt if needed ─────────────────────────────────────────────────────────

EXTRACT_FILE="$STAGING_FILE"

if [[ "$FILENAME" == *.gpg ]]; then
    echo "Decrypting ..."
    DECRYPTED="${STAGING_FILE%.gpg}"
    gpg --batch --yes --output "$DECRYPTED" --decrypt "$STAGING_FILE" \
    || { echo "ERROR: gpg decryption failed" >&2; rm -f "$STAGING_FILE"; exit 1; }
    rm -f "$STAGING_FILE"
    EXTRACT_FILE="$DECRYPTED"
fi

# ── Extract ───────────────────────────────────────────────────────────────────

echo "Extracting to $DEST_ROOT ..."
tar xzf "$EXTRACT_FILE" -C "$DEST_ROOT" --same-permissions \
|| { echo "ERROR: extraction failed" >&2; rm -f "$EXTRACT_FILE"; exit 1; }

rm -f "$EXTRACT_FILE"

# ── Restore MariaDB dumps (only when restoring to /) ─────────────────────────

DB_DUMP_DIR="${DEST_ROOT%/}/tmp/backup-staging/mariadb-dumps"

if [[ "$DEST_ROOT" == "/" && -d "$DB_DUMP_DIR" ]]; then
    echo
    echo "Found MariaDB dumps in $DB_DUMP_DIR"
    for dump in "$DB_DUMP_DIR"/*.sql.gz; do
        [[ -f "$dump" ]] || continue
        db="$(basename "$dump" .sql.gz)"
        echo "Restoring database: $db"
        mysql -e "CREATE DATABASE IF NOT EXISTS \`${db}\`;" \
        && zcat "$dump" | mysql "$db" \
        || echo "WARNING: failed to restore $db — you may need to do it manually"
    done
    rm -rf "$DB_DUMP_DIR"
fi

echo
echo "Restore complete."
if [[ "$DEST_ROOT" == "/" ]]; then
    echo "You may need to:"
    echo "  systemctl daemon-reload"
    echo "  systemctl restart mosquitto asterisk asterisk-mqtt ups-mqtt"
    echo "  fwconsole reload    # if FreePBX config was restored"
fi
