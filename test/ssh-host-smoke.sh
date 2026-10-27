#!/usr/bin/env bash
# Check SSH fragment registration with synthetic files and an offline SSH wrapper.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
if [[ ${1:-} == --list-scenarios ]]; then
  python3 -B "$REPO/test/python-scenarios.py" "$REPO/test/ssh_host_test.py" "$@"
  exit $?
fi
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ssh-host-smoke.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
# shellcheck source=test/lib.sh
source "$REPO/test/lib.sh"
trap lib_cleanup EXIT
export TEST_ROOT BASH
python3 -B "$REPO/test/python-scenarios.py" "$REPO/test/ssh_host_test.py" "$@"
