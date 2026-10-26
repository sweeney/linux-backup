# lib.sh: assertions shared by the test files. Sourced, not run.
# shellcheck shell=bash

# shellcheck disable=SC2034 # root is for the test files that source this
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname "$here")

pass=0
fail=0

ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [[ -z ${2:-} ]] || printf '%s\n' "$2" | sed 's/^/        /'; }

assert_eq() { # name want got
    if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "want: $2"$'\n'"got:  $3"; fi
}
assert_contains() { # name haystack needle
    if [[ $2 == *"$3"* ]]; then ok "$1"; else bad "$1" "missing: $3"$'\n'"in: $2"; fi
}
assert_not_contains() { # name haystack needle
    if [[ $2 != *"$3"* ]]; then ok "$1"; else bad "$1" "unexpected: $3"$'\n'"in: $2"; fi
}
assert_exit() { # name want-code cmd...
    local name=$1 want=$2 got=0
    shift 2
    "$@" >/dev/null 2>&1 || got=$?
    assert_eq "$name" "$want" "$got"
}

# finish: print the tally and exit non-zero on any failure.
finish() {
    echo "$pass passed, $fail failed"
    ((fail == 0))
}

# ── Stubs ─────────────────────────────────────────────────────────────────────
#
# make_stubs DIR: write stand-ins for the commands backup.sh and restore.sh
# call. They keep their state under $STATE (exported by the caller):
#   $STATE/s3/        the bucket: objects by file name
#   $STATE/calls      one line per stubbed call worth asserting on
#   $STATE/mqtt       one MQTT payload per line
#   $STATE/uid        what `id -u` prints (default 0, i.e. root)
#   $STATE/tar_exit   exit code for the stub tar (default 0)
#   $STATE/timeout_exit  if present, the stub timeout exits with it instead of
#                     running the command (124 = timed out)
#   $STATE/gpg_nokey  if present, `gpg --list-keys` fails
make_stubs() {
    local d=$1
    mkdir -p "$d"

    cat >"$d/id" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "-u" ]] && { cat "$STATE/uid" 2>/dev/null || echo 0; exit 0; }
exec /usr/bin/id "$@"
EOF

    cat >"$d/aws" <<'EOF'
#!/usr/bin/env bash
# aws s3 cp SRC DST | aws s3 rm URI | aws s3api list-objects-v2 --bucket B --prefix P --query Q
mkdir -p "$STATE/s3"
case "$1 $2" in
"s3 cp")
    if [[ "$3" == s3://* ]]; then
        echo "aws s3 cp $3" >>"$STATE/calls"
        cp "$STATE/s3/$(basename "$3")" "$4"
    else
        echo "aws s3 cp -> $4" >>"$STATE/calls"
        cp "$3" "$STATE/s3/$(basename "$4")"
    fi ;;
"s3 rm")
    echo "aws s3 rm $3" >>"$STATE/calls"
    rm -f "$STATE/s3/$(basename "$3")" ;;
"s3api list-objects-v2")
    shift 2
    bucket="" prefix="" query=""
    while (( $# )); do
        case "$1" in
        --bucket) bucket=$2; shift 2 ;;
        --prefix) prefix=$2; shift 2 ;;
        --query) query=$2; shift 2 ;;
        *) shift ;;
        esac
    done
    echo "aws list bucket=$bucket prefix=$prefix" >>"$STATE/calls"
    # names carry a sortable UTC timestamp, so name order is age order
    mapfile -t keys < <(ls "$STATE/s3" | sort | sed "s|^|$prefix|")
    if [[ "$query" == *"[-1]"* ]]; then
        (( ${#keys[@]} )) && echo "${keys[-1]}" || echo None
    else
        (IFS=$'\t'; echo "${keys[*]}")
    fi ;;
*) echo "aws stub: unexpected: $*" >&2; exit 1 ;;
esac
EOF

    cat >"$d/mosquitto_pub" <<'EOF'
#!/usr/bin/env bash
while (( $# )); do [[ "$1" == "-m" ]] && echo "$2" >>"$STATE/mqtt"; shift; done
EOF

    cat >"$d/mariadb-dump" <<'EOF'
#!/usr/bin/env bash
echo "mariadb-dump ${*: -1}" >>"$STATE/calls"
echo "-- dump of ${*: -1}"
EOF

    cat >"$d/timeout" <<'EOF'
#!/usr/bin/env bash
echo "timeout $1" >>"$STATE/calls"
[[ -f "$STATE/timeout_exit" ]] && exit "$(cat "$STATE/timeout_exit")"
shift
exec "$@"
EOF

    cat >"$d/gpg" <<'EOF'
#!/usr/bin/env bash
echo "gpg $*" >>"$STATE/calls"
[[ " $* " == *" --list-keys "* && -f "$STATE/gpg_nokey" ]] && exit 2
# --output FILE: write something there, as encrypt/decrypt would
while (( $# )); do [[ "$1" == "--output" ]] && echo "gpg output" >"$2"; shift; done
exit 0
EOF

    chmod +x "$d"/*
}

# make_tar_stub DIR: a tar that records its arguments in $STATE/tar_args (one
# per line), creates the archive file, and exits with $STATE/tar_exit.
make_tar_stub() {
    mkdir -p "$1"
    cat >"$1/tar" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STATE/tar_args"
[[ "$1" == czf ]] && echo "stub archive" >"$2"
exit "$(cat "$STATE/tar_exit" 2>/dev/null || echo 0)"
EOF
    chmod +x "$1/tar"
}

# gnu_tar: print the path of a GNU tar, or nothing.
gnu_tar() {
    local t
    for t in gtar tar; do
        if command -v "$t" >/dev/null && "$t" --version 2>/dev/null | grep -q 'GNU tar'; then
            command -v "$t"
            return
        fi
    done
}
