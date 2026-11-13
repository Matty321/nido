# SPDX-License-Identifier: Apache-2.0
"""nido-provision: phase 2 of the guest provisioning (Ollama and its models).

Run as root (sudo -n) by Nido over SSH, never by cloud-init. The guest never downloads Ollama:
Nido downloads the pinned archive on the Mac, checks it there, and sends it on stdin of
`ollama-install --archive-stdin` (or `ollama-update --archive-stdin`); the guest checks its size
and SHA-256 against release.json again before using it. Every step is idempotent (already
done: `done` without work) and can be re-run after an interruption ("Try Again"). The state lives
in /var/lib/nido-provision/state.json (0644, no secrets, written atomically) so the Guest Tools
monitor can read it; the log in /var/log/nido-provision.log.

Exit codes: 0 done, 1 step failed (one line "nido-provision: <code>: <message>" on stderr, see
MESSAGES), 2 usage error ("usage: nido-provision …"), 3 another step is running. Messages, the
state and the log are English: Nido shows its own text for each code, in the Mac's language.
"""

import errno
import fcntl
import hashlib
import http.client
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

GiB = 1 << 30
DISK_MARGIN = 2 * GiB
MEMORY_FACTOR = 1.2
CHUNK = 1 << 20
SYNC_EVERY = 64 << 20
PROGRESS_INTERVAL = 1.0
SERVICE_WAIT = 60
LOG_LIMIT = 1 << 20
LOG_TAIL = 64 << 10
OLLAMA_API = "http://127.0.0.1:11434"
UNIT = "ollama.service"
USER = "ollama"
DOWNLOAD_PREFIX = "https://github.com/ollama/ollama/releases/download/"
MANIFEST = ".nido-manifest.json"
MODEL_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/-]*")
LOCK_WAIT = 2.0
BOOT_ID = "/proc/sys/kernel/random/boot_id"
ARCHIVE_FLAG = "--archive-stdin"
NETWORK_ERRORS = (OSError, http.client.HTTPException)

STEPS = (
    "ollama-install", "ollama-verify", "ollama-start", "ollama-stop", "ollama-restart",
    "ollama-update", "ollama-uninstall", "model-pull", "model-remove",
)
USAGE = (
    "usage: nido-provision ollama-install [--archive-stdin]|ollama-verify|ollama-start|ollama-stop|ollama-restart|"
    "ollama-update [--archive-stdin]|ollama-uninstall [--keep-models|--remove-models]|model-pull <id> [--force]|"
    "model-remove <id>|status|log"
)

# What a step tells Nido when it fails, or warns: "<code>: <message>". A failed step prints
# "nido-provision: <code>: <message>" on stderr; the memory warning of model-pull is stored as
# "<code>: <message>" in the step's `warning`. The code is stable: Nido (GuestMessage.swift)
# shows its own text for each code it knows, in the Mac's language, and anything else as it
# arrives. Never rename or reuse a code; a new message gets a new code (and its text in Nido,
# whose tests read this table). The English message (the log, the Terminal) is Nido's English
# text with the values in place of %s, in the same order: Nido reads the values back from it.
MESSAGES = {
    # code: English message
    "release_invalid": "the Guest Tools’ release.json isn’t valid (%s)",
    "architecture_unsupported": "unsupported architecture (%s): aarch64 required",
    "ollama_foreign": "Ollama wasn’t installed by Nido: manage it yourself",
    "ollama_link_foreign": "/usr/local/bin/ollama already holds an Ollama that Nido didn’t install: remove it or use that one",
    "ollama_not_installed": "Ollama isn’t installed",
    "ollama_not_running": "Ollama isn’t running: start it or install it",
    "ollama_files_damaged": "the files of Ollama %s are incomplete or damaged: install it again with Try Again",
    "ollama_not_responding": "Ollama isn’t responding on 127.0.0.1:11434",
    "service_inactive": "the ollama service isn’t active",
    "service_stop_failed": "the ollama service didn’t stop",
    "disk_space_low": "not enough disk space: %s needed, %s free",
    "usr_local_space_low": "not enough disk space in /usr/local: %s needed, %s free",
    "archive_from_mac_required": "the Ollama archive comes from the Mac: install Ollama from the Nido app or update Nido",
    "archive_receive_interrupted": "the Ollama transfer was interrupted (%s): click Try Again",
    "archive_incomplete": "the Ollama archive is incomplete: click Try Again",
    "archive_checksum_mismatch": "the Ollama archive’s checksum doesn’t match: file discarded, click Try Again",
    "archive_extract_failed": "couldn’t extract the Ollama archive: %s",
    "archive_wrong_version": "the Ollama archive doesn’t contain version %s",
    "user_create_failed": "couldn’t create the user %s: %s",
    "pull_disk_space_low": "not enough disk space: only %s free",
    "model_disk_space_low": "not enough disk space for the model: %s needed, %s free",
    "model_pull_failed": "Ollama reported an error: %s",
    "model_pull_interrupted": "the model download was interrupted: click Try Again",
    "model_missing_after_pull": "the model %s is missing after the download",
    "model_remove_failed": "the model %s wasn’t removed",
    "model_memory_low": "the VM has %s of RAM and the model takes %s: it may be slow or fail to start",
    "interrupted": "interrupted: click Try Again",
    "unexpected_error": "unexpected error (%s: %s)",
    "busy": "another step is running, try again shortly",
}

