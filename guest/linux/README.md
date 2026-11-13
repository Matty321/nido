# Nido Guest Tools (Linux)

Read-only system monitor for Debian guests. Python 3 standard library only.
Listens on AF_VSOCK port 7700 (never TCP); `GET /api/status` returns JSON
(compatible with the `Nido AI Monitor` 2.0 API; thresholds CPU > 85, RAM > 85, disk > 90).

`reference/` holds the user's original `monitor.py` and `monitor_api.py`, read from the
`AI-Linux` VM on 2026-10-24. They are a compatibility fixture for `tests/test_compat.py`; do not edit.

## Manual install and recovery (Debian 13 ARM64)

Nido installs the Guest Tools by itself: through cloud-init on a new VM, or over SSH with
"Installa Guest Tools" on an existing one. Do it by hand only when Nido cannot reach the guest.

### What you need first
- A **Debian 13 (trixie)** or **Ubuntu Server 26.04 / 24.04 LTS** arm64 guest (the installer
  stops with `unsupported` on anything else), `python3`, `systemd`, `tar`, `gzip`, `base64` (all
  in the Debian and Ubuntu cloud images) and `sudo`.
- **An access to the VM**: a working SSH session (also from another Mac, or `nido ssh <vm>` in the
  Terminal, which uses the VM's key) **or** a password you set earlier for the user `nido`. VMs
  created by Nido have no password (`lock_passwd: true`), so the console login prompt alone is not
  an access: without SSH and without a password set beforehand, the Guest Tools cannot be installed.
- The `vsock` device is added by Nido at every start of a Linux VM (since Nido 0.3.0); after installing,
  the monitor answers at once if the VM was started by Nido.app, otherwise at its next start there.

### Way 1: the app's manual installer (recommended)
VM settings (S08) → Guest Tools → "Installazione manuale" → "Copia i comandi" copies one text (`GuestToolsInstaller.manualInstallCommand`):
a gzip+base64 here-document piped to `sudo /bin/sh -c '<bootstrap>'`. Copy it whole and paste it
into a shell of the guest (it fits one paste, at most 32 KiB, also in Nido's console). It installs
exactly what `install(on:)` installs over SSH, is idempotent and prints `NIDO_RESULT=installed`,
`NIDO_RESULT=unchanged` or `NIDO_RESULT=unsupported`.

### Way 2: from a checkout of this repository (as root in the guest)

    install -d /opt/nido-guest-tools
    cp -r bin nido_guest_tools ollama VERSION /opt/nido-guest-tools/
    chmod 0755 /opt/nido-guest-tools/bin/nido-guest-tools /opt/nido-guest-tools/bin/nido-provision \
        /opt/nido-guest-tools/bin/nido-ai-bridge
    cp systemd/nido-guest-tools.service systemd/nido-ai-bridge.service /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now nido-guest-tools nido-ai-bridge

The units run with `DynamicUser=yes`. `/var/lib/nido-provision/state.json`, if present, is
embedded as the `provisioning` field. A manual install does not update the VM's config
(`guestToolsVersion`): Nido records it at the next "Installa Guest Tools" that reaches the guest.

### Visible panics and automatic reboot (optional, as root)
New VMs with the Guest Tools get them from cloud-init; existing ones only on request (S08 →
"Impostazioni anti-blocco" → "Applica", over SSH, or by hand):

    printf '%s\n' '# Nido: kernel messages and panics also on the virtio console (console.log of the VM).' \
        'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT console=tty0 console=hvc0"' \
        > /etc/default/grub.d/nido.cfg
    printf '%s\n' '# Nido: reboot 10 seconds after a kernel panic; an oops is a panic.' \
        'kernel.panic = 10' 'kernel.panic_on_oops = 1' > /etc/sysctl.d/90-nido.conf
    chmod 0644 /etc/default/grub.d/nido.cfg /etc/sysctl.d/90-nido.conf
    update-grub && sysctl --system

The sysctl values apply at once, the kernel command line from the next boot.

### Recovery
- **Monitor says "Guest Tools non installati" or "Monitor non raggiungibile"**:
  `systemctl status nido-guest-tools` and `journalctl -u nido-guest-tools -b`. The service restarts
  on failure; `systemctl restart nido-guest-tools`. A VM started with `nido start` has no monitor
  in the app (the vsock device belongs to that process): start it from Nido.app.
- **"Versione dei Guest Tools non riconosciuta"**: the guest has Guest Tools newer or older than the
  app; install the app's version again (Way 1 or "Installa Guest Tools"). Files that are equal are
  left alone.
- **AI bridge answers `502 bridge_unavailable`**: the VM runs under `nido start`, or the app could not
  attach the bridge: restart the VM from Nido.app. `403 bridge_disabled` means it is off for the VM;
  `401 token_missing` that the Mac has no Hugging Face token.
- **A phase-2 step failed or was interrupted** (VM stopped, network lost, disk full):
  `sudo /opt/nido-guest-tools/bin/nido-provision status` shows every step, `... log` the log
  (`/var/log/nido-provision.log`). Run the failed step again ("Riprova" in the app does exactly
  this): `model-pull <id>` by hand; `ollama-install` needs the archive from the Mac, so use the app
  (by hand it only completes an install whose archive is already in the guest).
  A step left `running` by a reboot or a killed process is reported as `failed`. Nothing half
  installed is ever moved into `/usr/local`; a leftover `/usr/local/lib/nido-ollama/.incoming-*`
  (copy across file systems interrupted) is removed by the next install or update.
- **Another Ollama is already installed** (`/usr/local/bin/ollama` or `ollama.service` not made by
  Nido, also a masked unit): `nido-provision` refuses to replace or remove it. Remove it yourself
  or keep using it outside Nido.
- **Removing the Guest Tools** (as root): `systemctl disable --now nido-guest-tools nido-ai-bridge`,
  `rm /etc/systemd/system/nido-guest-tools.service /etc/systemd/system/nido-ai-bridge.service`,
  `systemctl daemon-reload`, `rm -r /opt/nido-guest-tools`. Ollama, if installed by Nido, first:
  `nido-provision ollama-uninstall --keep-models` (or `--remove-models`).

## AI bridge shim: `nido-ai-bridge`

The only TCP listener of the Guest Tools, and on loopback only: `127.0.0.1:11435` (11434 stays
Ollama's). Each connection is copied byte for byte to the Mac over vsock (CID 2, port 7701),
where Nido's proxy applies the VM's policy and adds the Hugging Face token; nothing about the
token or the policy is in the guest. Agents use `OPENAI_BASE_URL=http://127.0.0.1:11435/v1` with
any key. At most 4 connections at once (more get `503`). The Mac answers one request per connection
(`Connection: close`): once it has closed, the shim stops reading from the client too, so a
client that keeps its socket open (a pooled connection) does not hold a slot. When the Mac does not answer (bridge
not registered, e.g. a VM started with `nido start`) the shim answers `502` with code
`bridge_unavailable`. The unit adds `IPAddressDeny=any` / `IPAddressAllow=localhost` to the
monitor's hardening.

## Phase 2: `nido-provision` (Ollama and models)

Run as root by Nido over SSH (`sudo -n /opt/nido-guest-tools/bin/nido-provision <step>`), only
when the user chooses it; never by cloud-init. Steps: `ollama-install`, `ollama-verify`,
`ollama-start|stop|restart`, `ollama-install|ollama-update [--archive-stdin]`, `ollama-uninstall [--keep-models|--remove-models]`,
`model-pull <id> [--force]`, `model-remove <id>`, `status` (JSON), `log`. Every step is
idempotent and can be re-run after an interruption.

- Ollama: the pinned release of `ollama/release.json` (official GitHub release). Since Guest
  Tools 1.4.0 the guest never downloads it: Nido downloads it on the Mac, checks its SHA-256
  there, and sends it on stdin of `ollama-install --archive-stdin` (or `ollama-update`). The guest
  writes exactly `size` bytes into `/var/lib/nido-provision/tmp/<file>.part`, checks the SHA-256
  again (an incomplete or wrong archive is removed: "Riprova" sends it again), extracts and checks
  it there, then moved with one rename into
  `/usr/local/lib/nido-ollama/<version>/` and linked from `/usr/local/bin/ollama`.
- `ollama/ollama.service` is copied to `/etc/systemd/system/` and enabled by `ollama-install`
  only: user `ollama` (home `/usr/share/ollama`, models in `~/.ollama/models`),
  `OLLAMA_HOST=127.0.0.1:11434`.
- State: `/var/lib/nido-provision/state.json` (0644, no secrets); log:
  `/var/log/nido-provision.log`.
- A `running` step records `boot_id` and `pid`: the monitor reports one left by a reboot or a
  killed process as `failed` ("interrupted"). An Ollama not installed by Nido (another
  `/usr/local/bin/ollama` or `ollama.service`) is never replaced or removed.
- Messages, the state and the log are English. A failed step exits 1 with one line on stderr,
  `nido-provision: <code>: <message>`, and `model-pull` stores its memory warning as
  `<code>: <message>`: the codes are stable (the `MESSAGES` table at the top of `provision.py`)
  and Nido shows its own text for each, in the Mac's language. A usage error exits 2 with
  `usage: nido-provision …`. Guest Tools before 1.5.0 wrote Italian (`uso: nido-provision …`):
  Nido shows that text as it is.

Known limits:
- If `/usr/local` is on another file system than `/var/lib`, the tree is copied to
  `/usr/local/lib/nido-ollama/.incoming-<version>` before the final rename; a crash during that
  copy leaves it there until the next install or update removes it.

Since Guest Tools 1.3.0:
- `ollama-stop` also disables the service: a stopped Ollama stays stopped after a reboot until a
  step starts it again (`ollama-start`, `ollama-restart`, `ollama-install` or `ollama-update`,
  which all enable it).
- The installer keeps the list of the files it installed in `/opt/nido-guest-tools/MANIFEST`;
  an upgrade removes what the previous version listed and the new one no longer has: only files
  whose real folder is `/opt/nido-guest-tools/` or below (no `..`, no link to another folder) and
  `nido-*.service` units directly in `/etc/systemd/system/`, a unit disabled first. Upgrading from
  a version without a `MANIFEST` (1.2.x and earlier, or the manual install below, which writes
  none) removes nothing; neither does the manual method remove `__pycache__` folders.
- Both units run with extra systemd sandboxing (no capabilities, private `/tmp` and `/dev`,
  protected kernel settings, no namespaces, no writable-and-executable memory, only the address
  families each service needs). The monitor keeps the host's hostname namespace (it reports the
  hostname); the shim also has `ProtectHostname`.

## Tests

From the repository root: `python3 -m unittest discover -s guest/linux/tests`
