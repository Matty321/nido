# SPDX-License-Identifier: Apache-2.0
import contextlib
import errno
import io
import json
import os
import tempfile
import socket
import threading
import time
import unittest
from unittest import mock

import support  # noqa: F401
from nido_guest_tools import server


def status():
    return {"status": "OK"}


class OneShotListener:
    """Fake listener: hands out prepared connections, then fails like a closed socket."""

    def __init__(self, *conns):
        self.conns = list(conns)

    def accept(self):
        if not self.conns:
            raise OSError(errno.EBADF, "closed")
        return self.conns.pop(0), None


class FlakyListener(OneShotListener):
    """Raises a transient error first, then hands out its connections."""

    def __init__(self, error, *conns):
        super().__init__(*conns)
        self.error = error

    def accept(self):
        if self.error is not None:
            err, self.error = self.error, None
            raise err
        return super().accept()


def exchange(request, timeout=2.0, send=True, listener=None, status_fn=status, err=None):
    """One request through server.serve. The server's log lines (e.g. "listener closed") go to
    err, or are dropped, so the test output stays clean."""
    client, srv = socket.socketpair()
    with contextlib.redirect_stderr(err if err is not None else io.StringIO()):
        t = threading.Thread(
            target=server.serve,
            kwargs=dict(listener=listener(srv) if listener else OneShotListener(srv),
                        status_fn=status_fn, timeout=timeout, backoff=0.01))
        t.start()
        if send:
            client.sendall(request)
        client.settimeout(5)
        data = b""
        while True:
            chunk = client.recv(4096)
            if not chunk:
                break
            data += chunk
        t.join()
    client.close()
    return data


class ServerTests(unittest.TestCase):
    def test_server_answers_status(self):
        t0 = time.monotonic()
        data = exchange(b"GET /api/status HTTP/1.0\r\n\r\n")
        self.assertLess(time.monotonic() - t0, 0.1)  # request_does_not_sleep
        head, body = data.split(b"\r\n\r\n", 1)
        self.assertTrue(head.startswith(b"HTTP/1.0 200"))
        self.assertIn(b"Content-Type: application/json", head)
        self.assertEqual(json.loads(body), {"status": "OK"})

    def test_server_rejects_other_paths(self):
        for req in (b"GET /other HTTP/1.0\r\n\r\n", b"POST /api/status HTTP/1.0\r\n\r\n",
                    b"garbage\r\n\r\n"):
            self.assertTrue(exchange(req).startswith(b"HTTP/1.0 404"))

    def test_server_times_out_slow_client(self):
        t0 = time.monotonic()
        data = exchange(b"", timeout=0.2, send=False)
        self.assertEqual(data, b"")
        self.assertLess(time.monotonic() - t0, 1.5)

    def test_request_does_not_sleep(self):
        s = server.Sampler(read_stat=lambda: "cpu 1 0 1 1 0 0 0 0\n")
        t0 = time.monotonic()
        s.step()
        s.step()
        self.assertLess(time.monotonic() - t0, 0.1)
        self.assertEqual(s.usage(), 0.0)

    def test_sampler_reports_last_usage(self):
        texts = iter(["cpu 0 0 0 100 0 0 0 0\n", "cpu 50 0 0 150 0 0 0 0\n"])
        s = server.Sampler(read_stat=lambda: next(texts))
        s.step()
        s.step()
        self.assertEqual(s.usage(), 50.0)

    def test_serve_survives_transient_accept_error(self):
        for code in (errno.EMFILE, errno.ECONNABORTED, errno.EINTR):
            err = io.StringIO()
            data = exchange(
                b"GET /api/status HTTP/1.0\r\n\r\n",
                listener=lambda srv, c=code: FlakyListener(OSError(c, "boom"), srv), err=err)
            self.assertTrue(data.startswith(b"HTTP/1.0 200"))
            self.assertIn("accept failed", err.getvalue())

    def test_main_exits_nonzero_when_serve_returns(self):
        with mock.patch.object(server, "serve", lambda: None):
            with self.assertRaises(SystemExit) as cm:
                server.main()
        self.assertNotEqual(cm.exception.code, 0)

    def test_status_failure_logs_to_stderr(self):
        def boom():
            raise ValueError("bad proc")
        err = io.StringIO()
        data = exchange(b"GET /api/status HTTP/1.0\r\n\r\n", status_fn=boom, err=err)
        self.assertTrue(data.startswith(b"HTTP/1.0 500"))
        self.assertIn("status failed: ValueError: bad proc", err.getvalue())

    def test_sampler_errors_logged_once_per_interval(self):
        def bad():
            raise OSError("no stat")
        s = server.Sampler(interval=0.01, read_stat=bad)
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            s.start()
            time.sleep(0.15)
            s.stop()
            s.join(1)
        lines = [l for l in err.getvalue().splitlines() if "cpu sampling failed" in l]
        self.assertEqual(len(lines), 1)

    def test_build_status_real_path(self):
        from support import meminfo_text
        with tempfile.TemporaryDirectory() as proc:
            with open(os.path.join(proc, "uptime"), "w") as f:
                f.write("123.4 5.6\n")
            with open(os.path.join(proc, "meminfo"), "w") as f:
                f.write(meminfo_text())
            sampler = mock.Mock()
            sampler.usage.return_value = 12.34
            t0 = time.monotonic()
            d = server.build_status(sampler, provision_path=os.path.join(proc, "none"),
                                    proc=proc, root="/")
            self.assertLess(time.monotonic() - t0, 0.1)
        self.assertEqual(d["cpu"]["usage_percent"], 12.3)
        self.assertEqual(d["system"]["uptime_seconds"], 123)
        self.assertEqual(d["hostname"], d["system"]["hostname"])
        self.assertNotIn("provisioning", d)

    def test_no_tcp_fallback(self):
        if hasattr(socket, "AF_VSOCK"):
            self.skipTest("AF_VSOCK exists here")
        with self.assertRaises(RuntimeError):
            server.vsock_listener(7700)


if __name__ == "__main__":
    unittest.main()
