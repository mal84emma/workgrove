"""Pass fallback records through the inventory reader without remote hosts."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, REPO / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


capacity = load("capacity", "lib/workgrove/vm/capacity.py")
portable = load("portable", "lib/workgrove/portable.py")


class HostRecordsTests(unittest.TestCase):
    def shell(self, script, *args, interpreter="bash"):
        return subprocess.run([interpreter, "-c", script, "fixture", str(REPO), *args],
                              capture_output=True, text=True, check=True).stdout

    def record(self, report, host="test-host", status="0", validate=None):
        # Replacement can equal the supplied fallback, so record each validator's status.
        with tempfile.TemporaryDirectory(dir=os.environ.get("TEST_ROOT")) as scratch:
            validation_log = Path(scratch) / "validation"
            output = self.shell('''
                source "$1/lib/workgrove/common.sh"
                source "$1/lib/workgrove/hosts.sh"
                fixture_report=$2 fixture_status=$4 fixture_validation_log=$5
                ssh_host_check() { return 0; }
                probe_host() { printf '%s\\n' "$fixture_report"; return "$fixture_status"; }
                jq() {
                    local rc=0
                    command jq "$@" || rc=$?
                    case ${2:-} in
                        *'error("invalid capacity")'*) printf 'capacity:%s\\n' "$rc" >>"$fixture_validation_log" ;;
                        *'error("invalid readiness")'*) printf 'readiness:%s\\n' "$rc" >>"$fixture_validation_log" ;;
                    esac
                    return "$rc"
                }
                host_record "$3"
            ''', report, host, status, str(validation_log))
            if validate is not None:
                statuses = [line for line in validation_log.read_text().splitlines()
                            if line.startswith(validate + ":")]
                self.assertEqual(statuses, [validate + ":0"])
            return json.loads(output)

    def accepted(self, report, issue, kind):
        record = self.record(report, validate=kind)
        self.assertEqual(record["status"], "available")
        self.assertEqual(record[kind + "_issues"], [issue])
        self.assertIs(record["capacity_verified" if kind == "capacity" else "workgrove_ready"], False)

    def test_shell_fallbacks_and_python_runtime_error(self):
        for issue in ("missing-python", "python-3.9-required", "invalid-capacity-report"):
            report = self.shell('''
                . "$1/lib/workgrove/vm/python-runtime.sh"
                printf 'capabilities\\t'; wg_capabilities_error "$2"
            ''', issue, interpreter="/bin/sh")
            self.accepted(report, issue, "capacity")
        for issue in ("missing-python", "python-3.9-required", "invalid-readiness-report"):
            report = self.shell('''
                . "$1/lib/workgrove/vm/python-runtime.sh"
                printf 'readiness\\t'; wg_readiness_error "$2"
            ''', issue, interpreter="/bin/sh")
            self.accepted(report, issue, "readiness")
        report = self.shell('''
            . "$1/lib/workgrove/vm/python-runtime.sh"
            wg_python_issue=missing-python
            printf 'readiness\\t'; wg_python_readiness_error
        ''', interpreter="/bin/sh")
        self.accepted(report, "missing-python", "readiness")

    def test_sent_probe_fallbacks_need_no_installed_wt(self):
        source = self.shell('''
            WG_LIB_DIR="$1/lib/workgrove"
            source "$WG_LIB_DIR/hosts.sh"
            host_probe_source
        ''')
        with tempfile.TemporaryDirectory(dir=os.environ.get("TEST_ROOT")) as home:
            for issue in ("missing-python", "python-3.9-required"):
                script = source.replace("if wg_select_python; then",
                                        "if wg_python_issue=" + issue + "; false; then")
                result = subprocess.run(["/bin/sh", "-s"], input=script,
                                        env=dict(os.environ, HOME=home), capture_output=True,
                                        text=True, check=True)
                self.accepted(result.stdout, issue, "capacity")
                self.accepted(result.stdout, issue, "readiness")
                reports = dict(line.split("\t", 1) for line in result.stdout.splitlines() if "\t" in line)
                self.assertNotIn("root_discovery", json.loads(reports["readiness"]))

    def test_malformed_reports_use_shared_fallbacks(self):
        record = self.record("capabilities\tinvalid-json\nreadiness\tinvalid-json")
        self.assertEqual(record["capacity_issues"], ["invalid-capacity-report"])
        self.assertEqual(record["readiness_issues"], ["invalid-readiness-report"])

    def test_python_capacity_fallbacks(self):
        output = io.StringIO()
        with patch.object(capacity, "effective", side_effect=OSError), contextlib.redirect_stdout(output):
            capacity.report()
        self.accepted(output.getvalue(), "capacity-probe-failed", "capacity")
        with tempfile.TemporaryDirectory(dir=os.environ.get("TEST_ROOT")) as root:
            report = capacity.effective(capacity.KernelView(Path(root)))
        self.accepted("capabilities\t" + json.dumps(report), "kernel-view-missing", "capacity")

    def test_python_readiness_fallback_keys_and_validation(self):
        with patch.object(portable, "_readiness", side_effect=OSError):
            fallback = portable.readiness()
        self.accepted("readiness\t" + json.dumps(fallback), "readiness-probe-failed", "readiness")
        with tempfile.TemporaryDirectory(dir=os.environ.get("TEST_ROOT")) as home, \
                patch.object(Path, "home", return_value=Path(home)), \
                patch.dict(os.environ, {"WT_REMOTE_ROOT": ""}), \
                patch.object(portable.shutil, "which", return_value=None):
            normal = portable._readiness()
        self.assertEqual(set(fallback), set(normal))
        self.assertNotIn("root_discovery", fallback)
        shell_fallback = json.loads(self.shell("""
            . "$1/lib/workgrove/vm/python-runtime.sh"
            wg_readiness_error missing-python
        """, interpreter="/bin/sh"))
        self.assertEqual(set(shell_fallback), set(normal))

    def test_unavailable_record_is_defined_once(self):
        source = (REPO / "lib/workgrove/hosts.sh").read_text()
        self.assertEqual(source.count("gpu_allocation_verified:null"), 1)
        invalid = self.record("", "invalid alias")
        failed = self.record("", status="42")
        self.assertEqual(invalid["error"], "invalid SSH alias")
        self.assertEqual(failed["error"], "SSH probe failed (exit 42)")
        self.assertEqual(dict(invalid, host="test-host", error=None), dict(failed, error=None))


if __name__ == "__main__":
    unittest.main()
