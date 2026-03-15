#!/usr/bin/env bash
# backup.sh — archive configured paths and upload to S3
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-$SCRIPT_DIR/backup.conf}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: config file not found: $CONFIG_FILE" >&2
    exit 1
fi

# shellcheck source=backup.conf
source "$CONFIG_FILE"

HOSTNAME="$(hostname -s)"
TIMESTAMP="$(date -u '+%Y-%m-%d_%H%M%S')"
ARCHIVE_NAME="${HOSTNAME}_${TIMESTAMP}.tar.gz"
STAGING_FILE="${STAGING_DIR}/${ARCHIVE_NAME}"
START_TIME="$(date +%s)"
CURRENT_STAGE="init"

# ── Logging ──────────────────────────────────────────────────────────────────

log() {
    local msg="[$(date -u '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "$msg" >> "$LOG_FILE"
    fi
}

die() {
    log "ERROR: $*"
    mqtt_publish "failed" "\"stage\":\"${CURRENT_STAGE}\",\"error\":\"$*\""
    exit 1
}

# ── MQTT ──────────────────────────────────────────────────────────────────────

mqtt_publish() {
    local state="$1"
    local extra="${2:-}"
    [[ -n "${MQTT_BROKER:-}" ]] || return 0

    local topic="${MQTT_TOPIC_PREFIX}/${HOSTNAME}"
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local payload="{\"state\":\"${state}\",\"host\":\"${HOSTNAME}\",\"timestamp\":\"${ts}\""
    [[ -n "$extra" ]] && payload="${payload},${extra}"
    payload="${payload}}"

    local auth_args=()
    [[ -n "${MQTT_USERNAME:-}" ]] && auth_args+=(-u "$MQTT_USERNAME")
    [[ -n "${MQTT_PASSWORD:-}" ]] && auth_args+=(-P "$MQTT_PASSWORD")

    mosquitto_pub \
        -h "$MQTT_BROKER" \
        -p "${MQTT_PORT:-1883}" \
        "${auth_args[@]}" \
        -t "$topic" \
        -m "$payload" \
    || log "WARNING: failed to publish MQTT event (state=$state)"
}

# ── Preflight ─────────────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || die "must run as root"
command -v aws  &>/dev/null || die "aws CLI not found — run install.sh first"
command -v tar  &>/dev/null || die "tar not found"

if [[ -n "${GPG_RECIPIENT:-}" ]]; then
    command -v gpg &>/dev/null || die "gpg not found but GPG_RECIPIENT is set"
fi

if [[ -n "${MARIADB_DATABASES:-}" ]]; then
    command -v mysqldump &>/dev/null || die "mysqldump not found but MARIADB_DATABASES is set"
fi

mkdir -p "$STAGING_DIR"
mqtt_publish "started"

# ── Dump MariaDB databases ────────────────────────────────────────────────────

DB_DUMP_DIR="${STAGING_DIR}/mariadb-dumps"

if [[ -n "${MARIADB_DATABASES:-}" ]]; then
    CURRENT_STAGE="mariadb_dump"
    mkdir -p "$DB_DUMP_DIR"
    for db in $MARIADB_DATABASES; do
        DUMP_FILE="${DB_DUMP_DIR}/${db}.sql.gz"
        log "Dumping database: $db -> $DUMP_FILE"
        mysqldump \
            --single-transaction \
            --routines \
            --triggers \
            --events \
            "$db" \
        | gzip > "$DUMP_FILE" \
        || die "mysqldump failed for database: $db"
    done
fi

# ── Build exclude args ─────────────────────────────────────────────────────────

EXCLUDE_ARGS=()
for pattern in "${EXCLUDE_PATHS[@]:-}"; do
    EXCLUDE_ARGS+=("--exclude=${pattern}")
done

# ── Filter to paths that actually exist ───────────────────────────────────────

EXISTING_PATHS=()
for p in "${BACKUP_PATHS[@]}"; do
    if [[ -e "$p" ]]; then
        EXISTING_PATHS+=("$p")
    else
        log "WARNING: path not found, skipping: $p"
    fi
done

