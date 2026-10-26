#!/usr/bin/env bash
# backup.sh — archive configured paths and upload to S3
set -euo pipefail
umask 077   # staging dumps and archives may hold secrets

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-$SCRIPT_DIR/backup.conf}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: config file not found: $CONFIG_FILE" >&2
    exit 1
fi

# shellcheck source=backup.conf.example
source "$CONFIG_FILE"

HOSTNAME="$(hostname -s)"
TIMESTAMP="$(date -u '+%Y-%m-%d_%H%M%S')"
ARCHIVE_NAME="${HOSTNAME}_${TIMESTAMP}.tar.gz"
STAGING_FILE="${STAGING_DIR}/${ARCHIVE_NAME}"
START_TIME="$(date +%s)"
CURRENT_STAGE="init"

# ── Logging ──────────────────────────────────────────────────────────────────

log() {
    local msg
    msg="[$(date -u '+%Y-%m-%d %H:%M:%S')] $*"
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

# id -u rather than $EUID so tests can stand in for root with a stub id
[[ "$(id -u)" -eq 0 ]] || die "must run as root"
command -v aws  &>/dev/null || die "aws CLI not found — run install.sh first"
command -v tar  &>/dev/null || die "tar not found"

if [[ -n "${GPG_RECIPIENT:-}" ]]; then
    command -v gpg &>/dev/null || die "gpg not found but GPG_RECIPIENT is set"
    # Fail before the dumps, not after: the key must be in root's keyring
    gpg --batch --list-keys "$GPG_RECIPIENT" &>/dev/null \
        || die "GPG key not found in keyring: $GPG_RECIPIENT"
fi

# mariadb-dump is the name on newer MariaDB; mysqldump is the older alias
MYSQLDUMP=""
if [[ -n "${MARIADB_DATABASES:-}" ]]; then
    MYSQLDUMP="$(command -v mariadb-dump || command -v mysqldump || true)"
    [[ -n "$MYSQLDUMP" ]] || die "mariadb-dump/mysqldump not found but MARIADB_DATABASES is set"
fi

mkdir -p "$STAGING_DIR"

DB_DUMP_DIR="${STAGING_DIR}/mariadb-dumps"
HOOKS_OUTPUT_DIR="${STAGING_DIR}/hooks"
# Leftovers from a run that died must not end up in this archive
rm -rf "$DB_DUMP_DIR" "$HOOKS_OUTPUT_DIR"

mqtt_publish "started"

# ── Dump MariaDB databases ────────────────────────────────────────────────────

if [[ -n "${MARIADB_DATABASES:-}" ]]; then
    CURRENT_STAGE="mariadb_dump"
    mkdir -p "$DB_DUMP_DIR"
    for db in $MARIADB_DATABASES; do
        DUMP_FILE="${DB_DUMP_DIR}/${db}.sql.gz"
        log "Dumping database: $db -> $DUMP_FILE"
        "$MYSQLDUMP" \
            --single-transaction \
            --routines \
            --triggers \
            --events \
            "$db" \
        | gzip > "$DUMP_FILE" \
        || die "mysqldump failed for database: $db"
    done
fi

# ── Run pre-backup hooks ──────────────────────────────────────────────────────
#
# Each executable in PRE_BACKUP_HOOKS_DIR runs in name order with an empty
# directory in $BACKUP_HOOK_OUTPUT_DIR, which goes into the archive. A hook that
# fails or times out does not stop the backup: everything else is still worth
# uploading. But the run then ends with a "failed" event (stage hook:<name>)
# instead of "completed", and exits non-zero so the systemd unit shows failed.

HOOKS_FAILED=()

run_hook() {
    local hook="$1" name out rc=0
    name="$(basename "$hook")"
    out="${HOOKS_OUTPUT_DIR}/${name}"
    mkdir -p "$out"

    local cmd=("$hook")
    [[ -n "$TIMEOUT_CMD" ]] && cmd=("$TIMEOUT_CMD" "$HOOK_TIMEOUT" "$hook")

    log "Running hook: $name"
    BACKUP_HOOK_OUTPUT_DIR="$out" \
    BACKUP_HOSTNAME="$HOSTNAME" \
    BACKUP_TIMESTAMP="$TIMESTAMP" \
        "${cmd[@]}" </dev/null 2>&1 \
    | while IFS= read -r line || [[ -n "$line" ]]; do log "  [$name] $line"; done \
    || rc=$?

    if (( rc == 124 )) && [[ -n "$TIMEOUT_CMD" ]]; then
        log "ERROR: hook timed out after ${HOOK_TIMEOUT}s: $name"
        HOOKS_FAILED+=("$name")
    elif (( rc != 0 )); then
        log "ERROR: hook failed (exit $rc): $name"
        HOOKS_FAILED+=("$name")
    fi
}

if [[ -n "${PRE_BACKUP_HOOKS_DIR:-}" ]]; then
    CURRENT_STAGE="hooks"
    HOOK_TIMEOUT="${HOOK_TIMEOUT:-600}"
    TIMEOUT_CMD="$(command -v timeout || true)"
    [[ -n "$TIMEOUT_CMD" ]] || log "WARNING: timeout not found; hooks run without a time limit"

    if [[ ! -d "$PRE_BACKUP_HOOKS_DIR" ]]; then
        log "ERROR: PRE_BACKUP_HOOKS_DIR not found: $PRE_BACKUP_HOOKS_DIR"
        HOOKS_FAILED+=("PRE_BACKUP_HOOKS_DIR")
    else
        for hook in "$PRE_BACKUP_HOOKS_DIR"/*; do
            [[ -f "$hook" ]] || continue
            if [[ ! -x "$hook" ]]; then
                log "WARNING: hook not executable, skipping: $hook"
                continue
            fi
            run_hook "$hook"
        done
    fi
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

# Include DB dumps and hook output in archive if they were produced
for d in "$DB_DUMP_DIR" "$HOOKS_OUTPUT_DIR"; do
    if [[ -d "$d" ]]; then EXISTING_PATHS+=("$d"); fi
done

# ── Create archive ────────────────────────────────────────────────────────────

CURRENT_STAGE="archive"
log "Creating archive: $STAGING_FILE"
TAR_EXIT=0
tar czf "$STAGING_FILE" \
    "${EXCLUDE_ARGS[@]}" \
    --ignore-failed-read \
    "${EXISTING_PATHS[@]}" \
|| TAR_EXIT=$?
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
rm -rf "$DB_DUMP_DIR" "$HOOKS_OUTPUT_DIR"
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
RESULT="\"duration_seconds\":${DURATION},\"archive_size\":\"${ARCHIVE_SIZE}\",\"s3_uri\":\"${S3_URI}\",\"backups_retained\":${RETAINED}"

if (( ${#HOOKS_FAILED[@]} > 0 )); then
    HOOKS_FAILED_JSON=""
    for name in "${HOOKS_FAILED[@]}"; do
        HOOKS_FAILED_JSON+="${HOOKS_FAILED_JSON:+,}\"${name}\""
    done
    log "ERROR: uploaded $S3_URI, but ${#HOOKS_FAILED[@]} hook(s) failed: ${HOOKS_FAILED[*]}"
    mqtt_publish "failed" \
        "\"stage\":\"hook:${HOOKS_FAILED[0]}\",\"error\":\"${#HOOKS_FAILED[@]} hook(s) failed\",\"hooks_failed\":[${HOOKS_FAILED_JSON}],${RESULT}"
    exit 1
fi

mqtt_publish "completed" "$RESULT"
log "Backup complete: $S3_URI"
