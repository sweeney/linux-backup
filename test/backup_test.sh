#!/usr/bin/env bash
# backup_test.sh: tests for backup.sh.
#
# Whole runs of backup.sh against stubs (see make_stubs in lib.sh): S3 is a
# directory, MQTT payloads land in a file, and `id -u` says root.

# shellcheck disable=SC2016 # hook bodies are single-quoted to expand when the hook runs
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"
script=$root/backup.sh

echo "backup.sh"

assert_exit "parses (bash -n)" 0 bash -n "$script"

STATE=$(mktemp -d)
STUBS=$(mktemp -d)
TARSTUB=$(mktemp -d)
WORK=$(mktemp -d)
export STATE
trap 'rm -rf "$STATE" "$STUBS" "$TARSTUB" "$WORK"' EXIT
make_stubs "$STUBS"
make_tar_stub "$TARSTUB"
HOST=$(hostname -s)

# scenario: fresh state, one path to back up, an empty hooks dir, and a config
# in $WORK/backup.conf. Tests append to the config to vary it.
scenario() {
    rm -rf "${STATE:?}"/* "${WORK:?}"/*
    mkdir -p "$STATE/s3" "$WORK/etc/svc" "$WORK/hooks"
    echo "setting=1" >"$WORK/etc/svc/svc.conf"
    cat >"$WORK/backup.conf" <<EOF
S3_BUCKET="test-bucket"
S3_PREFIX="linux-backup"
AWS_REGION=""
MARIADB_DATABASES=""
PRE_BACKUP_HOOKS_DIR=""
BACKUP_PATHS=( "$WORK/etc/svc" "$WORK/missing" )
EXCLUDE_PATHS=( "*.log" )
RETENTION_COUNT=30
GPG_RECIPIENT=""
STAGING_DIR="$WORK/staging"
LOG_FILE=""
MQTT_BROKER="localhost"
MQTT_PORT="1883"
MQTT_USERNAME=""
MQTT_PASSWORD=""
MQTT_TOPIC_PREFIX="backups"
EOF
}
conf() { echo "$1" >>"$WORK/backup.conf"; }

# hook NAME BODY: an executable hook script in $WORK/hooks.
hook() {
    printf '#!/usr/bin/env bash\n%s\n' "$2" >"$WORK/hooks/$1"
    chmod +x "$WORK/hooks/$1"
}

# run: backup.sh as a separate process on the stubs. Sets $rc and $output.
# Pass a tar stub dir, or "realtar" to use the system's GNU tar.
run() {
    local tardir=$TARSTUB
    [[ "${1:-}" == realtar ]] && tardir=""
    rc=0
    output=$(PATH="$STUBS${tardir:+:$tardir}:$PATH" bash "$script" "$WORK/backup.conf" </dev/null 2>&1) || rc=$?
}
mqtt_last() { tail -n 1 "$STATE/mqtt" 2>/dev/null || true; }
uploads() { find "$STATE/s3" -type f | wc -l | tr -d ' '; }
calls() { cat "$STATE/calls" 2>/dev/null || true; }
tar_args() { cat "$STATE/tar_args" 2>/dev/null || true; }

# --- preconditions ---

scenario
echo 1000 >"$STATE/uid"
run
assert_eq "not root: exits 1" 1 "$rc"
assert_contains "not root: says so" "$output" "must run as root"
assert_eq "not root: nothing uploaded" 0 "$(uploads)"

rc=0
output=$(PATH="$STUBS:$TARSTUB:$PATH" bash "$script" "$WORK/nope.conf" 2>&1) || rc=$?
assert_eq "missing config: exits 1" 1 "$rc"
assert_contains "missing config: says so" "$output" "config file not found"

# --- a plain run ---

scenario
run
assert_eq "plain: exits 0" 0 "$rc"
assert_eq "plain: one upload" 1 "$(uploads)"
assert_contains "plain: archive named host_timestamp" "$(ls "$STATE/s3")" "${HOST}_"
assert_contains "plain: warns about missing path" "$output" "path not found, skipping: $WORK/missing"
assert_contains "plain: archives the path" "$(tar_args)" "$WORK/etc/svc"
assert_not_contains "plain: no hooks dir in archive" "$(tar_args)" "$WORK/staging/hooks"
assert_contains "plain: started event" "$(head -n 1 "$STATE/mqtt")" '"state":"started"'
assert_contains "plain: completed event" "$(mqtt_last)" '"state":"completed"'
assert_contains "plain: completed has s3_uri" "$(mqtt_last)" "\"s3_uri\":\"s3://test-bucket/linux-backup/${HOST}/${HOST}_"
assert_not_contains "plain: completed has no hooks_failed" "$(mqtt_last)" "hooks_failed"
assert_eq "plain: staging emptied" "" "$(ls "$WORK/staging")"

# --- tar exit codes ---

scenario
echo 1 >"$STATE/tar_exit"
run
assert_eq "tar exit 1 (file changed): exits 0" 0 "$rc"
assert_eq "tar exit 1: uploaded" 1 "$(uploads)"
assert_contains "tar exit 1: completed event" "$(mqtt_last)" '"state":"completed"'

scenario
echo 2 >"$STATE/tar_exit"
run
assert_eq "tar exit 2: exits 1" 1 "$rc"
assert_contains "tar exit 2: says so" "$output" "tar failed (exit 2)"
assert_eq "tar exit 2: nothing uploaded" 0 "$(uploads)"
assert_contains "tar exit 2: failed event" "$(mqtt_last)" '"state":"failed","host":"'
assert_contains "tar exit 2: failed at archive" "$(mqtt_last)" '"stage":"archive"'

# --- MariaDB ---

scenario
conf 'MARIADB_DATABASES="db1 db2"'
run
assert_eq "mariadb: exits 0" 0 "$rc"
assert_contains "mariadb: prefers mariadb-dump" "$(calls)" $'mariadb-dump db1\nmariadb-dump db2'
assert_contains "mariadb: dumps archived" "$(tar_args)" "$WORK/staging/mariadb-dumps"
assert_eq "mariadb: dumps removed after upload" "" "$(ls "$WORK/staging")"

# --- hooks ---

scenario
conf "PRE_BACKUP_HOOKS_DIR=\"$WORK/hooks\""
hook 10-first 'ls -A "$BACKUP_HOOK_OUTPUT_DIR" >"$STATE/hook_saw"
echo "hello from first"
echo "to stderr" >&2
echo "dump" >"$BACKUP_HOOK_OUTPUT_DIR/first.dump"
echo "$BACKUP_HOSTNAME $BACKUP_TIMESTAMP $(umask)" >"$STATE/hook_env"'
hook 20-second 'echo second >"$STATE/second_ran"'
echo 'echo should not run >"$STATE/plain_ran"' >"$WORK/hooks/30-not-executable"
mkdir "$WORK/hooks/40-a-directory"
run
assert_eq "hooks: exits 0" 0 "$rc"
assert_contains "hooks: run in name order" "$output" "Running hook: 10-first"
assert_contains "hooks: second ran" "$(cat "$STATE/second_ran" 2>/dev/null)" "second"
first_line=$(grep -n "Running hook: 10-first" <<<"$output" | cut -d: -f1)
second_line=$(grep -n "Running hook: 20-second" <<<"$output" | cut -d: -f1)
assert_eq "hooks: 10-first before 20-second" 1 "$(( first_line < second_line ))"
assert_contains "hooks: stdout logged with name" "$output" "[10-first] hello from first"
assert_contains "hooks: stderr logged too" "$output" "[10-first] to stderr"
assert_contains "hooks: non-executable skipped with warning" "$output" "hook not executable, skipping: $WORK/hooks/30-not-executable"
assert_eq "hooks: non-executable not run" "no" "$([[ -e "$STATE/plain_ran" ]] && echo yes || echo no)"
assert_not_contains "hooks: directory not run" "$output" "40-a-directory"
assert_contains "hooks: get BACKUP_HOSTNAME" "$(cat "$STATE/hook_env")" "$HOST "
assert_contains "hooks: run under umask 077" "$(cat "$STATE/hook_env")" "077"
assert_eq "hooks: output dir starts empty" "" "$(cat "$STATE/hook_saw")"
assert_contains "hooks: run under timeout with HOOK_TIMEOUT default" "$(calls)" "timeout 600"
assert_contains "hooks: output dir archived" "$(tar_args)" "$WORK/staging/hooks"
assert_contains "hooks: completed event" "$(mqtt_last)" '"state":"completed"'
assert_eq "hooks: output removed after upload" "" "$(ls "$WORK/staging")"

# A failing hook: later hooks still run, the archive is still uploaded, but the
# run ends "failed" at stage hook:<name> and exits 1.
scenario
conf "PRE_BACKUP_HOOKS_DIR=\"$WORK/hooks\""
hook 10-broken 'echo "cannot reach db" >&2; printf "last words, no newline" >&2; exit 3'
hook 20-fine 'echo ok >"$STATE/fine_ran"'
run
assert_eq "hook fails: exits 1" 1 "$rc"
assert_contains "hook fails: logged with exit code" "$output" "hook failed (exit 3): 10-broken"
assert_contains "hook fails: its stderr logged" "$output" "[10-broken] cannot reach db"
assert_contains "hook fails: unterminated last line logged" "$output" "[10-broken] last words, no newline"
assert_contains "hook fails: later hooks still run" "$(cat "$STATE/fine_ran" 2>/dev/null)" "ok"
assert_eq "hook fails: archive still uploaded" 1 "$(uploads)"
assert_contains "hook fails: failed event" "$(mqtt_last)" '"state":"failed"'
assert_contains "hook fails: stage names the hook" "$(mqtt_last)" '"stage":"hook:10-broken"'
assert_contains "hook fails: lists failed hooks" "$(mqtt_last)" '"hooks_failed":["10-broken"]'
assert_contains "hook fails: still gives s3_uri" "$(mqtt_last)" '"s3_uri":"s3://test-bucket/'
assert_eq "hook fails: no completed event" 0 "$(grep -c '"state":"completed"' "$STATE/mqtt" || true)"

scenario
conf "PRE_BACKUP_HOOKS_DIR=\"$WORK/hooks\""
conf "HOOK_TIMEOUT=5"
hook 10-slow 'sleep 1'
echo 124 >"$STATE/timeout_exit"
run
assert_eq "hook times out: exits 1" 1 "$rc"
assert_contains "hook times out: uses HOOK_TIMEOUT" "$(calls)" "timeout 5"
assert_contains "hook times out: says so" "$output" "hook timed out after 5s: 10-slow"
assert_contains "hook times out: stage names the hook" "$(mqtt_last)" '"stage":"hook:10-slow"'

scenario
conf "PRE_BACKUP_HOOKS_DIR=\"$WORK/no-such-dir\""
run
assert_eq "hooks dir missing: exits 1" 1 "$rc"
assert_contains "hooks dir missing: says so" "$output" "PRE_BACKUP_HOOKS_DIR not found"
assert_eq "hooks dir missing: rest still uploaded" 1 "$(uploads)"
assert_contains "hooks dir missing: failed event" "$(mqtt_last)" '"stage":"hook:PRE_BACKUP_HOOKS_DIR"'

# Leftovers from a run that died must not be archived.
scenario
mkdir -p "$WORK/staging/hooks/old" "$WORK/staging/mariadb-dumps"
echo stale >"$WORK/staging/hooks/old/stale.dump"
echo stale >"$WORK/staging/mariadb-dumps/old.sql.gz"
run
assert_eq "leftovers: exits 0" 0 "$rc"
assert_not_contains "leftovers: old hook output not archived" "$(tar_args)" "$WORK/staging/hooks"
assert_not_contains "leftovers: old dumps not archived" "$(tar_args)" "$WORK/staging/mariadb-dumps"

# --- retention ---

scenario
conf "RETENTION_COUNT=2"
for d in 2020-01-01 2020-01-02 2020-01-03; do
    echo old >"$STATE/s3/${HOST}_${d}_000000.tar.gz"
done
run
assert_eq "retention: exits 0" 0 "$rc"
assert_eq "retention: keeps RETENTION_COUNT" 2 "$(uploads)"
assert_contains "retention: deletes the oldest" "$(calls)" "aws s3 rm s3://test-bucket/linux-backup/${HOST}/${HOST}_2020-01-01_000000.tar.gz"
assert_contains "retention: deletes the next oldest" "$(calls)" "${HOST}_2020-01-02_000000.tar.gz"
assert_contains "retention: keeps the newest old one" "$(ls "$STATE/s3")" "${HOST}_2020-01-03_000000.tar.gz"
assert_contains "retention: reports retained count" "$(mqtt_last)" '"backups_retained":2'

# --- encryption ---

scenario
conf 'GPG_RECIPIENT="backup@example.com"'
conf 'MARIADB_DATABASES="db1"'
touch "$STATE/gpg_nokey"
run
assert_eq "gpg key missing: exits 1" 1 "$rc"
assert_contains "gpg key missing: says so" "$output" "GPG key not found in keyring: backup@example.com"
assert_not_contains "gpg key missing: fails before dumping" "$(calls)" "mariadb-dump"
assert_eq "gpg key missing: nothing uploaded" 0 "$(uploads)"

scenario
conf 'GPG_RECIPIENT="backup@example.com"'
run
assert_eq "gpg: exits 0" 0 "$rc"
assert_contains "gpg: encrypts for the recipient" "$(calls)" "--recipient backup@example.com"
assert_contains "gpg: uploads the .gpg" "$(calls)" ".tar.gz.gpg"

# --- with real GNU tar: what actually lands in the archive ---

if gt=$(gnu_tar) && [[ -n "$gt" ]]; then
    scenario
    conf "PRE_BACKUP_HOOKS_DIR=\"$WORK/hooks\""
    hook 10-dump 'echo "dump" >"$BACKUP_HOOK_OUTPUT_DIR/db.dump"'
    echo "noise" >"$WORK/etc/svc/svc.log"
    shim=$(mktemp -d)
    ln -s "$gt" "$shim/tar"
    rc=0
    output=$(PATH="$STUBS:$shim:$PATH" bash "$script" "$WORK/backup.conf" </dev/null 2>&1) || rc=$?
    listing=$("$gt" -tzf "$STATE"/s3/*.tar.gz)
    assert_eq "real tar: exits 0" 0 "$rc"
    assert_contains "real tar: holds the backed-up file" "$listing" "${WORK#/}/etc/svc/svc.conf"
    assert_contains "real tar: holds hook output at STAGING_DIR/hooks/<name>/" "$listing" "${WORK#/}/staging/hooks/10-dump/db.dump"
    assert_not_contains "real tar: excludes *.log" "$listing" "svc.log"
    rm -rf "$shim"
else
    echo "  skip  real tar tests (no GNU tar; brew install gnu-tar to run them)"
fi

finish
