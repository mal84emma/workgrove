#!/usr/bin/env bash
# Check kernel allocation limits and GPU visibility without hardware or network dependencies.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/capacity-smoke.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
# shellcheck source=test/lib.sh
source "$REPO/test/lib.sh"
trap lib_cleanup EXIT
export TEST_ROOT
python3 -B "$REPO/test/capacity_test.py"
