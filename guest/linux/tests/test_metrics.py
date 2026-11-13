# SPDX-License-Identifier: Apache-2.0
import unittest

import support  # noqa: F401  (sets sys.path)
from support import NOW, StatVFS, meminfo_text, stat_text

from nido_guest_tools import metrics


def doc(cpu_usage=10.0, mem_available_kb=4 * 1024 * 1024, disk=(4096, 1000, 500, 500)):
    cpu = metrics.cpu_stats(cpu_usage, 4, (1.0, 0.5, 0.25))
    mem = metrics.memory_stats(metrics.parse_meminfo(
        meminfo_text(available_kb=mem_available_kb)))
    dsk = metrics.disk_stats(StatVFS(*disk))
    system = {"hostname": "h", "architecture": "aarch64", "kernel": "6.12", "uptime_seconds": 5}
    return metrics.status_document(cpu, mem, dsk, system, NOW)


class MetricsTests(unittest.TestCase):
    def test_cpu_ignores_guest_columns(self):
        a = metrics.parse_cpu_times(stat_text(100, 0, 50, 800, 10))
        b = metrics.parse_cpu_times(stat_text(200, 0, 100, 1600, 20))
        with_guest = metrics.parse_cpu_times(stat_text(100, 0, 50, 800, 10, guest=1000))
        with_guest2 = metrics.parse_cpu_times(stat_text(200, 0, 100, 1600, 20, guest=1000))
        self.assertEqual(a, with_guest)
        self.assertEqual(metrics.cpu_usage(a, b), metrics.cpu_usage(with_guest, with_guest2))

    def test_cpu_zero_delta(self):
        s = metrics.parse_cpu_times(stat_text(100, 0, 50, 800, 10))
        self.assertEqual(metrics.cpu_usage(s, s), 0.0)

    def test_memory_uses_available(self):
        m = metrics.memory_stats(metrics.parse_meminfo(
            meminfo_text(total_kb=8 * 1024 * 1024, available_kb=2 * 1024 * 1024)))
        self.assertEqual(m["total_gib"], 8.0)
        self.assertEqual(m["available_gib"], 2.0)
        self.assertEqual(m["used_gib"], 6.0)
        self.assertEqual(m["usage_percent"], 75.0)

    def test_swap_absent_means_no_percent(self):
        m = metrics.memory_stats(metrics.parse_meminfo(meminfo_text()))
        self.assertIsNone(m["swap_usage_percent"])
        m = metrics.memory_stats(metrics.parse_meminfo(
            meminfo_text(swap_total_kb=1024 * 1024, swap_free_kb=768 * 1024)))
        self.assertEqual(m["swap_usage_percent"], 25.0)

    def test_disk_matches_reference(self):
        # used = blocks - bfree (not blocks - bavail); percent = used / (used + avail)
        d = metrics.disk_stats(StatVFS(4096, 1000, 400, 300))
        used = 600 * 4096
        avail = 300 * 4096
        self.assertEqual(d["used_gib"], round(used / 1024**3, 2))
        self.assertEqual(d["available_gib"], round(avail / 1024**3, 2))
        self.assertEqual(d["usage_percent"], round(100 * used / (used + avail), 1))
        self.assertEqual(metrics.disk_stats(StatVFS(4096, 0, 0, 0))["usage_percent"], 0)

    def test_thresholds_are_strict(self):
        self.assertEqual(metrics.cpu_stats(85.0, 1, (0, 0, 0))["status"], "OK")
        self.assertEqual(metrics.cpu_stats(85.1, 1, (0, 0, 0))["status"], "WARNING")
        total = 1000
        ok = metrics.memory_stats({"MemTotal": total, "MemAvailable": 150})  # 85.0
        bad = metrics.memory_stats({"MemTotal": total, "MemAvailable": 149})  # 85.1
        self.assertEqual(ok["status"], "OK")
        self.assertEqual(bad["status"], "WARNING")
        self.assertEqual(metrics.disk_stats(StatVFS(1, 100, 10, 10))["usage_percent"], 90.0)
        self.assertEqual(metrics.disk_stats(StatVFS(1, 100, 10, 10))["status"], "OK")
        self.assertEqual(metrics.disk_stats(StatVFS(1, 1000, 99, 99))["status"], "WARNING")

    def test_alerts_texts_match_api(self):
        d = doc(cpu_usage=99.0, mem_available_kb=1, disk=(1, 100, 1, 1))
        self.assertEqual(
            d["alerts"], ["High CPU", "Low available RAM", "Disk almost full"])
        self.assertEqual(d["status"], "WARNING")
        ok = doc()
        self.assertEqual(ok["alerts"], [])
        self.assertEqual(ok["status"], "OK")

    def test_document_has_top_level_hostname_and_system(self):
        d = doc()
        self.assertEqual(d["hostname"], "h")
        self.assertEqual(set(d["system"]),
                         {"hostname", "architecture", "kernel", "uptime_seconds"})
        self.assertEqual(d["agent"], "Nido AI Monitor")
        self.assertEqual(d["version"], "2.0")
        self.assertEqual(d["timestamp"], NOW.isoformat())
        self.assertIn("load_5min", d["cpu"])
        self.assertIn("load_15min", d["cpu"])
        self.assertNotIn("provisioning", d)

    def test_provisioning_embedded_when_given(self):
        d = metrics.status_document(
            doc()["cpu"], doc()["memory"], doc()["disk"], doc()["system"], NOW,
            {"step": "ollama", "state": "running"})
        self.assertEqual(d["provisioning"]["step"], "ollama")

    def test_load_provisioning(self):
        import json
        import os
        import tempfile
        with tempfile.TemporaryDirectory() as t:
            p = os.path.join(t, "state.json")
            self.assertIsNone(metrics.load_provisioning(p))
            with open(p, "w") as f:
                f.write("not json")
            self.assertIsNone(metrics.load_provisioning(p))
            with open(p, "w") as f:
                json.dump({"step": "x"}, f)
            self.assertEqual(metrics.load_provisioning(p), {"step": "x"})

    def test_running_step_of_another_boot_is_reported_interrupted(self):
        import json
        import os
        import tempfile
        with tempfile.TemporaryDirectory() as t:
            p = os.path.join(t, "state.json")
            boot = os.path.join(t, "boot_id")
            proc = os.path.join(t, "proc")
            os.makedirs(os.path.join(proc, "42"))
            with open(boot, "w") as f:
                f.write("boot-B\n")
            steps = {
                "old": {"state": "running", "message": "m", "boot_id": "boot-A", "pid": 42},
                "dead": {"state": "running", "message": "m", "boot_id": "boot-B", "pid": 7},
                "live": {"state": "running", "message": "m", "boot_id": "boot-B", "pid": 42},
                "done": {"state": "done", "message": "ok", "boot_id": "boot-A"},
                "legacy": {"state": "running", "message": "m"},
            }
            with open(p, "w") as f:
                json.dump({"version": 1, "steps": steps}, f)
            got = metrics.load_provisioning(p, boot_id_path=boot, proc=proc)["steps"]
            self.assertEqual(got["old"]["state"], "failed")
            self.assertEqual(got["old"]["message"], "interrupted (the VM was stopped or the command "
                             "was interrupted): click Try Again")
            from nido_guest_tools import provision
            self.assertEqual(got["old"]["message"], provision.INTERRUPTED)
            self.assertEqual(got["dead"]["state"], "failed")
            self.assertEqual(got["live"]["state"], "running")
            self.assertEqual(got["done"]["state"], "done")
            self.assertEqual(got["legacy"]["state"], "running")
            # Unreadable boot id: entries are left as they are.
            got = metrics.load_provisioning(p, boot_id_path=boot + "x", proc=proc)["steps"]
            self.assertEqual(got["old"]["state"], "running")


if __name__ == "__main__":
    unittest.main()
