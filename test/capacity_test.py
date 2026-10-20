"""Verify effective allocation against synthetic Linux kernel views."""

import importlib.util
from pathlib import Path
import os
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("capacity", REPO / "lib/workgrove/vm/capacity.py")
capacity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capacity)


class CapacityTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="capacity-", dir=os.environ.get("TEST_ROOT"))
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.view = capacity.KernelView(self.root)
        self.put("/sys/devices/system/cpu/online", "0-15")
        self.put("/proc/meminfo", "MemTotal: 67108864 kB\n")
        self.put("/proc/self/cgroup", "0::/team/job\n")
        self.put("/proc/self/mountinfo", "1 0 8:1 / / rw - ext4 /dev/root rw\n"
                 "10 1 0:1 / /sys/fs/cgroup rw - cgroup2 cgroup rw\n")
        for path in ("/sys/fs/cgroup", "/sys/fs/cgroup/team", "/sys/fs/cgroup/team/job"):
            self.put(path + "/cgroup.controllers", "cpu memory cpuset")
        for path in ("/sys/fs/cgroup/team", "/sys/fs/cgroup/team/job"):
            self.put(path + "/cpu.max", "max 100000")
            self.put(path + "/memory.max", "max")

    def put(self, path, value):
        destination = self.view.path(path)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(value)

    def report(self, affinity=None):
        return capacity.effective(self.view, set(range(16)) if affinity is None else affinity)

    def test_full_host_and_affinity_intersection(self):
        report = self.report({1, 2, 14, 16})
        self.assertTrue(report["capacity_verified"])
        self.assertEqual(report["cpu_logical"], 3)
        self.assertEqual(report["memory_mib"], 65536)

    def test_ancestor_quota_memory_and_cpuset_limits(self):
        self.put("/sys/fs/cgroup/team/cpu.max", "250000 100000")
        self.put("/sys/fs/cgroup/team/job/cpu.max", "700000 100000")
        self.put("/sys/fs/cgroup/team/cpuset.cpus.effective", "0-6")
        self.put("/sys/fs/cgroup/team/job/cpuset.cpus.effective", "2-5")
        self.put("/sys/fs/cgroup/team/memory.max", str(8192 * 1024 * 1024 + 1023))
        self.put("/sys/fs/cgroup/team/job/memory.max", str(16384 * 1024 * 1024))
        report = self.report()
        self.assertTrue(report["capacity_verified"])
        self.assertEqual(report["cpu_logical"], 2)
        self.assertEqual(report["memory_mib"], 8192)

    def test_fractional_cpu_capacity_stays_zero(self):
        self.put("/sys/fs/cgroup/team/cpu.max", "50000 100000")
        report = self.report()
        self.assertTrue(report["capacity_verified"])
        self.assertEqual(report["cpu_logical"], 0)

    def test_malformed_quota_does_not_replace_unknown_with_physical_cpu(self):
        for value in ("max", "bad 100000", "100000 0", "-1 100000", "0 100000"):
            with self.subTest(value=value):
                self.put("/sys/fs/cgroup/team/cpu.max", value)
                report = self.report()
                self.assertFalse(report["capacity_verified"])
                self.assertIsNone(report["cpu_logical"])
                self.assertEqual(report["memory_mib"], 65536)

    def test_malformed_memory_does_not_invalidate_known_cpu(self):
        self.put("/sys/fs/cgroup/team/memory.max", "not-a-number")
        report = self.report()
        self.assertFalse(report["capacity_verified"])
        self.assertEqual(report["cpu_logical"], 16)
        self.assertIsNone(report["memory_mib"])

    def test_namespaced_container_root_is_not_a_full_host_allocation(self):
        self.put("/.dockerenv", "")
        self.put("/proc/self/cgroup", "0::/\n")
        self.put("/sys/fs/cgroup/cpu.max", "400000 100000")
        self.put("/sys/fs/cgroup/memory.max", str(8 * 1024 ** 3))
        report = self.report()
        self.assertFalse(report["capacity_verified"])
        self.assertIsNone(report["cpu_logical"])
        self.assertIsNone(report["memory_mib"])
        self.assertEqual(report["observed_cpu_logical"], 4)
        self.assertIn("cpu-ancestors-hidden", report["capacity_issues"])

    def test_container_with_visible_initial_root_can_be_measured(self):
        self.put("/.dockerenv", "")
        report = self.report()
        self.assertTrue(report["capacity_verified"])
        self.assertEqual(report["environment"], "container")

    def test_hidden_mount_ancestors_are_unknown(self):
        self.put("/proc/self/mountinfo", "10 1 0:1 /team /sys/fs/cgroup rw - cgroup2 cgroup rw\n")
        self.put("/sys/fs/cgroup/job/cpu.max", "200000 100000")
        self.put("/sys/fs/cgroup/job/memory.max", "max")
        report = self.report()
        self.assertFalse(report["capacity_verified"])
        self.assertIsNone(report["cpu_logical"])
        self.assertIsNone(report["memory_mib"])

    def test_missing_mount_and_deleted_membership_are_unknown(self):
        self.put("/proc/self/mountinfo", "1 0 8:1 / / rw - ext4 /dev/root rw\n")
        self.assertFalse(self.report()["capacity_verified"])
        self.put("/proc/self/cgroup", "0::/team/job (deleted)\n")
        self.assertFalse(self.report()["capacity_verified"])

    def test_cgroup_v1_ancestor_limits_and_unlimited_memory(self):
        self.put("/proc/self/cgroup", "2:cpu,cpuacct:/team/job\n3:memory:/team/job\n4:cpuset:/team/job\n")
        self.put("/proc/self/mountinfo", "10 1 0:1 / /cg/cpu rw - cgroup cgroup rw,cpu,cpuacct\n"
                 "11 1 0:2 / /cg/memory rw - cgroup cgroup rw,memory\n"
                 "12 1 0:3 / /cg/cpuset rw - cgroup cgroup rw,cpuset\n")
        for suffix in ("", "/team", "/team/job"):
            self.put("/cg/cpu" + suffix + "/cpu.cfs_quota_us", "-1")
            self.put("/cg/cpu" + suffix + "/cpu.cfs_period_us", "100000")
            self.put("/cg/memory" + suffix + "/memory.limit_in_bytes", str((1 << 63) - 4096))
            self.put("/cg/cpuset" + suffix + "/cpuset.cpus", "0-15")
        self.put("/cg/cpu/team/cpu.cfs_quota_us", "350000")
        self.put("/cg/memory/team/memory.limit_in_bytes", str(4096 * 1024 * 1024))
        self.put("/cg/cpuset/team/job/cpuset.cpus", "0-3")
        report = self.report()
        self.assertTrue(report["capacity_verified"])
        self.assertEqual(report["cpu_logical"], 3)
        self.assertEqual(report["memory_mib"], 4096)

    def test_malformed_and_oversized_cpu_sets_are_unknown(self):
        for value in ("x", "4-1", "0-999999999", "1,,2"):
            with self.subTest(value=value):
                self.put("/sys/devices/system/cpu/online", value)
                self.assertIsNone(self.report()["cpu_logical"])

    def test_missing_active_controller_files_remain_unknown(self):
        self.view.path("/sys/fs/cgroup/team/job/cpu.max").unlink()
        self.view.path("/sys/fs/cgroup/team/job/memory.max").unlink()
        report = self.report()
        self.assertFalse(report["capacity_verified"])
        self.assertIsNone(report["cpu_logical"])
        self.assertIsNone(report["memory_mib"])

    def test_migration_during_probe_invalidates_allocation(self):
        original = self.view.read
        calls = []
        def read(path, optional=False):
            if str(path) == "/proc/self/cgroup":
                calls.append(path)
                if len(calls) > 1:
                    return "0::/different-group"
            return original(path, optional)
        self.view.read = read
        self.assertFalse(self.report()["capacity_verified"])

    def gpu(self, environment, query, detail=None):
        if detail is None:
            detail = "Virtualization Mode : None\n" * len(query.splitlines())
        return capacity.gpu_allocation(environment, query, detail)

    def test_virtual_gpus_and_unobservable_sharing_are_not_verified(self):
        query = "0, GPU-first, Disabled\n"
        self.assertFalse(self.gpu({}, query, "Virtualization Mode : VGPU\n")["gpu_allocation_verified"])
        self.assertFalse(self.gpu({}, query, "Virtualization Mode : None\nProcess Name : nvidia-cuda-mps-server\n")["gpu_allocation_verified"])
        self.assertFalse(capacity.gpu_allocation({}, query)["gpu_allocation_verified"])

    def test_gpu_uuid_filtering_and_unknown_partitions(self):
        query = "0, GPU-first, Disabled\n1, GPU-second, [N/A]\n"
        report = self.gpu({"NVIDIA_VISIBLE_DEVICES": "all", "CUDA_VISIBLE_DEVICES": "GPU-second"}, query)
        self.assertTrue(report["gpu_allocation_verified"])
        self.assertEqual(report["gpu_indices"], ["1"])
        report = self.gpu({"CUDA_VISIBLE_DEVICES": "0"}, query)
        self.assertFalse(report["gpu_allocation_verified"])
        for value in ("0, MIG-partition, Enabled\n", "0, GPU-first, Enabled\n", "bad query\n"):
            self.assertFalse(self.gpu({}, value)["gpu_allocation_verified"])

    def test_gpu_none_and_fractional_sharing(self):
        query = "0, GPU-first, Disabled\n"
        self.assertEqual(self.gpu({"NVIDIA_VISIBLE_DEVICES": "none"}, query)["gpu_indices"], [])
        self.assertFalse(self.gpu({"CUDA_MPS_ACTIVE_THREAD_PERCENTAGE": "50"}, query)["gpu_allocation_verified"])
        self.assertFalse(self.gpu({"CUDA_VISIBLE_DEVICES": "GPU-missing"}, query)["gpu_allocation_verified"])


if __name__ == "__main__":
    unittest.main()
