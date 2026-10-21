"""Measure Linux allocation from visible kernel limits without a provider API."""

import csv
from fractions import Fraction
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess


class Unknown(Exception):
    pass


class KernelView:
    def __init__(self, root=Path("/")):
        self.root = root

    def path(self, name):
        return self.root / str(name).lstrip("/")

    def read(self, name, optional=False):
        try:
            with self.path(name).open() as stream:
                data = stream.read(1024 * 1024 + 1)
        except FileNotFoundError:
            if optional:
                return None
            raise Unknown("kernel-view-missing") from None
        except (OSError, UnicodeError):
            raise Unknown("kernel-view-unreadable") from None
        if len(data) > 1024 * 1024:
            raise Unknown("kernel-view-invalid")
        return data.strip()


def unsigned(value, zero=True):
    if not re.fullmatch(r"[0-9]{1,24}", value) or (not zero and int(value) == 0):
        raise Unknown("invalid-limit")
    return int(value)


def cpus(value):
    result = set()
    for part in value.split(","):
        if "-" in part:
            start, end = part.split("-", 1)
            start, end = unsigned(start), unsigned(end)
        else:
            start = end = unsigned(part)
        if end < start or end > 1048576 or end - start > 131072:
            raise Unknown("invalid-cpuset")
        result.update(range(start, end + 1))
        if len(result) > 131072:
            raise Unknown("invalid-cpuset")
    return result


def kernel_path(value):
    path = PurePosixPath(value)
    if not path.is_absolute() or ".." in path.parts or " (deleted)" in value:
        raise Unknown("invalid-cgroup-path")
    return path


def unescape(value):
    return re.sub(r"\\([0-7]{3})", lambda match: chr(int(match[1], 8)), value)


def hierarchy(view):
    members = {}
    membership = view.read("/proc/self/cgroup")
    for line in membership.splitlines():
        parts = line.split(":", 2)
        if len(parts) != 3:
            raise Unknown("invalid-cgroup-membership")
        controllers = parts[1].split(",") if parts[1] else ["v2"]
        for controller in controllers:
            if controller in members:
                raise Unknown("duplicate-cgroup-membership")
            members[controller] = kernel_path(parts[2])
    mounts = []
    mountinfo = view.read("/proc/self/mountinfo")
    for line in mountinfo.splitlines():
        parts = line.split(" - ")
        if len(parts) != 2:
            raise Unknown("invalid-mountinfo")
        left, right = parts[0].split(), parts[1].split()
        if len(left) < 6 or len(right) < 3:
            raise Unknown("invalid-mountinfo")
        if right[0] in {"cgroup", "cgroup2"}:
            controllers = {"v2"} if right[0] == "cgroup2" else set(right[2].split(","))
            mounts.append((kernel_path(unescape(left[3])), kernel_path(unescape(left[4])), controllers))
    container = view.path("/.dockerenv").exists() or view.path("/run/.containerenv").exists()
    container = container or any(line.split(" - ")[1].split()[0] == "overlay" and
                                 line.split(" - ")[0].split()[4] == "/" for line in mountinfo.splitlines())
    return members, mounts, container


def nodes_for(controller, members, mounts):
    member = members.get(controller)
    if member is None:
        return None
    candidates = [(base, point) for base, point, controllers in mounts if controller in controllers and
                  (member == base or base in member.parents)]
    if not candidates:
        raise Unknown("cgroup-mount-hidden")
    base, point = max(candidates, key=lambda item: len(item[0].parts))
    current = point / member.relative_to(base)
    nodes = []
    while True:
        nodes.append(current)
        if current == point:
            break
        current = current.parent
        if len(nodes) > 256:
            raise Unknown("cgroup-depth-exceeded")
    return base, point, nodes