[[ ${#EXISTING_PATHS[@]} -gt 0 ]] || die "no backup paths exist — nothing to do"

# Include DB dumps in archive if they were produced
if [[ -d "$DB_DUMP_DIR" ]]; then
    EXISTING_PATHS+=("$DB_DUMP_DIR")
fi

# ── Create archive ────────────────────────────────────────────────────────────

CURRENT_STAGE="archive"
log "Creating archive: $STAGING_FILE"
tar czf "$STAGING_FILE" \
    "${EXCLUDE_ARGS[@]}" \
    --ignore-failed-read \
    "${EXISTING_PATHS[@]}"
TAR_EXIT=$?
# exit 1 = warnings only (e.g. files changed while reading); exit 2 = fatal
(( TAR_EXIT <= 1 )) || die "tar failed (exit $TAR_EXIT)"

ARCHIVE_SIZE="$(du -sh "$STAGING_FILE" | cut -f1)"
log "Archive size: $ARCHIVE_SIZE"

# ── Optionally encrypt ────────────────────────────────────────────────────────

UPLOAD_FILE="$STAGING_FILE"

if [[ -n "${GPG_RECIPIENT:-}" ]]; then
    log "Encrypting for recipient: $GPG_RECIPIENT"
    gpg --batch --yes --trust-model always \
        --recipient "$GPG_RECIPIENT" \
        --output "${STAGING_FILE}.gpg" \
        --encrypt "$STAGING_FILE" \
    || die "gpg encryption failed"
    rm -f "$STAGING_FILE"
    UPLOAD_FILE="${STAGING_FILE}.gpg"
    ARCHIVE_NAME="${ARCHIVE_NAME}.gpg"
fi

# ── Upload to S3 ──────────────────────────────────────────────────────────────

S3_KEY="${S3_PREFIX}/${HOSTNAME}/${ARCHIVE_NAME}"
S3_URI="s3://${S3_BUCKET}/${S3_KEY}"

CURRENT_STAGE="upload"
log "Uploading to $S3_URI"
aws s3 cp "$UPLOAD_FILE" "$S3_URI" \
    ${AWS_REGION:+--region "$AWS_REGION"} \
    --storage-class STANDARD_IA \
|| die "S3 upload failed"

rm -f "$UPLOAD_FILE"
rm -rf "$DB_DUMP_DIR"
log "Upload complete, local staging files removed"

# ── Prune old backups ─────────────────────────────────────────────────────────

CURRENT_STAGE="prune"
log "Checking retention (keep newest $RETENTION_COUNT)"
S3_PREFIX_PATH="${S3_PREFIX}/${HOSTNAME}/"

# List all backups sorted oldest-first, delete any beyond RETENTION_COUNT
mapfile -t ALL_KEYS < <(
    aws s3api list-objects-v2 \
        --bucket "$S3_BUCKET" \
        --prefix "$S3_PREFIX_PATH" \
        ${AWS_REGION:+--region "$AWS_REGION"} \
        --query 'sort_by(Contents, &LastModified)[].Key' \
        --output text \
    | tr '\t' '\n' \
    | grep -v '^$'
)

COUNT=${#ALL_KEYS[@]}
log "Found $COUNT backup(s) in S3"

if (( COUNT > RETENTION_COUNT )); then
    DELETE_COUNT=$(( COUNT - RETENTION_COUNT ))
    log "Deleting $DELETE_COUNT old backup(s)"
    for key in "${ALL_KEYS[@]:0:$DELETE_COUNT}"; do
        log "  Deleting: $key"
        aws s3 rm "s3://${S3_BUCKET}/${key}" \
            ${AWS_REGION:+--region "$AWS_REGION"}
    done
fi

DURATION=$(( $(date +%s) - START_TIME ))
RETAINED=$(( COUNT > RETENTION_COUNT ? RETENTION_COUNT : COUNT ))
mqtt_publish "completed" \
    "\"duration_seconds\":${DURATION},\"archive_size\":\"${ARCHIVE_SIZE}\",\"s3_uri\":\"${S3_URI}\",\"backups_retained\":${RETAINED}"
log "Backup complete: $S3_URI"