# The longest a value of a message gets (one line, cut with "…"): with every value this long, a
# message still fits the 300 characters of fail(), so it keeps its template's shape.
VALUE_LIMIT = 100

# A `running` step whose process is gone (state.json only; the Guest Tools monitor writes the same).
INTERRUPTED = "interrupted (the VM was stopped or the command was interrupted): click Try Again"


def _message(code, values):
    """MESSAGES[code] with `values` on one line, each cut to VALUE_LIMIT; TypeError when the
    values do not fit the code."""
    cut = []
    for value in values:
        value = one_line(value, VALUE_LIMIT + 1)
        cut.append(value if len(value) <= VALUE_LIMIT else value[:VALUE_LIMIT - 1] + "…")
    return MESSAGES[code] % tuple(cut)


def coded(code, *values):
    """"<code>: <message>" for a code of MESSAGES; TypeError when the values do not fit it."""
    return "%s: %s" % (code, _message(code, values))


class StepFailed(Exception):
    """A step cannot complete: `code` (MESSAGES) and its English `message`."""

    def __init__(self, code, *values):
        self.code = code
        self.message = _message(code, values)
        super().__init__(self.message)


class Interrupted(Exception):
    pass


class Paths:
    """Every path the provisioner touches, under `root` (\"/\" in the guest, a temp dir in tests)."""

    def __init__(self, root="/"):
        def j(path):
            return os.path.join(root, path.lstrip("/"))
        self.root = root
        self.state_dir = j("/var/lib/nido-provision")
        self.state = j("/var/lib/nido-provision/state.json")
        self.lock = j("/var/lib/nido-provision/lock")
        self.tmp = j("/var/lib/nido-provision/tmp")
        self.log = j("/var/log/nido-provision.log")
        self.release = j("/opt/nido-guest-tools/ollama/release.json")
        self.unit_source = j("/opt/nido-guest-tools/ollama/ollama.service")
        self.unit = j("/etc/systemd/system/ollama.service")
        self.lib = j("/usr/local/lib/nido-ollama")
        self.link = j("/usr/local/bin/ollama")
        self.home = j("/usr/share/ollama")
        self.models = j("/usr/share/ollama/.ollama/models")


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def one_line(text, limit=200):
    """`text` with control characters turned into spaces, on one line, at most `limit` chars."""
    out = "".join(" " if (ord(c) < 0x20 or 0x7F <= ord(c) < 0xA0) else c for c in str(text))
    return " ".join(out.split())[:limit]


def human(n):
    return "%.1f GiB" % (n / GiB) if n >= GiB else "%d MiB" % (n // (1 << 20))


def valid_model(name):
    return (isinstance(name, str) and len(name.encode("utf-8")) <= 128
            and MODEL_RE.fullmatch(name) is not None)


def model_key(name):
    """`llama3.2` and `llama3.2:latest` are the same model."""
    last = name.rsplit("/", 1)[-1]
    return name if ":" in last else name + ":latest"


# ------------------------------------------------------------------------------------------
# System access (replaced by a fake in the tests)


class System:
    """The real guest."""

    def machine(self):
        return os.uname().machine

    def free_bytes(self, path):
        while not os.path.exists(path):
            path = os.path.dirname(path)
        st = os.statvfs(path)
        return st.f_bavail * st.f_frsize

    def mem_total(self):
        with open("/proc/meminfo", encoding="utf-8") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    return int(line.split()[1]) * 1024
        return 0

    def sleep(self, seconds):
        time.sleep(seconds)

    def sync(self):
        os.sync()

    def boot_id(self):
        try:
            with open(BOOT_ID, encoding="ascii") as f:
                return f.read().strip()
        except OSError:
            return None

    def archive_input(self):
        """The Ollama archive Nido sends from the Mac (binary stdin)."""
        return sys.stdin.buffer

    def run(self, argv, timeout=60):
        proc = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=timeout)
        return proc.returncode, proc.stdout.decode("utf-8", "replace")

    def extract(self, archive, dest):
        code, out = self.run(["tar", "--zstd", "-x", "--no-same-owner", "-f", archive, "-C", dest],
                             timeout=3600)
        if code != 0:
            raise StepFailed("archive_extract_failed", out.strip()[-200:])

    def systemctl(self, *args):
        return subprocess.run(["systemctl"] + list(args), stdin=subprocess.DEVNULL,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=120).returncode

    def user_exists(self, name):
        import pwd
        try:
            pwd.getpwnam(name)
            return True
        except KeyError:
            return False

    def add_system_user(self, name, home):
        # Like Ollama's official installer: a system user with its own group and home.
        code, out = self.run(["useradd", "-r", "-s", "/bin/false", "-U", "-m", "-d", home, name])
        if code != 0:
            raise StepFailed("user_create_failed", name, out.strip()[-200:])

    def remove_user(self, name):
        self.run(["userdel", name])

    def _local_opener(self):
        # The local API is never reached through a proxy.
        return urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def _local_request(self, method, path, body):
        data = None if body is None else json.dumps(body).encode("utf-8")
        req = urllib.request.Request(OLLAMA_API + path, data=data, method=method)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        return req

    def api(self, method, path, body=None, timeout=10):
        with self._local_opener().open(self._local_request(method, path, body), timeout=timeout) as r:
            text = r.read(16 << 20)
        return json.loads(text) if text.strip() else {}

    def api_stream(self, method, path, body, timeout=60):
        try:
            resp = self._local_opener().open(self._local_request(method, path, body), timeout=timeout)
        except urllib.error.HTTPError as exc:
            # Ollama answers errors as {"error": "..."} with a 4xx/5xx status.
            text = exc.read(65536)
            try:
                yield json.loads(text)
            except ValueError:
                yield {"error": "HTTP %d" % exc.code}
            return
        with resp:
            for line in resp:
                line = line.strip()
                if line:
                    yield json.loads(line)


