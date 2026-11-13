# SPDX-License-Identifier: Apache-2.0
"""Pure metric functions: text in, dictionaries out. No I/O, no sleeping."""

import json
import os

GIB = 1024**3
CPU_THRESHOLD = 85
MEMORY_THRESHOLD = 85
DISK_THRESHOLD = 90

AGENT = "Nido AI Monitor"
VERSION = "2.0"

# English, as the Monitor view's own warnings (the app does not show these).
ALERT_CPU = "High CPU"
ALERT_MEMORY = "Low available RAM"
ALERT_DISK = "Disk almost full"


def parse_cpu_times(stat_text):
    """Return (idle, total) from the aggregate "cpu" line of /proc/stat.

    Only the first 8 fields (user..steal) count: guest and guest_nice are
    already included in user and nice.
    """
    first = stat_text.splitlines()[0]
    values = [int(v) for v in first.split()[1:9]]
    idle = values[3] + values[4]
    return idle, sum(values)


def cpu_usage(prev, cur):
    """CPU usage percent between two (idle, total) samples."""
    total_delta = cur[1] - prev[1]
    idle_delta = cur[0] - prev[0]
    if total_delta <= 0:
        return 0.0
    return 100 * (1 - idle_delta / total_delta)


def cpu_stats(usage, vcpus, loads):
    """CPU section. loads is (1min, 5min, 15min)."""
    return {
        "vcpus": vcpus,
        "usage_percent": round(usage, 1),
        "load_1min": round(loads[0], 2),
        "load_5min": round(loads[1], 2),
        "load_15min": round(loads[2], 2),
        "status": "WARNING" if usage > CPU_THRESHOLD else "OK",
    }


def parse_meminfo(text):
    """Parse /proc/meminfo into {key: kB}."""
    values = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        fields = value.split()
        if fields:
            values[key] = int(fields[0])
    return values


def memory_stats(meminfo):
    """Memory section, based on MemAvailable."""
    total = meminfo["MemTotal"] * 1024
    available = meminfo["MemAvailable"] * 1024
    used = total - available
    swap_total = meminfo.get("SwapTotal", 0) * 1024
    swap_free = meminfo.get("SwapFree", 0) * 1024
    swap_used = swap_total - swap_free
    usage = 100 * used / total if total else 0
    return {
        "total_gib": round(total / GIB, 2),
        "used_gib": round(used / GIB, 2),
        "available_gib": round(available / GIB, 2),
        "usage_percent": round(usage, 1),
        "swap_total_gib": round(swap_total / GIB, 2),
        "swap_used_gib": round(swap_used / GIB, 2),
        "swap_usage_percent": (
            round(100 * swap_used / swap_total, 1) if swap_total else None
        ),
        "status": "WARNING" if usage > MEMORY_THRESHOLD else "OK",
    }


def disk_stats(st):
    """Disk section from an os.statvfs-like object (same formula as the original)."""
    total = st.f_blocks * st.f_frsize
    free = st.f_bavail * st.f_frsize
    used = (st.f_blocks - st.f_bfree) * st.f_frsize
    usage = 100 * used / (used + free) if used + free else 0
    return {
        "total_gib": round(total / GIB, 2),
        "used_gib": round(used / GIB, 2),
        "available_gib": round(free / GIB, 2),
        "usage_percent": round(usage, 1),
        "status": "WARNING" if usage > DISK_THRESHOLD else "OK",
    }


def status_document(cpu, mem, disk, system, now, provisioning=None):
    """Full /api/status document. now is a timezone-aware datetime."""
    alerts = []
    if cpu["status"] != "OK":
        alerts.append(ALERT_CPU)
    if mem["status"] != "OK":
        alerts.append(ALERT_MEMORY)
    if disk["status"] != "OK":
        alerts.append(ALERT_DISK)
    doc = {
        "agent": AGENT,
        "version": VERSION,
        "timestamp": now.isoformat(),
        "hostname": system["hostname"],
        "system": system,
        "cpu": cpu,
        "memory": mem,
        "disk": disk,
        "alerts": alerts,
        "status": "WARNING" if alerts else "OK",
    }
    if provisioning is not None:
        doc["provisioning"] = provisioning
    return doc


def load_provisioning(path, boot_id_path="/proc/sys/kernel/random/boot_id", proc="/proc"):
    """Parsed JSON object from path, or None if missing, unreadable or not an object.

    A step still `running` that was started in another boot, or whose process is gone, is
    reported as `failed` ("interrupted"): nido-provision records `boot_id` and `pid` in running
    entries. The file itself is never written (the monitor only reads it)."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    try:
        with open(boot_id_path, encoding="ascii") as f:
            boot_id = f.read().strip()
    except OSError:
        return data
    steps = data.get("steps")
    if not isinstance(steps, dict):
        return data
    for entry in steps.values():
        if not isinstance(entry, dict) or entry.get("state") != "running":
            continue
        other_boot = isinstance(entry.get("boot_id"), str) and entry["boot_id"] != boot_id
        pid = entry.get("pid")
        dead = (not other_boot and isinstance(pid, int) and not isinstance(pid, bool)
                and not os.path.exists(os.path.join(proc, str(pid))))
        if other_boot or dead:
            entry["state"] = "failed"
            # As provision.INTERRUPTED.
            entry["message"] = "interrupted (the VM was stopped or the command was interrupted): click Try Again"
    return data
