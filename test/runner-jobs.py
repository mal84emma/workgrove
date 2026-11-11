"""Choose a bounded worker count from the available CPU allocation."""

import importlib.util
import os
from pathlib import Path
import subprocess
import sys


def default_jobs():
    if sys.platform == "darwin":
        try:
            cpus = int(subprocess.check_output(
                ["sysctl", "-n", "hw.physicalcpu"], text=True, stderr=subprocess.DEVNULL))
        except (OSError, ValueError, subprocess.CalledProcessError):
            cpus = 1
    elif sys.platform.startswith("linux"):
        spec = importlib.util.spec_from_file_location(
            "capacity", Path(__file__).resolve().parents[1] / "lib/workgrove/vm/capacity.py")
        capacity = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(capacity)
        report = capacity.effective()
        cpus = report.get("observed_cpu_logical")
        if cpus is None:
            try:
                cpus = min(4, len(os.sched_getaffinity(0)))
            except (AttributeError, OSError):
                cpus = 1
    else:
        cpus = 1
    return max(1, min(4, cpus))


if __name__ == "__main__":
    print(default_jobs())
