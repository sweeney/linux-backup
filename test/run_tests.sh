#!/usr/bin/env bash
# run_tests.sh: run every test/*_test.sh. They drive backup.sh and restore.sh
# against stub commands (aws, tar, mosquitto_pub, ...), need only bash, and so
# run on a laptop and in CI. The one test that needs GNU tar is skipped
# without it.
#
# Usage: test/run_tests.sh

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
failed=()
for t in "$here"/*_test.sh; do
    echo "== $(basename "$t")"
    bash "$t" || failed+=("$(basename "$t")")
    echo
done
if ((${#failed[@]})); then
    echo "FAILED: ${failed[*]}"
    exit 1
fi
echo "all test files passed"
