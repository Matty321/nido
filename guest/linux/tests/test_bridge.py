# SPDX-License-Identifier: Apache-2.0
import contextlib
import errno
import io
import json
import os
import queue
import socket
import threading
import time
import unittest

import support  # noqa: F401
from nido_guest_tools import bridge

UNIT = os.path.join(support.ROOT, "systemd", "nido-ai-bridge.service")


class QueueListener:
    """Fake listener: accept() hands out queued connections; None means closed."""

    def __init__(self):
        self.queue = queue.Queue()

    def add(self, conn):
        self.queue.put(conn)

    def close(self):
        self.queue.put(None)

    def accept(self):
        conn = self.queue.get()
        if conn is None:
            raise OSError(errno.EBADF, "closed")
        return conn, ("127.0.0.1", 0)


def read_all(sock, timeout=5.0):
    sock.settimeout(timeout)
    data = b""
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            return data
        data += chunk


class Bridge:
    """Runs bridge.serve on a QueueListener with an injected vsock connector."""

    def __init__(self, connect, max_connections=bridge.MAX_CONNECTIONS):
        self.listener = QueueListener()
        self.err = io.StringIO()
        self.thread = threading.Thread(
            target=self._run, args=(connect, max_connections), daemon=True)
        self.thread.start()

    def _run(self, connect, max_connections):
        with contextlib.redirect_stderr(self.err):
            bridge.serve(listener=self.listener, connect=connect,
                         max_connections=max_connections, backoff=0.01)

    def client(self):
        """A new guest client connected through the bridge."""
        client, srv = socket.socketpair()
        self.listener.add(srv)
        return client

    def stop(self):
        self.listener.close()
        self.thread.join(5)


