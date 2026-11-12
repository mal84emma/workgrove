#!/usr/bin/env bash
# Run receipt policy and atomic-write characterization tests.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
python3 -B "$REPO/test/receipts_test.py"
