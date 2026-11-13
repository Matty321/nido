# SPDX-License-Identifier: Apache-2.0
import contextlib
import io
import json
import os
import sys
import unittest
from types import SimpleNamespace
from unittest import mock

import support  # noqa: F401
from support import NOW, StatVFS, meminfo_text, stat_text

from nido_guest_tools import metrics

sys.path.insert(0, os.path.join(support.ROOT, "reference"))
import monitor  # noqa: E402
import monitor_api  # noqa: E402

STAT1 = stat_text(1000, 10, 500, 8000, 200, 5, 5, 0)
STAT2 = stat_text(1400, 10, 700, 8300, 250, 5, 5, 0)
MEMINFO = meminfo_text(total_kb=4 * 1024 * 1024, available_kb=1 * 1024 * 1024,
                       swap_total_kb=2 * 1024 * 1024, swap_free_kb=1536 * 1024)
UPTIME = "12345.67 9999.00\n"
VFS = StatVFS(4096, 2_000_000, 500_000, 400_000)
LOADS = (0.52, 0.4, 0.3)


def fake_os():
    return SimpleNamespace(
        cpu_count=lambda: 4,
        getloadavg=lambda: LOADS,
        statvfs=lambda p: VFS,
        uname=lambda: SimpleNamespace(nodename="ai-linux", machine="aarch64", release="6.12.0"),
    )


def fake_open_factory():
    stats = iter([STAT1, STAT2])

    def fake_open(path, *a, **k):
        if path == "/proc/stat":
            return io.StringIO(next(stats))
        if path == "/proc/meminfo":
            return io.StringIO(MEMINFO)
        if path == "/proc/uptime":
            return io.StringIO(UPTIME)
        raise FileNotFoundError(path)

    return fake_open


def reference_api_document():
    fos = fake_os()
    with contextlib.ExitStack() as stack:
        stack.enter_context(mock.patch.object(monitor, "open", fake_open_factory(), create=True))
        stack.enter_context(mock.patch.object(monitor, "os", fos))
        stack.enter_context(mock.patch.object(monitor_api, "os", fos))
        stack.enter_context(mock.patch.object(monitor, "time", SimpleNamespace(sleep=lambda s: None)))
        h = monitor_api.MonitorHandler.__new__(monitor_api.MonitorHandler)
        h.path = "/api/status"
        h.wfile = io.BytesIO()
        h.send_response = h.send_header = h.end_headers = lambda *a: None
        h.do_GET()
        api = json.loads(h.wfile.getvalue())
        # monitor.py's own main() document (system block, alerts wording)
        out = io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(monitor, "open", fake_open_factory(), create=True))
            stack.enter_context(mock.patch("sys.stdout", out))
            monitor.main()
        return api, json.loads(out.getvalue())


def our_document():
    fos = fake_os()
    cur = metrics.parse_cpu_times(STAT2)
    prev = metrics.parse_cpu_times(STAT1)
    cpu = metrics.cpu_stats(metrics.cpu_usage(prev, cur), fos.cpu_count(), LOADS)
    mem = metrics.memory_stats(metrics.parse_meminfo(MEMINFO))
    disk = metrics.disk_stats(VFS)
    system = {"hostname": "ai-linux", "architecture": "aarch64", "kernel": "6.12.0",
              "uptime_seconds": round(float(UPTIME.split()[0]))}
    return metrics.status_document(cpu, mem, disk, system, NOW)


class CompatTests(unittest.TestCase):
    def test_compat_with_reference(self):
        api, mon = reference_api_document()
        ours = our_document()
        for key, value in api.items():
            if key == "timestamp":
                self.assertIn(key, ours)
                continue
            self.assertIn(key, ours, key)
            if isinstance(value, dict):
                for k, v in value.items():
                    self.assertEqual(ours[key][k], v, "%s.%s" % (key, k))
            else:
                self.assertEqual(ours[key], value, key)
        # monitor.py system block
        self.assertEqual(ours["system"], mon["system"])


if __name__ == "__main__":
    unittest.main()
