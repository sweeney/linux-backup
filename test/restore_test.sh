#!/usr/bin/env bash
# restore_test.sh: tests for restore.sh.
#
# Whole runs of restore.sh against stubs (see make_stubs in lib.sh). The
# "bucket" holds a real .tar.gz built here, laid out as backup.sh lays it out:
# backed-up paths plus STAGING_DIR/hooks/<name>/. Restores go to --dest, never /.

set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"
script=$root/restore.sh

echo "restore.sh"

assert_exit "parses (bash -n)" 0 bash -n "$script"

STATE=$(mktemp -d)
STUBS=$(mktemp -d)
WORK=$(mktemp -d)
export STATE
trap 'rm -rf "$STATE" "$STUBS" "$WORK"' EXIT
make_stubs "$STUBS"
HOST=$(hostname -s)
ARCHIVE="${HOST}_2026-10-27_000000.tar.gz"

# scenario: fresh state, a config at $WORK/conf/host.conf (deliberately not
# next to restore.sh), and one backup in the bucket.
scenario() {
    rm -rf "${STATE:?}"/* "${WORK:?}"/*
    mkdir -p "$STATE/s3" "$WORK/conf" "$WORK/dest" "$WORK/src"
    cat >"$WORK/conf/host.conf" <<EOF
S3_BUCKET="restore-test-bucket"
S3_PREFIX="linux-backup"
AWS_REGION=""
STAGING_DIR="$WORK/staging"
EOF
    # What backup.sh would have archived (tar strips the leading /)
    local s="$WORK/src/${WORK#/}"
    mkdir -p "$s/etc/svc" "$s/staging/hooks/10-dump"
    echo "setting=1" >"$s/etc/svc/svc.conf"
    echo "dump" >"$s/staging/hooks/10-dump/db.dump"
    tar czf "$STATE/s3/$ARCHIVE" -C "$WORK/src" "${WORK#/}"
}

# run ARGS...: restore.sh as a separate process on the stubs, stdin from
# $INPUT (default: nothing, so a prompt reads EOF). Sets $rc and $output.
run() {
    rc=0
    output=$(PATH="$STUBS:$PATH" bash "$script" "$@" <<<"${INPUT:-}" 2>&1) || rc=$?
}
calls() { cat "$STATE/calls" 2>/dev/null || true; }
restored="$WORK/dest/${WORK#/}"

# --- config ---

scenario
run --config "$WORK/conf/host.conf"
assert_eq "--config: list exits 0" 0 "$rc"
assert_contains "--config: uses that config's bucket" "$(calls)" "bucket=restore-test-bucket prefix=linux-backup/${HOST}/"

scenario
CONFIG="$WORK/conf/host.conf" run
assert_eq "CONFIG env: list exits 0" 0 "$rc"
assert_contains "CONFIG env: uses that config's bucket" "$(calls)" "bucket=restore-test-bucket"

scenario
run --config "$WORK/conf/nope.conf"
assert_eq "--config missing: exits 1" 1 "$rc"
assert_contains "--config missing: names the file" "$output" "config file not found: $WORK/conf/nope.conf"

scenario
run --bogus
assert_eq "unknown option: exits 1" 1 "$rc"

scenario
run --config "$WORK/conf/host.conf" --host oldbox
assert_contains "--host: lists that host's backups" "$(calls)" "prefix=linux-backup/oldbox/"

# --- restoring ---

scenario
INPUT=n run latest --config "$WORK/conf/host.conf" --dest "$WORK/dest"
assert_eq "answer no: exits 0" 0 "$rc"
assert_contains "answer no: aborted" "$output" "Aborted."
assert_not_contains "answer no: nothing downloaded" "$(calls)" "aws s3 cp"

scenario
run latest --config "$WORK/conf/host.conf" --dest "$WORK/dest"
assert_eq "no answer (EOF): exits 0" 0 "$rc"
assert_contains "no answer (EOF): aborted" "$output" "Aborted."

scenario
echo 1000 >"$STATE/uid"
run latest --config "$WORK/conf/host.conf" --dest "$WORK/dest" --yes
assert_eq "not root: exits 1" 1 "$rc"
assert_contains "not root: says so" "$output" "must run as root"

scenario
run latest --config "$WORK/conf/host.conf" --dest "$WORK/dest" --yes
assert_eq "--yes latest: exits 0" 0 "$rc"
assert_contains "--yes latest: downloads the newest" "$(calls)" "aws s3 cp s3://restore-test-bucket/linux-backup/${HOST}/${ARCHIVE}"
assert_eq "--yes latest: restores files" "setting=1" "$(cat "$restored/etc/svc/svc.conf" 2>/dev/null)"
assert_eq "--yes latest: restores hook output" "dump" "$(cat "$restored/staging/hooks/10-dump/db.dump" 2>/dev/null)"
assert_contains "--yes latest: says where hook output is" "$output" "Pre-backup hook output restored to $restored/staging/hooks"
assert_not_contains "--yes latest: no service hints off /" "$output" "systemctl daemon-reload"
assert_eq "--yes latest: staging cleaned" "" "$(ls "$WORK/staging" 2>/dev/null)"

scenario
run "$ARCHIVE" --config "$WORK/conf/host.conf" --dest "$WORK/dest" -y
assert_eq "by name: exits 0" 0 "$rc"
assert_eq "by name: restores files" "setting=1" "$(cat "$restored/etc/svc/svc.conf" 2>/dev/null)"

finish
