#!/usr/bin/env bash
# Check portable installation and explicit recovery with synthetic homes and repositories.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/portable-smoke.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
# shellcheck source=test/lib.sh
source "$REPO/test/lib.sh"
trap lib_cleanup EXIT
export TEST_ROOT
python3 -B "$REPO/test/portable_test.py"
