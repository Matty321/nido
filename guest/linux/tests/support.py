# SPDX-License-Identifier: Apache-2.0
"""Shared test helpers: puts guest/linux on sys.path and builds fake /proc data."""

import os
import sys
from collections import namedtuple
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

StatVFS = namedtuple("StatVFS", "f_frsize f_blocks f_bfree f_bavail")

NOW = datetime(2026, 10, 24, 12, 0, 0, tzinfo=timezone.utc)


def stat_text(user, nice=0, system=0, idle=0, iowait=0, irq=0, softirq=0,
              steal=0, guest=None, guest_nice=None):
    fields = [user, nice, system, idle, iowait, irq, softirq, steal]
    if guest is not None:
        fields += [guest, guest_nice or 0]
    return "cpu  " + " ".join(map(str, fields)) + "\ncpu0 1 2 3 4 5 6 7 8 9 10\n"


def meminfo_text(total_kb=8 * 1024 * 1024, available_kb=2 * 1024 * 1024,
                 swap_total_kb=0, swap_free_kb=0):
    return (
        "MemTotal:       %d kB\nMemFree:         100 kB\nMemAvailable:   %d kB\n"
        "Buffers:         10 kB\nSwapTotal:      %d kB\nSwapFree:       %d kB\n"
        % (total_kb, available_kb, swap_total_kb, swap_free_kb)
    )
