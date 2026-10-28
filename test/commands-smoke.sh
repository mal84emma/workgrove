#!/usr/bin/env bash
# Check pinned command cancellation with fake graphs and disposable owned processes.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
python3 -B "$root/test/commands_test.py"