class BridgeTests(unittest.TestCase):
    def test_listens_only_on_loopback(self):
        self.assertEqual(bridge.LISTEN_ADDRESS, "127.0.0.1")
        self.assertEqual(bridge.PORT, 11435)
        sock = bridge.loopback_listener(port=0)
        try:
            self.assertEqual(sock.family, socket.AF_INET)
            self.assertEqual(sock.getsockname()[0], "127.0.0.1")
        finally:
            sock.close()
        # The default port is the bridge's, never a wildcard address.
        with open(os.path.join(support.ROOT, "nido_guest_tools", "bridge.py")) as f:
            source = f.read()
        self.assertNotIn("0.0.0.0", source)
        self.assertNotIn('"::"', source)
        self.assertNotIn("INADDR_ANY", source)
        # The unit denies every IP peer but localhost.
        with open(UNIT) as f:
            unit = f.read()
        for line in ("DynamicUser=yes", "ProtectSystem=strict", "ProtectHome=yes",
                     "NoNewPrivileges=yes", "Restart=on-failure", "IPAddressDeny=any",
                     "IPAddressAllow=localhost",
                     "ExecStart=/usr/bin/python3 /opt/nido-guest-tools/bin/nido-ai-bridge"):
            self.assertIn(line + "\n", unit)
        self.assertTrue(unit.startswith("# SPDX-License-Identifier: Apache-2.0\n"))

    def test_both_units_are_sandboxed(self):
        # No capabilities, no devices, no kernel knobs, no namespaces, no W+X memory, only the
        # address families each service needs (the monitor never speaks IP).
        sandbox = ("PrivateTmp=yes", "PrivateDevices=yes", "ProtectKernelTunables=yes",
                   "ProtectKernelModules=yes", "ProtectKernelLogs=yes", "ProtectControlGroups=yes",
                   "ProtectClock=yes", "RestrictNamespaces=yes",
                   "RestrictRealtime=yes", "RestrictSUIDSGID=yes", "LockPersonality=yes",
                   "MemoryDenyWriteExecute=yes", "SystemCallArchitectures=native", "CapabilityBoundingSet=")
        families = {"nido-ai-bridge.service": "AF_UNIX AF_INET AF_VSOCK",
                    "nido-guest-tools.service": "AF_UNIX AF_VSOCK"}
        for name, allowed in families.items():
            with open(os.path.join(support.ROOT, "systemd", name)) as f:
                unit = f.read()
            for line in sandbox + ("RestrictAddressFamilies=" + allowed,):
                self.assertIn(line + "\n", unit, name)
        # The monitor reports the hostname: it must see a change made after it started (its own
        # UTS namespace would keep the old one).
        with open(os.path.join(support.ROOT, "systemd", "nido-guest-tools.service")) as f:
            self.assertNotIn("ProtectHostname", f.read())

    def test_vsock_target_is_host_cid_2_port_7701(self):
        self.assertEqual(bridge.HOST_CID, 2)
        self.assertEqual(bridge.VSOCK_PORT, 7701)
        calls = []

        class FakeSocket:
            def __init__(self, family, kind):
                calls.append(("socket", family, kind))

            def settimeout(self, t):
                pass

            def connect(self, addr):
                calls.append(("connect", addr))

        fake = type("S", (), {"AF_VSOCK": 40, "SOCK_STREAM": 1, "socket": FakeSocket})
        bridge.vsock_connect(module=fake)
        self.assertEqual(calls, [("socket", 40, 1), ("connect", (2, 7701))])

    def test_vsock_missing_raises_oserror(self):
        fake = type("S", (), {"SOCK_STREAM": 1})
        with self.assertRaises(OSError):
            bridge.vsock_connect(module=fake)

    def test_forwards_both_directions(self):
        hosts = queue.Queue()

        def connect():
            guest_side, host_side = socket.socketpair()
            hosts.put(host_side)
            return guest_side

        b = Bridge(connect)
        try:
            client = b.client()
            request = b"POST /v1/chat/completions HTTP/1.1\r\n\r\n" + b"x" * 200000
            sender = threading.Thread(target=lambda: (client.sendall(request),
                                                      client.shutdown(socket.SHUT_WR)))
            sender.start()
            host = hosts.get(timeout=5)
            # Half-close: the host sees the end of the request, then still answers.
            self.assertEqual(read_all(host), request)
            answer = b"HTTP/1.1 200 OK\r\n\r\n" + b"y" * 300000
            received = []
            reader = threading.Thread(target=lambda: received.append(read_all(client)))
            reader.start()
            host.sendall(answer)
            host.close()
            reader.join(5)
            self.assertEqual(received, [answer])
            sender.join(5)
            client.close()
        finally:
            b.stop()

    def test_forward_ends_when_host_closes_and_client_stays_open(self):
        # A pooled client keeps its socket open after the answer: once the Mac has closed its
        # side, forward() must still return (and free the slot) without waiting for the client.
        client, client_srv = socket.socketpair()
        upstream, host = socket.socketpair()
        done = threading.Event()
        threading.Thread(target=lambda: (bridge.forward(client_srv, upstream), done.set()),
                         daemon=True).start()
        client.sendall(b"GET /v1/models HTTP/1.1\r\n\r\n")
        host.settimeout(5)
        self.assertEqual(host.recv(1024), b"GET /v1/models HTTP/1.1\r\n\r\n")
        host.sendall(b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n{}")
        host.close()
        try:
            self.assertTrue(done.wait(5), "forward() still blocked on the open client")
            self.assertEqual(read_all(client), b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n{}")
        finally:
            client.close()

    def test_pooled_clients_do_not_hold_the_slots(self):
        hosts = queue.Queue()

        def connect():
            guest_side, host_side = socket.socketpair()
            hosts.put(host_side)
            return guest_side

        b = Bridge(connect, max_connections=1)
        kept = []
        try:
            for _ in range(3):
                # The slot comes back although every earlier client is still open.
                deadline = time.monotonic() + 5
                attempts = {}
                while True:
                    tag = b"ping%04d" % len(kept)
                    client = b.client()
                    kept.append(client)  # never closed by the client until the end
                    attempts[tag] = client
                    client.sendall(tag)
                    try:
                        host = hosts.get(timeout=0.2)
                        break
                    except queue.Empty:
                        self.assertLess(time.monotonic(), deadline, "slot still held")
                host.settimeout(5)
                client = attempts[host.recv(8)]  # the attempt that got the slot
                host.sendall(b"pong")
                host.close()
                self.assertEqual(read_all(client), b"pong")
        finally:
            for s in kept:
                s.close()
            b.stop()

    def test_vsock_unavailable_returns_502(self):
        def connect():
            raise OSError(errno.ECONNRESET, "Connection reset by peer")

        b = Bridge(connect)
        try:
            client = b.client()
            client.sendall(b"GET /v1/models HTTP/1.1\r\nHost: x\r\n\r\n")
            data = read_all(client)
            client.close()
        finally:
            b.stop()
        head, body = data.split(b"\r\n\r\n", 1)
        self.assertTrue(head.startswith(b"HTTP/1.1 502 "), head)
        self.assertIn(b"Content-Type: application/json", head)
        self.assertIn(b"Content-Length: %d" % len(body), head)
        self.assertEqual(json.loads(body), {"error": {
            "message": "Nido AI bridge not available for this VM",
            "type": "bridge_unavailable", "code": "bridge_unavailable"}})
        self.assertIn("vsock", b.err.getvalue())

    def test_connection_cap(self):
        hosts = queue.Queue()

        def connect():
            guest_side, host_side = socket.socketpair()
            hosts.put(host_side)
            return guest_side

        b = Bridge(connect)
        try:
            held = [b.client() for _ in range(bridge.MAX_CONNECTIONS)]
            host_ends = [hosts.get(timeout=5) for _ in held]
            extra = b.client()
            data = read_all(extra)
            extra.close()
            head, body = data.split(b"\r\n\r\n", 1)
            self.assertTrue(head.startswith(b"HTTP/1.1 503 "), head)
            self.assertEqual(json.loads(body)["error"]["code"], "too_many_connections")
            self.assertTrue(hosts.empty())  # never forwarded
            # One ends: a new connection is forwarded again.
            held[0].close()
            host_ends[0].close()
            deadline = time.monotonic() + 5
            while True:
                again = b.client()
                again.sendall(b"ping")
                try:
                    host = hosts.get(timeout=0.2)
                    break
                except queue.Empty:
                    again.close()
                    self.assertLess(time.monotonic(), deadline)
            self.assertEqual(host.recv(4), b"ping")
            again.close()
            host.close()
            for s in held[1:] + host_ends[1:]:
                s.close()
        finally:
            b.stop()

    def test_main_exits_non_zero_when_serve_returns(self):
        orig = bridge.serve
        bridge.serve = lambda *a, **k: None
        try:
            with self.assertRaises(SystemExit) as ctx:
                bridge.main()
            self.assertNotEqual(ctx.exception.code, 0)
        finally:
            bridge.serve = orig

    def test_transient_accept_error_is_retried(self):
        class Flaky(QueueListener):
            def __init__(self):
                super().__init__()
                self.failed = False

            def accept(self):
                if not self.failed:
                    self.failed = True
                    raise OSError(errno.EMFILE, "too many files")
                return super().accept()

        listener = Flaky()

        def connect():
            raise OSError(errno.ECONNREFUSED, "refused")

        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            t = threading.Thread(target=bridge.serve, kwargs=dict(
                listener=listener, connect=connect, backoff=0.01), daemon=True)
            t.start()
            client, srv = socket.socketpair()
            listener.add(srv)
            data = read_all(client)
            client.close()
            listener.close()
            t.join(5)
        self.assertTrue(data.startswith(b"HTTP/1.1 502 "))
        self.assertIn("accept failed", err.getvalue())


if __name__ == "__main__":
    unittest.main()
