# SPDX-License-Identifier: Apache-2.0
"""vsock HTTP/1.0 status server. Listens on AF_VSOCK only, never TCP."""

import errno
import json
import os
import socket
import sys
import threading
import time
from datetime import datetime, timezone

from . import metrics

PORT = 7700
MAX_REQUEST = 4096
REQUEST_TIMEOUT = 2.0
PROVISION_STATE = "/var/lib/nido-provision/state.json"


CLOSED_ERRNOS = (errno.EBADF, errno.EINVAL, errno.ENOTSOCK)
ACCEPT_BACKOFF = 0.5
SAMPLER_LOG_INTERVAL = 60.0


def log(message):
    """One line to stderr (the systemd journal)."""
    try:
        print("nido-guest-tools: " + message, file=sys.stderr, flush=True)
    except (OSError, ValueError):
        pass


def _read_text(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


class Sampler(threading.Thread):
    """Background CPU sampler: one sample per interval, requests read the last value."""

    def __init__(self, interval=1.0, read_stat=None):
        super().__init__(daemon=True)
        self.interval = interval
        self._read_stat = read_stat or (lambda: _read_text("/proc/stat"))
        self._prev = None
        self._usage = 0.0
        self._lock = threading.Lock()
        self._stop_event = threading.Event()
        self._last_error = None
        self._last_error_time = 0.0

    def _report(self, exc):
        text = "%s: %s" % (type(exc).__name__, exc)
        now = time.monotonic()
        if text != self._last_error or now - self._last_error_time >= SAMPLER_LOG_INTERVAL:
            self._last_error, self._last_error_time = text, now
            log("cpu sampling failed: " + text)

    def step(self):
        cur = metrics.parse_cpu_times(self._read_stat())
        with self._lock:
            if self._prev is not None:
                self._usage = metrics.cpu_usage(self._prev, cur)
            self._prev = cur

    def usage(self):
        with self._lock:
            return self._usage

    def run(self):
        while not self._stop_event.is_set():
            try:
                self.step()
            except (OSError, ValueError, IndexError) as exc:
                self._report(exc)
            self._stop_event.wait(self.interval)

    def stop(self):
        self._stop_event.set()


def build_status(sampler, provision_path=PROVISION_STATE, proc="/proc", root="/"):
    """Collect the live status document. Never sleeps."""
    uname = os.uname()
    uptime = round(float(_read_text(proc + "/uptime").split()[0]))
    system = {
        "hostname": uname.nodename,
        "architecture": uname.machine,
        "kernel": uname.release,
        "uptime_seconds": uptime,
    }
    cpu = metrics.cpu_stats(sampler.usage(), os.cpu_count(), os.getloadavg())
    mem = metrics.memory_stats(metrics.parse_meminfo(_read_text(proc + "/meminfo")))
    disk = metrics.disk_stats(os.statvfs(root))
    return metrics.status_document(
        cpu, mem, disk, system, datetime.now(timezone.utc),
        metrics.load_provisioning(provision_path),
    )


def _response(code, reason, body=b""):
    head = (
        "HTTP/1.0 %d %s\r\nContent-Type: application/json\r\n"
        "Content-Length: %d\r\nConnection: close\r\n\r\n" % (code, reason, len(body))
    )
    return head.encode("ascii") + body


def _read_request(conn, timeout):
    """Read until end of headers or 4 KiB, within one overall deadline. None on timeout."""
    deadline = time.monotonic() + timeout
    data = b""
    while len(data) < MAX_REQUEST:
        if b"\r\n\r\n" in data or b"\n\n" in data:
            break
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        conn.settimeout(remaining)
        try:
            chunk = conn.recv(MAX_REQUEST - len(data))
        except (socket.timeout, OSError):
            return None
        if not chunk:
            break
        data += chunk
    return data


def handle_connection(conn, status_fn, timeout=REQUEST_TIMEOUT):
    """Serve one request on conn, then close it."""
    try:
        data = _read_request(conn, timeout)
        if data is None:
            return
        parts = data.split(b"\n", 1)[0].decode("latin-1").split()
        if len(parts) >= 2 and parts[0] == "GET" and parts[1] == "/api/status":
            try:
                body = json.dumps(status_fn(), ensure_ascii=False).encode("utf-8")
                out = _response(200, "OK", body)
            except Exception as exc:
                log("status failed: %s: %s" % (type(exc).__name__, exc))
                out = _response(500, "Internal Server Error")
        else:
            out = _response(404, "Not Found")
        conn.settimeout(timeout)
        conn.sendall(out)
    except OSError:
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


def vsock_listener(port):
    """Bind a listening AF_VSOCK socket. Raises if vsock is unavailable (no TCP fallback)."""
    if not hasattr(socket, "AF_VSOCK"):
        raise RuntimeError("AF_VSOCK not available on this system")
    sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    sock.bind((socket.VMADDR_CID_ANY, port))
    sock.listen(1)
    return sock


def serve(port=PORT, listener=None, status_fn=None, timeout=REQUEST_TIMEOUT,
          backoff=ACCEPT_BACKOFF):
    """Accept connections one at a time. Transient accept errors are logged and retried
    after a short backoff; returns only when the listener is closed."""
    if listener is None:
        listener = vsock_listener(port)
    if status_fn is None:
        sampler = Sampler()
        sampler.step()
        sampler.start()
        status_fn = lambda: build_status(sampler)
    while True:
        try:
            conn, _ = listener.accept()
        except OSError as exc:
            if exc.errno in CLOSED_ERRNOS:
                log("listener closed: %s" % exc)
                return
            log("accept failed, retrying: %s" % exc)
            time.sleep(backoff)
            continue
        handle_connection(conn, status_fn, timeout)


def main():
    serve()
    # serve() only returns when the listener is closed: exit non-zero so
    # systemd (Restart=on-failure) restarts the service.
    sys.exit(1)
