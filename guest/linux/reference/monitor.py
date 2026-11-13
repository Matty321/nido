
#!/usr/bin/env python3

import json
import os
import time
from datetime import datetime, timezone


def read_cpu():
    """Misura l'utilizzo CPU tra due campionamenti."""

    def sample():
        with open("/proc/stat") as f:
            values = list(map(int, f.readline().split()[1:]))

        idle = values[3] + values[4]
        total = sum(values)
        return idle, total

    idle1, total1 = sample()
    time.sleep(1)
    idle2, total2 = sample()

    total_delta = total2 - total1
    idle_delta = idle2 - idle1

    usage = (
        100 * (1 - idle_delta / total_delta)
        if total_delta > 0 else 0
    )

    return {
        "vcpus": os.cpu_count(),
        "usage_percent": round(usage, 1),
        "load_1min": round(os.getloadavg()[0], 2),
        "status": "WARNING" if usage > 85 else "OK"
    }


def read_memory():
    """Legge la RAM direttamente dal kernel."""

    values = {}

    with open("/proc/meminfo") as f:
        for line in f:
            key, value = line.split(":", 1)
            values[key] = int(value.strip().split()[0])

    total = values["MemTotal"] * 1024
    available = values["MemAvailable"] * 1024
    used = total - available

    swap_total = values["SwapTotal"] * 1024
    swap_free = values["SwapFree"] * 1024

    usage = 100 * used / total

    return {
        "total_gib": round(total / 1024**3, 2),
        "used_gib": round(used / 1024**3, 2),
        "available_gib": round(available / 1024**3, 2),
        "usage_percent": round(usage, 1),
        "swap_total_gib": round(swap_total / 1024**3, 2),
        "swap_used_gib": round(
            (swap_total - swap_free) / 1024**3, 2
        ),
        "status": "WARNING" if usage > 85 else "OK"
    }


def read_disk():
    """Legge lo spazio del filesystem root."""

    disk = os.statvfs("/")

    total = disk.f_blocks * disk.f_frsize
    free = disk.f_bavail * disk.f_frsize
    used = (disk.f_blocks - disk.f_bfree) * disk.f_frsize

    usage = 100 * used / (used + free) if used + free else 0

    return {
        "total_gib": round(total / 1024**3, 2),
        "used_gib": round(used / 1024**3, 2),
        "available_gib": round(free / 1024**3, 2),
        "usage_percent": round(usage, 1),
        "status": "WARNING" if usage > 90 else "OK"
    }


def main():
    cpu = read_cpu()
    memory = read_memory()
    disk = read_disk()

    alerts = []

    if cpu["status"] != "OK":
        alerts.append("Utilizzo CPU elevato")

    if memory["status"] != "OK":
        alerts.append("Memoria RAM disponibile ridotta")

    if disk["status"] != "OK":
        alerts.append("Spazio disco quasi esaurito")

    result = {
        "agent": "Nido AI Monitor",
        "version": "2.0",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "system": {
            "hostname": os.uname().nodename,
            "architecture": os.uname().machine,
            "kernel": os.uname().release,
            "uptime_seconds": round(
                float(open("/proc/uptime").read().split()[0])
            )
        },
        "cpu": cpu,
        "memory": memory,
        "disk": disk,
        "alerts": alerts,
        "status": "WARNING" if alerts else "OK"
    }

    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