def effective(view=None, affinity=None):
    view = view or KernelView()
    issues = []
    cpu = memory = None
    observed_cpu = observed_memory = None
    try:
        members, mounts, container = hierarchy(view)
    except Unknown as error:
        return {"schema": 1, "capacity_verified": False, "cpu_logical": None, "memory_mib": None,
                "environment": "unknown", "capacity_issues": [str(error)]}
    try:
        online = cpus(view.read("/sys/devices/system/cpu/online"))
        if affinity is None:
            try:
                affinity = os.sched_getaffinity(0)
            except (AttributeError, OSError):
                raise Unknown("process-affinity-unknown") from None
        usable = online & set(affinity)
        quota = Fraction(len(usable))
        namespace_hidden = False
        for version, controller in ((2, "v2"), (1, "cpu"), (1, "cpuset")):
            mapped = nodes_for(controller, members, mounts)
            if mapped is None:
                continue
            base, point, nodes = mapped
            if base != PurePosixPath("/"):
                namespace_hidden = True
            if container or version == 2:
                # A non-root v2 cgroup exposes cpu.max when its CPU controller is available.
                available = view.read(point / "cgroup.controllers", optional=True) or ""
                initial_root = version == 2 and "cpu" in available.split() and view.read(point / "cpu.max", optional=True) is None
                if not initial_root:
                    namespace_hidden = True
            for node in nodes:
                if not view.path(node).is_dir():
                    raise Unknown("cgroup-node-hidden")
                if controller in {"v2", "cpu"}:
                    if version == 2:
                        value = view.read(node / "cpu.max", optional=True)
                        if value is None and node != point and "cpu" in (view.read(node / "cgroup.controllers", optional=True) or "").split():
                            raise Unknown("cpu-limit-interface-missing")
                        if value is not None:
                            parts = value.split()
                            if len(parts) != 2:
                                raise Unknown("invalid-cpu-quota")
                            period = unsigned(parts[1], zero=False)
                            if parts[0] != "max":
                                quota = min(quota, Fraction(unsigned(parts[0], zero=False), period))
                    else:
                        value = view.read(node / "cpu.cfs_quota_us")
                        period = unsigned(view.read(node / "cpu.cfs_period_us"), zero=False)
                        if value != "-1":
                            quota = min(quota, Fraction(unsigned(value, zero=False), period))
                if controller in {"v2", "cpuset"}:
                    name = "cpuset.cpus.effective" if version == 2 else "cpuset.effective_cpus"
                    value = view.read(node / name, optional=True)
                    if value is None and version == 1:
                        value = view.read(node / "cpuset.cpus", optional=True)
                    if value:
                        usable &= cpus(value)
        observed_cpu = min(len(usable), quota.numerator // quota.denominator)
        if container and not members:
            namespace_hidden = True
        if namespace_hidden:
            raise Unknown("cpu-ancestors-hidden")
        cpu = observed_cpu
    except Unknown as error:
        issues.append(str(error))
    try:
        match = re.search(r"^MemTotal:\s+([0-9]+)\s+kB$", view.read("/proc/meminfo"), re.M)
        if not match:
            raise Unknown("physical-memory-unknown")
        limit = unsigned(match[1], zero=False) * 1024
        namespace_hidden = False
        for version, controller in ((2, "v2"), (1, "memory")):
            mapped = nodes_for(controller, members, mounts)
            if mapped is None:
                continue
            base, point, nodes = mapped
            if base != PurePosixPath("/"):
                namespace_hidden = True
            if container or version == 2:
                available = view.read(point / "cgroup.controllers", optional=True) or ""
                initial_root = version == 2 and "memory" in available.split() and view.read(point / "memory.max", optional=True) is None
                if not initial_root:
                    namespace_hidden = True
            for node in nodes:
                if not view.path(node).is_dir():
                    raise Unknown("cgroup-node-hidden")
                value = view.read(node / ("memory.max" if version == 2 else "memory.limit_in_bytes"), optional=version == 2)
                if value is None and node != point and "memory" in (view.read(node / "cgroup.controllers", optional=True) or "").split():
                    raise Unknown("memory-limit-interface-missing")
                if value is not None and value != "max":
                    number = unsigned(value)
                    if version == 2 or number < (1 << 60):
                        limit = min(limit, number)
        observed_memory = limit // (1024 * 1024)
        if container and not members:
            namespace_hidden = True
        if namespace_hidden:
            raise Unknown("memory-ancestors-hidden")
        memory = observed_memory
    except Unknown as error:
        issues.append(str(error))
    try:
        if hierarchy(view) != (members, mounts, container):
            raise Unknown("cgroup-hierarchy-changed")
    except Unknown as error:
        cpu = memory = None
        issues.append(str(error))
    return {"schema": 1, "capacity_verified": cpu is not None and memory is not None,
            "cpu_logical": cpu, "memory_mib": memory,
            "environment": "container" if container else "unknown" if any("ancestors-hidden" in item for item in issues) else "host",
            "capacity_issues": sorted(set(issues)), "observed_cpu_logical": observed_cpu,
            "observed_memory_mib": observed_memory}


def gpu_allocation(environment=None, query=None, detail=None):
    environment = os.environ if environment is None else environment
    if query is None:
        if not shutil.which("nvidia-smi"):
            return {"gpu_allocation_verified": None, "gpu_indices": None}
        try:
            result = subprocess.run(["nvidia-smi", "--query-gpu=index,uuid,mig.mode.current",
                                     "--format=csv,noheader,nounits"], stdin=subprocess.DEVNULL,
                                    capture_output=True, text=True, timeout=5, check=False)
            if result.returncode:
                raise ValueError
            query = result.stdout
            status = subprocess.run(["nvidia-smi", "-q"], stdin=subprocess.DEVNULL,
                                    capture_output=True, text=True, timeout=5, check=False)
            if status.returncode:
                raise ValueError
            detail = status.stdout
        except (OSError, subprocess.TimeoutExpired, ValueError):
            return {"gpu_allocation_verified": False, "gpu_indices": None}
    try:
        rows = list(csv.reader(io.StringIO(query)))
        devices = {}
        for row in rows:
            if len(row) != 3:
                raise ValueError
            index, identity, mode = [item.strip() for item in row]
            if not index.isdecimal() or not identity.startswith("GPU-") or mode not in {"Disabled", "[N/A]", "N/A"}:
                raise ValueError
            if index in devices:
                raise ValueError
            devices[index] = identity
        if detail is None:
            raise ValueError
        virtualization = re.findall(r"^\s*Virtualization Mode\s*:\s*([^\n]+)", detail, re.M)
        if len(virtualization) != len(devices) or any(re.sub(r"[ -]", "", mode).lower() not in {"none", "passthrough"}
                                                     for mode in virtualization):
            raise ValueError
        if "nvidia-cuda-mps" in detail or "[Not Found]" in detail:
            raise ValueError
        selected = set(devices)
        for variable in ("NVIDIA_VISIBLE_DEVICES", "CUDA_VISIBLE_DEVICES"):
            if variable not in environment:
                continue
            value = environment[variable]
            if variable == "NVIDIA_VISIBLE_DEVICES" and value == "all":
                continue
            if value in {"", "none", "void", "-1"}:
                selected.clear()
                continue
            wanted = value.split(",")
            # CUDA ordinals can be renumbered or reordered. UUIDs identify the device unambiguously.
            if variable == "CUDA_VISIBLE_DEVICES" and any(not part.startswith("GPU-") for part in wanted):
                raise ValueError
            matches = {index for index, identity in devices.items() if index in wanted or identity in wanted}
            if len(matches) != len(wanted):
                raise ValueError
            selected &= matches
        if environment.get("CUDA_MPS_PIPE_DIRECTORY") or environment.get("CUDA_MPS_ACTIVE_THREAD_PERCENTAGE", "100") != "100":
            raise ValueError
        return {"gpu_allocation_verified": True, "gpu_indices": sorted(selected, key=int)}
    except ValueError:
        return {"gpu_allocation_verified": False, "gpu_indices": None}


def report():
    try:
        result = effective()
        result.update(gpu_allocation())
    except (OSError, ValueError, Unknown, UnicodeError):
        result = {"schema": 1, "capacity_verified": False, "cpu_logical": None, "memory_mib": None,
                  "environment": "unknown", "capacity_issues": ["capacity-probe-failed"],
                  "gpu_allocation_verified": False, "gpu_indices": None}
    print("capabilities\t" + json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    report()
