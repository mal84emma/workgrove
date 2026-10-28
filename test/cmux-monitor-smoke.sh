#!/usr/bin/env bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
python3 -B "$REPO/test/cmux_monitor_test.py"