# ------------------------------------------------------------------------------------------
# State and log


class State:
    """state.json: {"version": 1, "steps": {name: {"state", "message", "updated", ...}}}."""

    def __init__(self, paths, boot_id=None):
        self.paths = paths
        # A `running` entry records the boot and the process that runs it, so a reader (the
        # Guest Tools monitor) can tell an entry left behind by a reboot or a killed process.
        self.boot_id = boot_id

    def load(self):
        try:
            with open(self.paths.state, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            data = None
        if not isinstance(data, dict) or not isinstance(data.get("steps"), dict):
            data = {"version": 1, "steps": {}}
        data["version"] = 1
        return data

    def save(self, data):
        os.makedirs(self.paths.state_dir, exist_ok=True)
        os.chmod(self.paths.state_dir, 0o755)
        tmp = os.path.join(self.paths.state_dir, ".state.%d.tmp" % os.getpid())
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, self.paths.state)

    def set(self, name, state, message, **extra):
        data = self.load()
        entry = {"state": state, "message": message, "updated": now_iso()}
        if state == "running":
            entry["pid"] = os.getpid()
            if self.boot_id:
                entry["boot_id"] = self.boot_id
        entry.update({k: v for k, v in extra.items() if v is not None})
        data["steps"][name] = entry
        self.save(data)
        return entry

    def update(self, name, **fields):
        data = self.load()
        entry = data["steps"].setdefault(name, {"state": "running", "message": ""})
        entry.update({k: v for k, v in fields.items() if v is not None})
        entry["updated"] = now_iso()
        self.save(data)

    def drop(self, names):
        data = self.load()
        for name in names:
            data["steps"].pop(name, None)
        self.save(data)

    def mark_interrupted(self):
        """Called while holding the lock: a step still `running` belongs to a dead process."""
        data = self.load()
        changed = False
        for entry in data["steps"].values():
            if isinstance(entry, dict) and entry.get("state") == "running":
                entry["state"] = "failed"
                entry["message"] = INTERRUPTED
                entry["updated"] = now_iso()
                changed = True
        if changed:
            self.save(data)
        return data


