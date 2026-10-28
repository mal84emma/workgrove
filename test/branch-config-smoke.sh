#!/usr/bin/env bash
# Run disposable branch-configuration interruption tests.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
python3 -B "$REPO/test/branch_config_test.py"
