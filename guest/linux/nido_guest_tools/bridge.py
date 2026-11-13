# SPDX-License-Identifier: Apache-2.0
"""Nido AI bridge shim: listens on the guest's loopback only (127.0.0.1:11435) and copies each
connection byte for byte to the Mac over vsock (CID 2, port 7701), where Nido's proxy answers.
No token and no configuration live in the guest: the Mac decides everything."""

import errno
import json
import socket
import sys
import threading
import time

LISTEN_ADDRESS = "127.0.0.1"
PORT = 11435
HOST_CID = 2  # VMADDR_CID_HOST
VSOCK_PORT = 7701
MAX_CONNECTIONS = 4
CONNECT_TIMEOUT = 5.0
# How long a refused connection is drained before closing it (no RST over the answer).
REFUSAL_DRAIN = 0.5
CHUNK = 65536

CLOSED_ERRNOS = (errno.EBADF, errno.EINVAL, errno.ENOTSOCK)
ACCEPT_BACKOFF = 0.5

UNAVAILABLE = {"error": {
    "message": "Nido AI bridge not available for this VM",
    "type": "bridge_unavailable", "code": "bridge_unavailable"}}
BUSY = {"error": {
    "message": "Too many connections to the Nido AI bridge",
    "type": "rate_limit_error", "code": "too_many_connections"}}


def log(message):
    """One line to stderr (the systemd journal)."""
    try:
        print("nido-ai-bridge: " + message, file=sys.stderr, flush=True)
    except (OSError, ValueError):
        pass


def loopback_listener(port=PORT):
    """A TCP listener on 127.0.0.1 only."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((LISTEN_ADDRESS, port))
        sock.listen(16)
    except OSError:
        sock.close()
        raise
    return sock


def vsock_connect(module=socket, timeout=CONNECT_TIMEOUT):
    """A stream connected to the Mac's bridge port. OSError when vsock is missing or nobody
    listens (a VM started with `nido start`)."""
    if not hasattr(module, "AF_VSOCK"):
        raise OSError(errno.EAFNOSUPPORT, "AF_VSOCK not available on this system")
    sock = module.socket(module.AF_VSOCK, module.SOCK_STREAM)
    try:
        sock.settimeout(timeout)
        sock.connect((HOST_CID, VSOCK_PORT))
        sock.settimeout(None)
    except BaseException:
        try:
            sock.close()
        except (OSError, AttributeError):
            pass
        raise
    return sock


def _response(code, reason, document):
    body = json.dumps(document).encode("utf-8")
    head = (
        "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\n"
        "Content-Length: %d\r\nConnection: close\r\n\r\n" % (code, reason, len(body))
    )
    return head.encode("ascii") + body


def refuse(conn, code, reason, document, drain=REFUSAL_DRAIN):
    """Answers with an error, ends the stream and discards what the client still sends for a
    short while, so closing does not reset the connection over the answer."""
    try:
        conn.settimeout(drain)
        conn.sendall(_response(code, reason, document))
        conn.shutdown(socket.SHUT_WR)
        deadline = time.monotonic() + drain
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            conn.settimeout(remaining)
            if not conn.recv(CHUNK):
                break
    except OSError:
        pass
    finally:
        _close(conn)


def _close(sock):
    try:
        sock.close()
    except OSError:
        pass


def _shutdown(sock, how):
    try:
        sock.shutdown(how)
    except OSError:
        pass


def _pump(src, dst):
    """Copies src to dst until src ends, then half-closes dst. On an error both directions stop."""
    try:
        while True:
            data = src.recv(CHUNK)
            if not data:
                break
            dst.sendall(data)
        _shutdown(dst, socket.SHUT_WR)
    except OSError:
        _shutdown(src, socket.SHUT_RDWR)
        _shutdown(dst, socket.SHUT_RDWR)


def _pump_back(upstream, client):
    """Mac to guest client. The Mac answers one request per connection (`Connection: close`):
    once it has ended, the client's read side is shut too, so the other pump returns at once
    instead of waiting for a client that keeps its socket open (a pooled connection), which
    would hold a slot."""
    _pump(upstream, client)
    _shutdown(client, socket.SHUT_RD)


def forward(client, upstream):
    """Copies both directions until both have ended, then closes both."""
    back = threading.Thread(target=_pump_back, args=(upstream, client), daemon=True)
    back.start()
    _pump(client, upstream)
    back.join()
    _close(upstream)
    _close(client)


def handle(client, connect, slots):
    """One guest connection: forwarded to the Mac, or 502 when the Mac does not answer."""
    try:
        try:
            upstream = connect()
        except OSError as exc:
            log("vsock connect to the Mac failed: %s" % exc)
            refuse(client, 502, "Bad Gateway", UNAVAILABLE)
            return
        forward(client, upstream)
    finally:
        slots.release()


def serve(listener=None, connect=None, max_connections=MAX_CONNECTIONS, backoff=ACCEPT_BACKOFF):
    """Accepts connections, at most `max_connections` forwarded at once (the next ones get 503).
    Transient accept errors are logged and retried after a short backoff; returns only when the
    listener is closed."""
    if listener is None:
        listener = loopback_listener()
    if connect is None:
        connect = vsock_connect
    slots = threading.BoundedSemaphore(max_connections)
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
        if not slots.acquire(blocking=False):
            refuse(conn, 503, "Service Unavailable", BUSY)
            continue
        try:
            threading.Thread(target=handle, args=(conn, connect, slots), daemon=True).start()
        except RuntimeError as exc:
            log("cannot start a connection thread: %s" % exc)
            slots.release()
            _close(conn)


def main():
    serve()
    # serve() only returns when the listener is closed: exit non-zero so
    # systemd (Restart=on-failure) restarts the service.
    sys.exit(1)