class Log:
    def __init__(self, paths):
        self.paths = paths

    def write(self, message):
        try:
            os.makedirs(os.path.dirname(self.paths.log), exist_ok=True)
            try:
                if os.path.getsize(self.paths.log) > LOG_LIMIT:
                    with open(self.paths.log, "rb") as f:
                        f.seek(-LOG_LIMIT // 2, os.SEEK_END)
                        keep = f.read()
                    with open(self.paths.log, "wb") as f:
                        f.write(keep)
            except OSError:
                pass
            fd = os.open(self.paths.log, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o640)
            with os.fdopen(fd, "a", encoding="utf-8") as f:
                f.write("%s %s\n" % (now_iso(), message))
        except OSError:
            pass

    def tail(self):
        try:
            with open(self.paths.log, "rb") as f:
                f.seek(0, os.SEEK_END)
                f.seek(max(0, f.tell() - LOG_TAIL))
                return f.read().decode("utf-8", "replace")
        except OSError:
            return ""


# ------------------------------------------------------------------------------------------
# Steps


class Provisioner:
    def __init__(self, paths, system):
        self.paths = paths
        self.sys = system
        # True when Nido sends the archive on stdin (`--archive-stdin`).
        self.archive_on_stdin = False
        self.state = State(paths, boot_id=system.boot_id())
        self.log = Log(paths)
        self.step = None
        self._last_progress = 0.0

    # --- helpers -------------------------------------------------------------------------

    def progress(self, message, **extra):
        self.log.write("%s: %s" % (self.step, message))
        self.state.set(self.step, "running", message, **extra)

    def release(self):
        try:
            with open(self.paths.release, encoding="utf-8") as f:
                rel = json.load(f)
            for key in ("version", "url", "file", "size", "sha256"):
                if key not in rel:
                    raise ValueError(key)
        except (OSError, ValueError) as exc:
            raise StepFailed("release_invalid", exc)
        if not rel["url"].startswith(DOWNLOAD_PREFIX) or "/" in rel["file"]:
            raise StepFailed("release_invalid", "url")
        return rel

    def version_dir(self, version):
        return os.path.join(self.paths.lib, version)

    def managed_target(self):
        """The binary our symlink points to, None when nothing is installed; StepFailed when
        /usr/local/bin/ollama exists and is not ours."""
        link = self.paths.link
        if not os.path.lexists(link):
            return None
        if os.path.islink(link):
            target = os.readlink(link)
            if os.path.dirname(os.path.dirname(os.path.dirname(target))) == self.paths.lib:
                return target
        raise StepFailed("ollama_link_foreign")

    def binary_version(self, binary):
        if not os.path.isfile(binary):
            return None
        try:
            code, out = self.sys.run([binary, "--version"], timeout=60)
        except (OSError, subprocess.SubprocessError):
            return None
        match = re.search(r"version is (\S+)", out)
        return match.group(1) if match else None

    def installed_version(self):
        try:
            target = self.managed_target()
        except StepFailed:
            return None
        if not target or not self.tree_ok(os.path.dirname(os.path.dirname(target))):
            return None
        return self.binary_version(target)

    @staticmethod
    def write_manifest(tree):
        """Records every regular file of `tree` with its size."""
        files = {}
        for base, _, names in os.walk(tree):
            for name in names:
                path = os.path.join(base, name)
                if os.path.isfile(path) and not os.path.islink(path):
                    files[os.path.relpath(path, tree)] = os.path.getsize(path)
        with open(os.path.join(tree, MANIFEST), "w", encoding="utf-8") as f:
            json.dump({"files": files}, f, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())

    @staticmethod
    def tree_ok(tree):
        """True when every file of the manifest is there with its size: a tree damaged by a
        crash (empty or missing files) counts as not installed."""
        try:
            with open(os.path.join(tree, MANIFEST), encoding="utf-8") as f:
                files = json.load(f)["files"]
            return all(os.path.getsize(os.path.join(tree, rel)) == size
                       for rel, size in files.items())
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            return False

    def service_active(self):
        return self.sys.systemctl("is-active", "--quiet", UNIT) == 0

    def api_version(self):
        try:
            return self.sys.api("GET", "/api/version", timeout=5).get("version")
        except NETWORK_ERRORS + (ValueError, AttributeError):
            return None

    def models(self):
        """[(name, size)] from /api/tags; None when Ollama does not answer."""
        try:
            tags = self.sys.api("GET", "/api/tags", timeout=10)
        except NETWORK_ERRORS + (ValueError,):
            return None
        listed = tags.get("models") if isinstance(tags, dict) else None
        out = []
        for m in listed if isinstance(listed, list) else []:
            if isinstance(m, dict) and isinstance(m.get("name"), str):
                size = m.get("size")
                out.append((m["name"], size if isinstance(size, int) else 0))
        return out

    def check(self, version):
        """None when the service is active, `ollama --version` and the API report `version`;
        otherwise what is wrong, as a StepFailed to raise. Waits for a starting service up to
        SERVICE_WAIT seconds."""
        if self.installed_version() != version:
            return StepFailed("ollama_files_damaged", version)
        deadline = time.monotonic() + SERVICE_WAIT
        attempts = 0
        while True:
            attempts += 1
            if self.service_active() and self.api_version() == version:
                return None
            if time.monotonic() >= deadline or attempts > SERVICE_WAIT:
                break
            self.sys.sleep(1)
        if not self.service_active():
            return StepFailed("service_inactive")
        return StepFailed("ollama_not_responding")

    def require_installed(self):
        version = self.installed_version()
        if version is None:
            raise StepFailed("ollama_not_installed")
        return version

    def require_api(self):
        if self.api_version() is None:
            raise StepFailed("ollama_not_running")

    # --- install -------------------------------------------------------------------------

    def clean_tmp(self, keep=None):
        if not os.path.isdir(self.paths.tmp):
            return
        for name in os.listdir(self.paths.tmp):
            if name == keep:
                continue
            path = os.path.join(self.paths.tmp, name)
            if os.path.isdir(path) and not os.path.islink(path):
                shutil.rmtree(path, ignore_errors=True)
            else:
                try:
                    os.remove(path)
                except OSError:
                    pass

    def check_disk(self, rel, have):
        estimate = int(rel.get("extracted_size_estimate") or 3 * rel["size"])
        need = (rel["size"] - have) + estimate + DISK_MARGIN
        free = self.sys.free_bytes(self.paths.tmp)
        if free < need:
            raise StepFailed("disk_space_low", human(need), human(free))
        lib_parent = os.path.dirname(self.paths.lib)
        if self._device(lib_parent) != self._device(self.paths.tmp):
            need = estimate + DISK_MARGIN
            free = self.sys.free_bytes(lib_parent)
            if free < need:
                raise StepFailed("usr_local_space_low", human(need), human(free))

    @staticmethod
    def _device(path):
        while not os.path.exists(path):
            path = os.path.dirname(path)
        return os.stat(path).st_dev

    def receive(self, rel):
        """The verified archive in tmp/<file>.part: one already complete there (an install
        interrupted before the link), otherwise the bytes Nido sends on stdin. Never the network."""
        part = os.path.join(self.paths.tmp, rel["file"] + ".part")
        total = rel["size"]
        have = os.path.getsize(part) if os.path.exists(part) else 0
        if have != total:
            if not self.archive_on_stdin:
                raise StepFailed("archive_from_mac_required")
            self.check_disk(rel, 0)
            self.progress("Receiving Ollama %s from the Mac" % rel["version"],
                          progress={"completed": 0, "total": total})
            self._copy(self.sys.archive_input(), part, total)
        self.progress("Checking integrity (SHA-256)", progress={"completed": total, "total": total})
        if os.path.getsize(part) != total or self._sha256(part) != rel["sha256"].lower():
            os.remove(part)
            raise StepFailed("archive_checksum_mismatch")
        return part

    def _copy(self, source, part, total):
        """Writes exactly `total` bytes of `source` into `part` (0600, replaced); an incomplete
        transfer removes it and fails."""
        os.makedirs(self.paths.tmp, exist_ok=True)
        have = synced = 0
        fd = os.open(part, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        try:
            with os.fdopen(fd, "wb") as out:
                while have < total:
                    chunk = source.read(min(CHUNK, total - have))
                    if not chunk:
                        break
                    out.write(chunk)
                    have += len(chunk)
                    if have - synced >= SYNC_EVERY:
                        out.flush()
                        os.fsync(out.fileno())
                        synced = have
                    self._report(have, total)
                out.flush()
                os.fsync(out.fileno())
        except OSError as exc:
            os.remove(part)
            raise StepFailed("archive_receive_interrupted", exc)
        if have < total:
            os.remove(part)
            raise StepFailed("archive_incomplete")

    def _report(self, completed, total, **extra):
        now = time.monotonic()
        if now - self._last_progress >= PROGRESS_INTERVAL or completed >= total:
            self._last_progress = now
            self.state.update(self.step, progress={"completed": completed, "total": total}, **extra)

    @staticmethod
    def _sha256(path):
        digest = hashlib.sha256()
        with open(path, "rb") as f:
            for block in iter(lambda: f.read(CHUNK), b""):
                digest.update(block)
        return digest.hexdigest()

    def place(self, rel, archive):
        """Extracts into a staging dir under tmp, checks `bin/ollama --version` there, then moves
        the whole tree into /usr/local/lib/nido-ollama/<version> with one rename."""
        version = rel["version"]
        stage = os.path.join(self.paths.tmp, "stage-" + version)
        shutil.rmtree(stage, ignore_errors=True)
        os.makedirs(stage, 0o755)
        self.progress("Extracting Ollama %s" % version)
        self.sys.extract(archive, stage)
        if self.binary_version(os.path.join(stage, "bin", "ollama")) != version:
            shutil.rmtree(stage, ignore_errors=True)
            raise StepFailed("archive_wrong_version", version)
        self.write_manifest(stage)
        # The extracted files must be on disk before the rename publishes them: after a crash
        # the tree in /usr/local is either complete or absent, never made of empty files.
        self.sys.sync()
        dest = self.version_dir(version)
        os.makedirs(self.paths.lib, 0o755, exist_ok=True)
        if os.path.exists(dest):
            shutil.rmtree(dest)
        os.chmod(stage, 0o755)
        try:
            os.rename(stage, dest)
        except OSError as exc:
            if exc.errno != errno.EXDEV:
                raise
            # Another file system: copy next to the destination, then one rename there.
            incoming = os.path.join(self.paths.lib, ".incoming-" + version)
            shutil.rmtree(incoming, ignore_errors=True)
            shutil.copytree(stage, incoming, symlinks=True)
            self.sys.sync()
            os.rename(incoming, dest)
            shutil.rmtree(stage, ignore_errors=True)
        self.sys.sync()

    def link(self, version):
        target = os.path.join(self.version_dir(version), "bin", "ollama")
        os.makedirs(os.path.dirname(self.paths.link), exist_ok=True)
        tmp = os.path.join(os.path.dirname(self.paths.link), ".ollama.nido-tmp")
        if os.path.lexists(tmp):
            os.remove(tmp)
        os.symlink(target, tmp)
        os.replace(tmp, self.paths.link)
        self.sys.sync()

    def remove_other_versions(self, keep):
        if not os.path.isdir(self.paths.lib):
            return
        for name in os.listdir(self.paths.lib):
            if name != keep:
                shutil.rmtree(os.path.join(self.paths.lib, name), ignore_errors=True)

    def ensure_unit(self):
        """Installs the unit from the Guest Tools payload; True when it changed."""
        with open(self.paths.unit_source, "rb") as f:
            wanted = f.read()
        try:
            with open(self.paths.unit, "rb") as f:
                if f.read() == wanted:
                    return False
        except OSError:
            pass
        os.makedirs(os.path.dirname(self.paths.unit), exist_ok=True)
        tmp = self.paths.unit + ".nido-tmp"
        with open(tmp, "wb") as f:
            f.write(wanted)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, self.paths.unit)
        return True

    def ensure_ollama(self, rel):
        """Brings the guest to the pinned release; returns True when something changed."""
        version = rel["version"]
        current = self.installed_version()
        changed = False
        if current != version:
            dest_binary = os.path.join(self.version_dir(version), "bin", "ollama")
            if (not self.tree_ok(self.version_dir(version))
                    or self.binary_version(dest_binary) != version):
                self.clean_tmp(keep=rel["file"] + ".part")
                archive = self.receive(rel)
                self.place(rel, archive)
            self.link(version)
            changed = True
        # The verified archive goes only now: an interruption before the link must not cost a
        # second download.
        self.clean_tmp()
        self.remove_other_versions(version)
        if not self.sys.user_exists(USER):
            self.progress("Creating the user %s" % USER)
            self.sys.add_system_user(USER, self.paths.home)
            changed = True
        unit_changed = self.ensure_unit()
        if unit_changed:
            self.sys.systemctl("daemon-reload")
        if unit_changed or changed:
            self.progress("Starting the ollama service")
            self.sys.systemctl("enable", UNIT)
            self.sys.systemctl("restart", UNIT)
            changed = True
        elif self.sys.systemctl("is-enabled", "--quiet", UNIT) != 0 or not self.service_active():
            self.progress("Starting the ollama service")
            self.sys.systemctl("enable", "--now", UNIT)
            changed = True
        return changed

    def refuse_foreign(self):
        """StepFailed when an Ollama not installed by Nido is there: a foreign
        /usr/local/bin/ollama, or (without our link) a unit that is not ours. An empty unit is
        what a crash leaves of ours and is not foreign; a link (e.g. a unit masked to /dev/null)
        is never ours."""
        if self.managed_target() is not None:
            return
        if os.path.islink(self.paths.unit):
            raise StepFailed("ollama_foreign")
        try:
            with open(self.paths.unit, "rb") as f:
                current = f.read()
        except OSError:
            return
        with open(self.paths.unit_source, "rb") as f:
            ours = f.read()
        if current.strip() and current != ours:
            raise StepFailed("ollama_foreign")

    def preflight(self):
        if self.sys.machine() != "aarch64":
            raise StepFailed("architecture_unsupported", self.sys.machine())
        self.refuse_foreign()

    def do_install(self):
        rel = self.release()
        self.preflight()
        self.progress("Checks")
        changed = self.ensure_ollama(rel)
        self.progress("Verifying")
        problem = self.check(rel["version"])
        if problem:
            raise problem
        return ("Ollama %s installed and running" % rel["version"] if changed
                else "Ollama %s is already installed and running" % rel["version"])

    def do_update(self):
        rel = self.release()
        self.preflight()
        target = self.managed_target()
        if target is None:
            raise StepFailed("ollama_not_installed")
        # A damaged older tree is still something to update.
        current = self.binary_version(target) or "?"
        changed = self.ensure_ollama(rel)
        problem = self.check(rel["version"])
        if problem:
            raise problem
        if current == rel["version"] and not changed:
            return "Ollama is already at version %s" % current
        return "Ollama updated from %s to %s" % (current, rel["version"])

    def do_verify(self):
        version = self.require_installed()
        problem = self.check(version)
        if problem:
            raise problem
        return "Ollama %s works" % version

    def do_service(self, verb):
        version = self.require_installed()
        if verb == "stop":
            # Disabled as well: a stopped Ollama stays stopped after the guest reboots, until
            # "Start" (which enables it again).
            self.sys.systemctl("disable", "--now", UNIT)
            if self.service_active():
                raise StepFailed("service_stop_failed")
            return "Ollama stopped"
        self.sys.systemctl("enable", UNIT)
        self.sys.systemctl(verb, UNIT)
        problem = self.check(version)
        if problem:
            raise problem
        return "Ollama started" if verb == "start" else "Ollama restarted"

    def do_uninstall(self, remove_models):
        self.refuse_foreign()
        self.sys.systemctl("disable", "--now", UNIT)
        if os.path.exists(self.paths.unit):
            os.remove(self.paths.unit)
            self.sys.systemctl("daemon-reload")
        if os.path.lexists(self.paths.link):
            os.remove(self.paths.link)
        shutil.rmtree(self.paths.lib, ignore_errors=True)
        self.clean_tmp()
        dropped = ["ollama-install", "ollama-update", "ollama-verify", "ollama-start",
                   "ollama-stop", "ollama-restart"]
        if remove_models:
            shutil.rmtree(self.paths.home, ignore_errors=True)
            if self.sys.user_exists(USER):
                self.sys.remove_user(USER)
            dropped += ["model-pull", "model-remove"]
        self.state.drop(dropped)
        return ("Ollama uninstalled, models removed" if remove_models
                else "Ollama uninstalled, models kept")

    # --- models --------------------------------------------------------------------------

    def find_model(self, name):
        models = self.models()
        if models is None:
            raise StepFailed("ollama_not_running")
        key = model_key(name)
        for found, size in models:
            if model_key(found) == key:
                return found, size
        return None

    def memory_warning(self, size):
        """"model_memory_low: …" when the VM's RAM looks too small for a model of `size`."""
        mem = self.sys.mem_total()
        if size and mem < MEMORY_FACTOR * size:
            return coded("model_memory_low", human(mem), human(size))
        return None

    def do_pull(self, name, force):
        self.require_api()
        existing = self.find_model(name)
        if existing and not force:
            return "the model %s is already there" % name, {"model": name}
        free = self.sys.free_bytes(self.paths.models)
        if free < DISK_MARGIN:
            raise StepFailed("pull_disk_space_low", human(free))
        self.progress("Downloading the model %s" % name, model=name)
        layers = {}
        warning = None
        for event in self.sys.api_stream("POST", "/api/pull", {"model": name, "stream": True},
                                         timeout=120):
            if not isinstance(event, dict):
                continue
            if event.get("error"):
                raise StepFailed("model_pull_failed", str(event["error"])[:300])
            digest, total = event.get("digest"), event.get("total")
            if isinstance(digest, str) and isinstance(total, int):
                new = digest not in layers
                layers[digest] = (int(event.get("completed") or 0), total)
                size = sum(t for _, t in layers.values())
                done = sum(c for c, _ in layers.values())
                if new:
                    warning = self.memory_warning(size) or warning
                    remaining = size - done
                    free = self.sys.free_bytes(self.paths.models)
                    if free < remaining + DISK_MARGIN:
                        raise StepFailed("model_disk_space_low", human(remaining + DISK_MARGIN),
                                         human(free))
                self._report(done, size, warning=warning, message=str(event.get("status", ""))[:120])
            if event.get("status") == "success":
                break
        else:
            raise StepFailed("model_pull_interrupted")
        found = self.find_model(name)
        if not found:
            raise StepFailed("model_missing_after_pull", name)
        warning = self.memory_warning(found[1])
        size = sum(t for _, t in layers.values())
        # Ollama does not always send a last event per layer: success means all of it.
        extra = {"model": name, "progress": {"completed": size, "total": size}}
        if warning:
            extra["warning"] = warning
        return "model %s downloaded (%s)" % (name, human(found[1])), extra

    def do_model_remove(self, name):
        self.require_api()
        found = self.find_model(name)
        if not found:
            return "the model %s isn’t there" % name, {"model": name}
        self.sys.api("DELETE", "/api/delete", {"model": found[0]}, timeout=60)
        if self.find_model(name):
            raise StepFailed("model_remove_failed", name)
        return "model %s removed" % name, {"model": name}

    # --- status --------------------------------------------------------------------------

    def status(self, steps):
        version = self.installed_version()
        try:
            pinned = self.release()["version"]
        except StepFailed:
            pinned = None
        running = version is not None and self.service_active() and self.api_version() is not None
        models = self.models() if running else None
        return {
            "version": 1,
            "ollama": {"installed": version is not None, "version": version, "running": running,
                       "pinned": pinned},
            "models": [{"name": n, "size": s} for n, s in (models or [])],
            "steps": steps,
        }

    # --- driver --------------------------------------------------------------------------

    def run_step(self, name, args):
        self.step = name
        self.log.write("%s: start %s" % (name, " ".join(args)))
        extra = {}
        model = args[0] if name in ("model-pull", "model-remove") else None
        self.state.set(name, "running", "In progress", model=model)
        try:
            if name == "ollama-install":
                message = self.do_install()
            elif name == "ollama-update":
                message = self.do_update()
            elif name == "ollama-verify":
                message = self.do_verify()
            elif name in ("ollama-start", "ollama-stop", "ollama-restart"):
                message = self.do_service(name.split("-", 1)[1])
            elif name == "ollama-uninstall":
                message = self.do_uninstall("--remove-models" in args)
                self.log.write("%s: %s" % (name, message))
                self.state.set(name, "done", message)
                return 0
            elif name == "model-pull":
                message, extra = self.do_pull(args[0], "--force" in args)
            else:
                message, extra = self.do_model_remove(args[0])
        except StepFailed as exc:
            return self.fail(name, exc, model)
        except Interrupted:
            return self.fail(name, StepFailed("interrupted"), model)
        except NETWORK_ERRORS + (subprocess.SubprocessError, ValueError) as exc:
            return self.fail(name, StepFailed("unexpected_error", type(exc).__name__, exc), model)
        except Exception as exc:  # noqa: BLE001 - never leave a step `running` with a traceback
            return self.fail(name, StepFailed("unexpected_error", type(exc).__name__, exc), model)
        self.log.write("%s: done: %s" % (name, message))
        self.state.set(name, "done", message, **extra)
        return 0

    def fail(self, name, failure, model):
        """Records `failure` (a StepFailed) and prints "nido-provision: <code>: <message>"."""
        message = one_line(failure.message, 300)
        self.log.write("%s: failed: %s: %s" % (name, failure.code, message))
        data = self.state.load()
        previous = data["steps"].get(name) or {}
        extra = {"model": model}
        if isinstance(previous.get("progress"), dict):
            extra["progress"] = previous["progress"]
        self.state.set(name, "failed", message, **extra)
        _emit(sys.stderr, "nido-provision: %s: %s" % (failure.code, message))
        return 1


def _emit(stream, text):
    try:
        stream.write(text + "\n")
        stream.flush()
    except (OSError, ValueError):
        pass


def _parse(argv):
    """(step, args) or None for a usage error."""
    if not argv:
        return None
    name, rest = argv[0], argv[1:]
    if name in ("ollama-install", "ollama-update"):
        return (name, rest) if rest in ([], [ARCHIVE_FLAG]) else None
    if name in ("status", "log") or name in STEPS[:6]:
        return (name, []) if not rest else None
    if name == "ollama-uninstall":
        if rest in ([], ["--keep-models"], ["--remove-models"]):
            return name, rest
        return None
    if name in ("model-pull", "model-remove"):
        if not rest or not valid_model(rest[0]):
            return None
        flags = rest[1:]
        if name == "model-pull" and flags in ([], ["--force"]):
            return name, rest
        if name == "model-remove" and not flags:
            return name, rest
    return None


def _acquire(paths, wait=0.0):
    """The exclusive lock fd, or None when it stays busy for `wait` seconds (`status` holds it
    only for a moment, so a step waits a little instead of failing as busy)."""
    os.makedirs(paths.state_dir, exist_ok=True)
    os.chmod(paths.state_dir, 0o755)
    fd = os.open(paths.lock, os.O_RDWR | os.O_CREAT, 0o600)
    deadline = time.monotonic() + wait
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except OSError:
            if time.monotonic() >= deadline:
                os.close(fd)
                return None
            time.sleep(0.05)


def _on_term(signum, frame):
    raise Interrupted()


def main(argv=None, paths=None, system=None):
    argv = sys.argv[1:] if argv is None else argv
    paths = paths or Paths()
    system = system or System()
    parsed = _parse(argv)
    if parsed is None:
        _emit(sys.stderr, USAGE)
        return 2
    name, args = parsed
    prov = Provisioner(paths, system)
    prov.archive_on_stdin = ARCHIVE_FLAG in args
    if name == "log":
        sys.stdout.write(prov.log.tail())
        return 0
    lock = _acquire(paths, wait=0.0 if name == "status" else LOCK_WAIT)
    if name == "status":
        if lock is not None:
            steps = prov.state.mark_interrupted()["steps"]
            os.close(lock)
        else:
            steps = prov.state.load()["steps"]
        _emit(sys.stdout, json.dumps(prov.status(steps), ensure_ascii=False, sort_keys=True))
        return 0
    if lock is None:
        _emit(sys.stderr, "nido-provision: " + coded("busy"))
        return 3
    try:
        prov.state.mark_interrupted()
        return prov.run_step(name, args)
    finally:
        os.close(lock)


def entry():
    """Entry point of bin/nido-provision: a closed SSH session must not stop a long step."""
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, _on_term)
    signal.signal(signal.SIGINT, _on_term)
    os.umask(0o022)
    sys.exit(main())
