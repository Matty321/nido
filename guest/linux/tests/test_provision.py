# SPDX-License-Identifier: Apache-2.0
"""nido-provision: phase 2 steps (Ollama and models) against a fake system in a temporary root."""

import contextlib
import hashlib
import http.client
import io
import json
import os
import re
import stat
import tempfile
import threading
import time
import unittest

import support  # noqa: F401
from nido_guest_tools import provision

GiB = 1 << 30
VERSION = "0.40.10"
PAYLOAD = b"fake ollama archive " * 5000
ARCHIVE = "--archive-stdin"
# Words of the Italian messages the Guest Tools wrote before 1.5.0.
ITALIAN = re.compile(r"[àèéìòù]|\b(?:Riprova|usa|non|della?|dell|il|gli|riprova|uso|errore|installato|interrotto|modello|spazio|elevata|ridotta|quasi)\b")


class FakeSystem:
    """Records what the provisioner does; answers like a Debian arm64 guest."""

    def __init__(self, payload=PAYLOAD):
        self.machine_name = "aarch64"
        self.free = 100 * GiB
        self.mem = 8 * GiB
        self.payload = payload
        self.fail_after = None
        # Each time the provisioner reads the archive Nido sends on stdin.
        self.downloads = []
        self.extracts = []
        self.users = set()
        self.unit_enabled = False
        self.active = False
        self.systemctl_calls = []
        self.models = {}
        self.pulls = []
        self.deleted = []
        self.pull_total = 600 * 1024 * 1024
        self.pull_error = None
        self.stream_exception = None
        self.tags_response = None

    # host facts
    def machine(self):
        return self.machine_name

    def free_bytes(self, path):
        return self.free

    def mem_total(self):
        return self.mem

    def sleep(self, seconds):
        pass

    def sync(self):
        pass

    def boot_id(self):
        return "boot-A"

    # the archive Nido sends from the Mac on stdin
    def archive_input(self):
        self.downloads.append("stdin")
        body = self.payload if self.fail_after is None else self.payload[:self.fail_after]
        return io.BytesIO(body)

    # processes
    def extract(self, archive, dest):
        self.extracts.append(archive)
        os.makedirs(os.path.join(dest, "bin"))
        os.makedirs(os.path.join(dest, "lib", "ollama"))
        with open(os.path.join(dest, "bin", "ollama"), "w") as f:
            f.write("FAKE " + VERSION)
        os.chmod(os.path.join(dest, "bin", "ollama"), 0o755)
        with open(os.path.join(dest, "lib", "ollama", "libggml.so"), "w") as f:
            f.write("lib")

    def run(self, argv, timeout=60):
        if argv[-1] == "--version":
            with open(argv[0]) as f:
                version = f.read().split()[1]
            return 0, "ollama version is %s\n" % version
        return 1, "unknown"

    def systemctl(self, *args):
        self.systemctl_calls.append(args)
        verb = args[0]
        if verb == "is-active":
            return 0 if self.active else 3
        if verb == "is-enabled":
            return 0 if self.unit_enabled else 1
        if verb == "enable":
            self.unit_enabled = True
            if "--now" in args:
                self.active = True
        elif verb in ("start", "restart"):
            self.active = True
        elif verb == "stop":
            self.active = False
        elif verb == "disable":
            self.unit_enabled = False
            if "--now" in args:
                self.active = False
        return 0

    def user_exists(self, name):
        return name in self.users

    def add_system_user(self, name, home):
        self.users.add(name)
        os.makedirs(home, exist_ok=True)

    def remove_user(self, name):
        self.users.discard(name)

    # local Ollama API
    def api(self, method, path, body=None, timeout=10):
        if not self.active:
            raise OSError("connection refused")
        if path == "/api/version":
            return {"version": VERSION}
        if path == "/api/tags":
            if self.tags_response is not None:
                return self.tags_response
            return {"models": [{"name": n, "model": n, "size": s} for n, s in self.models.items()]}
        if path == "/api/delete":
            self.deleted.append(body["model"])
            self.models.pop(body["model"], None)
            return {}
        raise AssertionError(path)

    def api_stream(self, method, path, body, timeout=60):
        if not self.active:
            raise OSError("connection refused")
        self.pulls.append(body)
        if self.pull_error:
            yield {"error": self.pull_error}
            return
        total = self.pull_total
        yield {"status": "pulling manifest"}
        yield {"status": "pulling abc", "digest": "sha256:abc", "total": total, "completed": 0}
        if self.stream_exception is not None:
            raise self.stream_exception
        yield {"status": "pulling abc", "digest": "sha256:abc", "total": total, "completed": total}
        yield {"status": "verifying sha256 digest"}
        self.models[body["model"]] = total
        yield {"status": "success"}


class ProvisionTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = self._tmp.name
        self.paths = provision.Paths(self.root)
        self.sys = FakeSystem()
        os.makedirs(os.path.dirname(self.paths.release))
        self.write_release(PAYLOAD)
        with open(self.paths.unit_source, "w") as f:
            f.write("[Service]\nExecStart=/usr/local/bin/ollama serve\n")

    def tearDown(self):
        self._tmp.cleanup()

    def write_release(self, payload, sha=None):
        with open(self.paths.release, "w") as f:
            json.dump({
                "version": VERSION,
                "url": "https://github.com/ollama/ollama/releases/download/v%s/ollama-linux-arm64.tar.zst" % VERSION,
                "file": "ollama-linux-arm64.tar.zst",
                "size": len(payload),
                "sha256": sha or hashlib.sha256(payload).hexdigest(),
                "extracted_size_estimate": 3 * len(payload),
            }, f)

    def run_step(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = provision.main(list(argv), paths=self.paths, system=self.sys)
        return code, out.getvalue(), err.getvalue()

    def state(self):
        with open(self.paths.state) as f:
            return json.load(f)

    def step(self, name):
        return self.state()["steps"][name]

    def usr_local_files(self):
        found = []
        for base, dirs, files in os.walk(os.path.join(self.root, "usr", "local")):
            found += [os.path.join(base, n) for n in files]
            found += [os.path.join(base, n) for n in dirs if os.path.islink(os.path.join(base, n))]
        return found

    def tmp_files(self):
        if not os.path.isdir(self.paths.tmp):
            return []
        return os.listdir(self.paths.tmp)

    # --- install ---------------------------------------------------------------------------

    def test_installIsIdempotent(self):
        code, _, err = self.run_step("ollama-install", ARCHIVE)
        self.assertEqual(code, 0, err)
        self.assertEqual(self.step("ollama-install")["state"], "done")
        self.assertEqual(len(self.sys.downloads), 1)
        link = self.paths.link
        self.assertTrue(os.path.islink(link))
        self.assertEqual(os.path.realpath(link),
                         os.path.realpath(os.path.join(self.paths.lib, VERSION, "bin", "ollama")))
        self.assertIn("ollama", self.sys.users)
        self.assertTrue(self.sys.active and self.sys.unit_enabled)
        with open(self.paths.unit) as f, open(self.paths.unit_source) as g:
            self.assertEqual(f.read(), g.read())
        self.assertEqual(self.tmp_files(), [])

        calls_before = len(self.sys.systemctl_calls)
        code, _, err = self.run_step("ollama-install", ARCHIVE)
        self.assertEqual(code, 0, err)
        self.assertEqual(len(self.sys.downloads), 1)  # no new download
        self.assertEqual(len(self.sys.extracts), 1)
        mutating = [c for c in self.sys.systemctl_calls[calls_before:]
                    if c[0] not in ("is-active", "is-enabled")]
        self.assertEqual(mutating, [])
        self.assertEqual(self.step("ollama-install")["state"], "done")
        self.assertIn("already", self.step("ollama-install")["message"])

    def test_interruptedArchiveFailsAndRetryStartsOver(self):
        # The SSH session ends mid-transfer: the step fails, nothing half-written stays, and
        # "Riprova" (the Mac sends the whole archive again) installs.
        self.sys.fail_after = len(PAYLOAD) // 3
        code, _, err = self.run_step("ollama-install", ARCHIVE)
        self.assertEqual(code, 1)
        self.assertTrue(err.startswith("nido-provision: archive_incomplete: "), err)
        self.assertEqual(self.step("ollama-install")["state"], "failed")
        self.assertEqual(self.tmp_files(), [])
        self.assertEqual(self.usr_local_files(), [])

        self.sys.fail_after = None
        code, _, err = self.run_step("ollama-install", ARCHIVE)
        self.assertEqual(code, 0, err)
        self.assertEqual(self.step("ollama-install")["state"], "done")
        self.assertEqual(self.tmp_files(), [])

    def test_theGuestNeverDownloadsOllama(self):
        # The archive only comes from the Mac: without it a fresh install fails with a hint,
        # and the provisioner has no way to reach the network for it.
        self.assertFalse(hasattr(provision.System, "open_url"))
        self.assertFalse(hasattr(provision.Provisioner, "download"))
        code, _, err = self.run_step("ollama-install")
        self.assertEqual(code, 1)
        self.assertTrue(err.startswith("nido-provision: archive_from_mac_required: "), err)
        self.assertEqual(self.sys.downloads, [])
        self.assertEqual(self.usr_local_files(), [])

    def test_installedOllamaNeedsNoArchive(self):
        self.assertEqual(self.run_step("ollama-install", ARCHIVE)[0], 0)
        code, _, err = self.run_step("ollama-install")
        self.assertEqual(code, 0, err)
        self.assertEqual(len(self.sys.downloads), 1)
        self.assertIn("already", self.step("ollama-install")["message"])

    def test_damagedTreeIsReinstalled(self):
        # A crash after the rename can leave empty files behind (seen on a real VM): the size
        # manifest catches them and "Riprova" installs again instead of declaring success.
        self.assertEqual(self.run_step("ollama-install", ARCHIVE)[0], 0)
        lib = os.path.join(self.paths.lib, VERSION, "lib", "ollama", "libggml.so")
        open(lib, "w").close()
        code, out, _ = self.run_step("status")
        self.assertFalse(json.loads(out)["ollama"]["installed"])
        code, _, err = self.run_step("ollama-install", ARCHIVE)
        self.assertEqual(code, 0, err)
        self.assertEqual(len(self.sys.downloads), 2)
        with open(lib) as f:
            self.assertEqual(f.read(), "lib")
        self.assertEqual(self.run_step("ollama-verify")[0], 0)
        open(lib, "w").close()
        self.assertEqual(self.run_step("ollama-verify")[0], 1)

    def test_staleStagingAndOldPartsAreRemoved(self):
        os.makedirs(os.path.join(self.paths.tmp, "stage-0.1.0", "bin"))
        with open(os.path.join(self.paths.tmp, "ollama-linux-amd64.tgz.part"), "wb") as f:
            f.write(b"old")
        code, _, err = self.run_step("ollama-install", ARCHIVE)
        self.assertEqual(code, 0, err)
        self.assertEqual(self.tmp_files(), [])

    def test_incomingLeftByAnInterruptedCopyIsRemoved(self):
        # A copy across file systems interrupted by a crash leaves .incoming-<version> next to the
        # versions: the next install removes it, whatever version it was for.
        for leftover in (".incoming-0.1.0", ".incoming-" + VERSION):
            os.makedirs(os.path.join(self.paths.lib, leftover, "bin"))
        code, _, err = self.run_step("ollama-install", ARCHIVE)
        self.assertEqual(code, 0, err)
        self.assertEqual([n for n in os.listdir(self.paths.lib) if n.startswith(".incoming")], [])
        self.assertTrue(os.path.isdir(os.path.join(self.paths.lib, VERSION)))

    def test_checksumMismatchFailsAndCleans(self):
        self.write_release(PAYLOAD, sha="0" * 64)
        code, _, err = self.run_step("ollama-install", ARCHIVE)
        self.assertEqual(code, 1)
        self.assertEqual(
            err, "nido-provision: archive_checksum_mismatch: the Ollama archive’s checksum doesn’t "
            "match: file discarded, click Try Again\n")
        self.assertEqual(self.step("ollama-install")["message"],
                         "the Ollama archive’s checksum doesn’t match: file discarded, click Try Again")
        self.assertEqual(self.step("ollama-install")["state"], "failed")
        self.assertEqual(self.tmp_files(), [])
        self.assertEqual(self.usr_local_files(), [])
        self.assertEqual(self.sys.extracts, [])
        self.assertFalse(self.sys.active)

    def test_refusesNonArm64(self):
        self.sys.machine_name = "x86_64"
        code, _, err = self.run_step("ollama-install", ARCHIVE)
        self.assertEqual(code, 1)
        self.assertEqual(err, "nido-provision: architecture_unsupported: unsupported architecture "
                              "(x86_64): aarch64 required\n")
        self.assertEqual(self.sys.downloads, [])
        self.assertEqual(self.step("ollama-install")["state"], "failed")

    def test_refusesLowDisk(self):
        self.sys.free = 2 * GiB + 4 * len(PAYLOAD) - 1
        code, _, err = self.run_step("ollama-install", ARCHIVE)
        self.assertEqual(code, 1)
        self.assertTrue(err.startswith("nido-provision: disk_space_low: not enough disk space: "), err)
        self.assertEqual(self.sys.downloads, [])
        self.sys.free = 2 * GiB + 4 * len(PAYLOAD)
        code, _, err = self.run_step("ollama-install", ARCHIVE)
        self.assertEqual(code, 0, err)

    def test_foreignOllamaIsNotReplaced(self):
        os.makedirs(os.path.dirname(self.paths.link))
        with open(self.paths.link, "w") as f:
            f.write("someone else's ollama")
        code, _, err = self.run_step("ollama-install", ARCHIVE)
        self.assertEqual(code, 1)
        with open(self.paths.link) as f:
            self.assertEqual(f.read(), "someone else's ollama")

    def test_successOnlyAfterChecks(self):
        real_api = self.sys.api

        def api(method, path, body=None, timeout=10):
            if path == "/api/version":
                raise OSError("connection refused")
            return real_api(method, path, body, timeout)
        self.sys.api = api
        code, _, err = self.run_step("ollama-install", ARCHIVE)
        self.assertEqual(code, 1)
        self.assertEqual(self.step("ollama-install")["state"], "failed")

    def test_updateReplacesOldVersion(self):
        self.assertEqual(self.run_step("ollama-install", ARCHIVE)[0], 0)
        old = os.path.join(self.paths.lib, "0.1.0")
        os.makedirs(os.path.join(old, "bin"))
        with open(os.path.join(old, "bin", "ollama"), "w") as f:
            f.write("FAKE 0.1.0")
        os.remove(self.paths.link)
        os.symlink(os.path.join(old, "bin", "ollama"), self.paths.link)
        code, _, err = self.run_step("ollama-update", ARCHIVE)
        self.assertEqual(code, 0, err)
        self.assertFalse(os.path.exists(old))
        self.assertIn(VERSION, os.path.realpath(self.paths.link))
        self.assertIn(("restart", "ollama.service"), self.sys.systemctl_calls)

    # --- models ----------------------------------------------------------------------------

    def install(self):
        code, _, err = self.run_step("ollama-install", ARCHIVE)
        self.assertEqual(code, 0, err)

    def test_modelPullWritesProgressAndChecksPresence(self):
        self.install()
        code, _, err = self.run_step("model-pull", "qwen3:0.6b")
        self.assertEqual(code, 0, err)
        entry = self.step("model-pull")
        self.assertEqual(entry["state"], "done")
        self.assertEqual(entry["model"], "qwen3:0.6b")
        self.assertEqual(entry["progress"], {"completed": self.sys.pull_total,
                                             "total": self.sys.pull_total})
        self.assertEqual(self.sys.pulls, [{"model": "qwen3:0.6b", "stream": True}])

    def test_pullErrorFails(self):
        self.install()
        self.sys.pull_error = "pull model manifest: file does not exist"
        code, _, err = self.run_step("model-pull", "nope:1b")
        self.assertEqual(code, 1)
        self.assertIn("file does not exist", err)
        self.assertEqual(self.step("model-pull")["state"], "failed")

    def test_warnsLowMemory(self):
        self.install()
        self.sys.mem = int(1.1 * self.sys.pull_total)
        code, _, err = self.run_step("model-pull", "qwen3:0.6b")
        self.assertEqual(code, 0, err)  # warn, don't refuse
        entry = self.step("model-pull")
        self.assertEqual(entry["state"], "done")
        self.assertRegex(entry["warning"], r"^model_memory_low: the VM has \d+ MiB of RAM and the model "
                                           r"takes 600 MiB: it may be slow or fail to start$")

        self.sys.mem = 8 * GiB
        self.run_step("model-pull", "gemma3:1b")
        self.assertNotIn("warning", self.step("model-pull"))

    def test_existingModelNotOverwritten(self):
        self.install()
        self.sys.models["qwen3:0.6b"] = 123
        code, _, err = self.run_step("model-pull", "qwen3:0.6b")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.sys.pulls, [])
        self.assertEqual(self.step("model-pull")["state"], "done")
        self.assertIn("already", self.step("model-pull")["message"])
        code, _, err = self.run_step("model-pull", "qwen3:0.6b", "--force")
        self.assertEqual(code, 0, err)
        self.assertEqual(len(self.sys.pulls), 1)

    def test_modelNameWithoutTagMatchesLatest(self):
        self.install()
        self.sys.models["llama3.2:latest"] = 1
        self.assertEqual(self.run_step("model-pull", "llama3.2")[0], 0)
        self.assertEqual(self.sys.pulls, [])

    def test_invalidModelNameRefused(self):
        for bad in ("-rf", "a;b", "a b", "", "x" * 129, "é"):
            code, _, _ = self.run_step("model-pull", bad)
            self.assertEqual(code, 2, bad)
        self.assertEqual(self.sys.pulls, [])

    def test_pullNeedsRunningOllama(self):
        code, _, err = self.run_step("model-pull", "qwen3:0.6b")
        self.assertEqual(code, 1)
        self.assertTrue(err.startswith("nido-provision: ollama_not_running: "), err)

    def test_modelRemove(self):
        self.install()
        self.sys.models["qwen3:0.6b"] = 1
        self.assertEqual(self.run_step("model-remove", "qwen3:0.6b")[0], 0)
        self.assertEqual(self.sys.deleted, ["qwen3:0.6b"])
        self.assertEqual(self.run_step("model-remove", "qwen3:0.6b")[0], 0)  # already gone
        self.assertEqual(self.sys.deleted, ["qwen3:0.6b"])

    # --- uninstall, service ----------------------------------------------------------------

    def test_uninstallKeepsModelsByDefault(self):
        self.install()
        os.makedirs(self.paths.models)
        blob = os.path.join(self.paths.models, "blob")
        with open(blob, "w") as f:
            f.write("weights")
        for argv in (("ollama-uninstall",), ("ollama-uninstall", "--keep-models")):
            code, _, err = self.run_step(*argv)
            self.assertEqual(code, 0, err)
            self.assertTrue(os.path.exists(blob))
            self.assertFalse(os.path.lexists(self.paths.link))
            self.assertFalse(os.path.exists(self.paths.unit))
            self.assertEqual(self.usr_local_files(), [])
            self.assertFalse(os.path.exists(self.paths.lib))
            self.assertFalse(self.sys.active)
            self.install()
        code, _, err = self.run_step("ollama-uninstall", "--remove-models")
        self.assertEqual(code, 0, err)
        self.assertFalse(os.path.exists(blob))
        self.assertNotIn("ollama", self.sys.users)

    def test_startStopRestart(self):
        self.install()
        self.assertEqual(self.run_step("ollama-stop")[0], 0)
        self.assertFalse(self.sys.active)
        self.assertEqual(self.run_step("ollama-start")[0], 0)
        self.assertTrue(self.sys.active)
        self.assertEqual(self.run_step("ollama-restart")[0], 0)
        self.assertEqual(self.run_step("ollama-verify")[0], 0)
        self.assertEqual(self.step("ollama-verify")["state"], "done")

    def test_stoppedOllamaStaysStoppedAfterReboot(self):
        self.install()
        self.assertEqual(self.run_step("ollama-stop")[0], 0)
        self.assertFalse(self.sys.active)
        # Disabled: the next boot does not start it again.
        self.assertFalse(self.sys.unit_enabled)
        self.assertEqual(self.run_step("ollama-start")[0], 0)
        self.assertTrue(self.sys.unit_enabled)
        self.assertTrue(self.sys.active)

    def test_startWithoutInstallFails(self):
        code, _, err = self.run_step("ollama-start")
        self.assertEqual(code, 1)
        self.assertEqual(err, "nido-provision: ollama_not_installed: Ollama isn’t installed\n")

    # --- state and status ------------------------------------------------------------------

    def test_stateFileFormat(self):
        self.install()
        st = os.stat(self.paths.state)
        self.assertEqual(stat.S_IMODE(st.st_mode), 0o644)
        self.assertEqual(stat.S_IMODE(os.stat(self.paths.state_dir).st_mode), 0o755)
        data = self.state()
        self.assertEqual(data["version"], 1)
        for name, entry in data["steps"].items():
            self.assertIn(entry["state"], ("pending", "running", "done", "failed"))
            self.assertIsInstance(entry["message"], str)
            self.assertRegex(entry["updated"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertFalse([n for n in os.listdir(self.paths.state_dir) if n.startswith(".state")])
        with open(self.paths.log) as f:
            self.assertIn("ollama-install", f.read())

    def test_interruptedRunningStepReportedAsFailed(self):
        provision.State(self.paths).set("model-pull", "running", "Downloading the model")
        code, out, _ = self.run_step("status")
        self.assertEqual(code, 0)
        doc = json.loads(out)
        self.assertEqual(doc["steps"]["model-pull"]["state"], "failed")
        self.assertEqual(doc["steps"]["model-pull"]["message"], provision.INTERRUPTED)
        self.assertIn("interrupted", provision.INTERRUPTED)

    def test_statusReportsOllamaAndModels(self):
        code, out, _ = self.run_step("status")
        doc = json.loads(out)
        self.assertEqual(doc["version"], 1)
        self.assertEqual(doc["ollama"]["installed"], False)
        self.assertEqual(doc["ollama"]["running"], False)
        self.assertEqual(doc["models"], [])
        self.install()
        self.sys.models["qwen3:0.6b"] = 522653277
        doc = json.loads(self.run_step("status")[1])
        self.assertEqual(doc["ollama"], {"installed": True, "version": VERSION, "running": True,
                                         "pinned": VERSION})
        self.assertEqual(doc["models"], [{"name": "qwen3:0.6b", "size": 522653277}])

    def test_logPrintsTail(self):
        self.install()
        code, out, _ = self.run_step("log")
        self.assertEqual(code, 0)
        self.assertIn("ollama-install", out)

    def test_concurrentStepRefused(self):
        lock = provision._acquire(self.paths)
        try:
            code, _, err = self.run_step("ollama-install", ARCHIVE)
            self.assertEqual(code, 3)
            self.assertEqual(err, "nido-provision: busy: another step is running, try again shortly\n")
            self.assertEqual(self.sys.downloads, [])
            self.assertEqual(self.run_step("status")[0], 0)  # status never waits
        finally:
            os.close(lock)

    # --- review fixes ----------------------------------------------------------------------

    def test_streamBrokenMidPullFailsTheStep(self):
        self.install()
        self.sys.stream_exception = http.client.IncompleteRead(b"partial", 100)
        code, _, err = self.run_step("model-pull", "qwen3:0.6b")
        self.assertEqual(code, 1)
        self.assertEqual(len(err.strip().splitlines()), 1)
        self.assertTrue(err.startswith("nido-provision: "))
        self.assertEqual(self.step("model-pull")["state"], "failed")

    def test_unexpectedExceptionFailsTheStepWithOneLine(self):
        self.install()
        self.sys.stream_exception = RuntimeError("boom\nsecond line\x1b[31m")
        code, _, err = self.run_step("model-pull", "qwen3:0.6b")
        self.assertEqual(code, 1)
        self.assertEqual(len(err.strip().splitlines()), 1)
        self.assertTrue(err.startswith("nido-provision: unexpected_error: unexpected error (RuntimeError: boom "), err)
        self.assertNotIn("\x1b", err)
        entry = self.step("model-pull")
        self.assertEqual(entry["state"], "failed")
        self.assertNotIn("\n", entry["message"])

    def test_unexpectedTagsShapeIsTolerated(self):
        self.install()
        for shape in ([1, 2], {"models": "x"}, {"models": [1, None, {"name": 3}]}):
            self.sys.tags_response = shape
            code, out, _ = self.run_step("status")
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(out)["models"], [])
            code, _, err = self.run_step("model-remove", "qwen3:0.6b")
            self.assertEqual(code, 0, err)

    def test_modelNameWithTrailingNewlineRefused(self):
        self.assertEqual(self.run_step("model-pull", "qwen3\n")[0], 2)
        self.assertFalse(provision.valid_model("qwen3\n"))

    def test_runningEntryRecordsBootAndPid(self):
        provision.State(self.paths, boot_id="boot-A").set("model-pull", "running", "x")
        entry = self.step("model-pull")
        self.assertEqual(entry["boot_id"], "boot-A")
        self.assertEqual(entry["pid"], os.getpid())
        provision.State(self.paths, boot_id="boot-A").set("model-pull", "done", "ok")
        self.assertNotIn("pid", self.step("model-pull"))

    def test_stepWaitsBrieflyForTheLock(self):
        lock = provision._acquire(self.paths)

        def release():
            time.sleep(0.3)
            os.close(lock)
        t = threading.Thread(target=release)
        t.start()
        code, _, err = self.run_step("ollama-install", ARCHIVE)
        t.join()
        self.assertEqual(code, 0, err)

    def test_archiveKeptUntilLinked(self):
        real_link = provision.Provisioner.link
        calls = []

        def broken_link(prov, version):
            calls.append(version)
            if len(calls) == 1:
                raise OSError("interrupted before the link")
            return real_link(prov, version)
        provision.Provisioner.link = broken_link
        try:
            self.assertEqual(self.run_step("ollama-install", ARCHIVE)[0], 1)
            self.assertIn("ollama-linux-arm64.tar.zst.part", self.tmp_files())
            code, _, err = self.run_step("ollama-install", ARCHIVE)
            self.assertEqual(code, 0, err)
        finally:
            provision.Provisioner.link = real_link
        self.assertEqual(len(self.sys.downloads), 1)  # no second download
        self.assertEqual(self.tmp_files(), [])

    def write_foreign_unit(self):
        os.makedirs(os.path.dirname(self.paths.unit), exist_ok=True)
        with open(self.paths.unit, "w") as f:
            f.write("[Service]\nExecStart=/usr/bin/ollama serve\n")
        os.makedirs(self.paths.models)
        self.sys.users.add("ollama")

    def test_foreignInstallIsNotTouched(self):
        self.write_foreign_unit()
        for argv in (("ollama-install", ARCHIVE), ("ollama-uninstall", "--remove-models"),
                     ("ollama-uninstall",)):
            code, _, err = self.run_step(*argv)
            self.assertEqual(code, 1, argv)
            self.assertTrue(err.startswith("nido-provision: ollama_foreign: "), err)
            with open(self.paths.unit) as f:
                self.assertIn("/usr/bin/ollama", f.read())
            self.assertTrue(os.path.isdir(self.paths.models))
            self.assertIn("ollama", self.sys.users)
        self.assertEqual(self.sys.downloads, [])

    def test_symlinkedUnitIsForeign(self):
        # A masked unit (a link to /dev/null) reads as empty but is the admin's, not a crash.
        os.makedirs(os.path.dirname(self.paths.unit), exist_ok=True)
        os.symlink(os.devnull, self.paths.unit)
        for argv in (("ollama-install", ARCHIVE), ("ollama-uninstall",)):
            code, _, err = self.run_step(*argv)
            self.assertEqual(code, 1, argv)
            self.assertTrue(err.startswith("nido-provision: ollama_foreign: "), err)
            self.assertTrue(os.path.islink(self.paths.unit))
            self.assertEqual(os.readlink(self.paths.unit), os.devnull)
        self.assertEqual(self.sys.downloads, [])

    def test_emptyUnitLeftByACrashIsOurs(self):
        os.makedirs(os.path.dirname(self.paths.unit), exist_ok=True)
        open(self.paths.unit, "w").close()
        self.assertEqual(self.run_step("ollama-install", ARCHIVE)[0], 0)

    def test_unknownStepIsUsageError(self):
        for argv in (("nope",), (), ("ollama-uninstall", "--yes"), ("model-pull",),
                     ("ollama-install", "--archive"), ("ollama-verify", ARCHIVE),
                     ("ollama-install", ARCHIVE, ARCHIVE)):
            code, _, err = self.run_step(*argv)
            self.assertEqual(code, 2, argv)
            # Nido reads a usage error as Guest Tools too old for the step's arguments.
            self.assertTrue(err.startswith("usage: nido-provision ollama-install "), err)

    # --- messages --------------------------------------------------------------------------

    def test_failureLineIsCodeThenEnglishMessage(self):
        # One line "nido-provision: <code>: <message>": the code is what Nido localizes.
        self.assertEqual(self.run_step("ollama-install")[0], 1)
        code, _, err = self.run_step("ollama-verify")
        self.assertEqual(code, 1)
        self.assertEqual(err, "nido-provision: ollama_not_installed: Ollama isn’t installed\n")
        self.assertEqual(self.step("ollama-verify")["message"], "Ollama isn’t installed")
        with open(self.paths.log, encoding="utf-8") as f:
            self.assertIn("ollama-verify: failed: ollama_not_installed: Ollama isn’t installed", f.read())

    def test_codesAreStableSnakeCaseWithEnglishMessages(self):
        self.assertGreaterEqual(len(provision.MESSAGES), 25)
        for code, message in provision.MESSAGES.items():
            self.assertRegex(code, r"^[a-z][a-z0-9]*(_[a-z0-9]+)*$")
            self.assertEqual(message, message.strip(), code)
            self.assertNotIn("\n", message, code)
            self.assertEqual(message.replace("%s", "").count("%"), 0, code)
            self.assertNotRegex(message, ITALIAN, code)

    def test_everyFailureUsesACodeOfTheTable(self):
        with open(provision.__file__, encoding="utf-8") as f:
            source = f.read()
        used = set(re.findall(r"(?:StepFailed|coded)\(\s*\"([a-z0-9_]+)\"", source))
        self.assertEqual(used, set(provision.MESSAGES))
        # A StepFailed never carries free text.
        self.assertEqual(re.findall(r"(?<!class )StepFailed\(\s*[^\"\s)]", source), [])

    def test_longValuesAreCutSoTheMessageKeepsItsShape(self):
        # Nido reads the values back from the message: a long detail is cut inside its value,
        # never at the end of the line, so the template's closing text survives.
        self.install()
        self.sys.stream_exception = RuntimeError("x" * 1000)
        code, _, err = self.run_step("model-pull", "qwen3:0.6b")
        self.assertEqual(code, 1)
        line = err.rstrip("\n")
        self.assertRegex(line, r"^nido-provision: unexpected_error: unexpected error \(RuntimeError: x+…\)$")
        self.assertEqual(self.step("model-pull")["message"], line.split(": ", 2)[2])

    def test_everyMessageFitsTheLineWithLongValues(self):
        # With every value at its longest, no message reaches the cut of fail() (300).
        for code, template in provision.MESSAGES.items():
            values = ["y" * 1000] * template.count("%s")
            message = provision.StepFailed(code, *values).message
            self.assertLessEqual(len(message), 300, code)
            self.assertEqual(provision.one_line(message, 300), message, code)

    def test_wrongArgumentsForACodeAreAnError(self):
        with self.assertRaises(TypeError):
            provision.StepFailed("ollama_files_damaged")

    def test_noItalianLeftInTheGuestTools(self):
        # Messages, progress, the log and the monitor's alerts are English (Nido localizes).
        import ast
        from nido_guest_tools import metrics
        for module in (provision, metrics):
            with open(module.__file__, encoding="utf-8") as f:
                tree = ast.parse(f.read())
            for node in ast.walk(tree):
                if isinstance(node, ast.Constant) and isinstance(node.value, str):
                    self.assertNotRegex(node.value, ITALIAN, module.__name__)


if __name__ == "__main__":
    unittest.main()
