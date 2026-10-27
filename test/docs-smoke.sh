#!/usr/bin/env bash
# Check the README tree, compatibility markers, citations, and local documentation links.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
# shellcheck source=test/lib.sh
source "$REPO/test/lib.sh"

check_docs() {
  local mode=$1 output status=0
  output=$(python3 -B "$REPO/test/docs_check.py" "$REPO" "$mode" 2>&1) || status=$?
  if ((status == 0)); then pass; else fail "$mode checks (exit $status): $output"; fi
}

scenario_layout() {
  begin_scenario 'README Layout matches tracked files' || return 0
  check_docs layout
  end_scenario
}
scenario_citations() {
  begin_scenario 'documentation guide citation checks' || return 0
  check_docs citations
  end_scenario
}
scenario_links() {
  begin_scenario 'relative documentation links and anchors resolve' || return 0
  check_docs links
  end_scenario
}
scenario_compatibility() {
  begin_scenario 'compatibility inventory matches tracked markers' || return 0
  check_docs compatibility
  end_scenario
}
scenario_regressions() {
  begin_scenario 'documentation checker regression fixtures' || return 0
  local output status=0
  output=$(python3 -B "$REPO/test/docs_check_test.py" 2>&1) || status=$?
  if ((status == 0)); then pass; else fail "checker regressions (exit $status): $output"; fi
  end_scenario
}
scenario_regressions
scenario_compatibility
scenario_layout
scenario_citations
scenario_links
lib_summary
