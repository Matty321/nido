# What’s New in Nido

Every Nido release, newest first. The first time Nido opens after an update, it shows the notes for the installed version (choose Help › What’s New in Nido to read them again).

## [0.8.0] – 2026-11-11

### Languages
- **Nido now speaks English, Italian, German, Spanish and French**: the app, the `nido` command, the release notes and the README. English is the base language. The app follows the language you use in macOS and falls back to English for any other language.
- The `nido` command follows the system language. Set `NIDO_LANGUAGE` (`en`, `it`, `de`, `es` or `fr`) to choose another one, for example in scripts that read its output.

### Nido Guest Tools 1.5.0
- **Messages about Ollama and models now appear in your language**: the Guest Tools send a stable code with each error and warning, and the app shows its own text for it. Earlier Guest Tools still send their messages in Italian, and Nido shows them as they arrive: reinstall the Guest Tools from the VM’s settings to get the new version in existing VMs.

### The nido Command in the Menu
- **Nido › Install the nido Command…** creates `~/.local/bin/nido`, a link to the command, which now lives inside the app (along with `gvproxy`): the command updates with the app. If `~/.local/bin` isn’t in your `PATH`, Nido tells you. A copy installed earlier by `scripts/install.sh` is replaced only after you confirm.
- **Nido › Remove the nido Command** removes the link only if it points to Nido.
- When you open Nido straight from the DMG, it doesn’t install the command and asks you to move it to Applications first.

### Updates
- **Nido › Check for Updates…** looks for a new version. Nido never goes online on its own: automatic checks run only if you turn them on (when Nido asks at its second launch, or in **Settings › General › Check for updates automatically**, off by default).
- **Never with a VM running**: while a VM is running, in the app or with `nido start`, a downloaded update waits. It installs when you quit Nido with no VM running, and a notice tells you which VMs are holding it back.
- Every update is signed (EdDSA) and downloaded over HTTPS; Nido rejects an update or a list of versions without a valid signature.

### Developer ID Signing
- **Nido is signed with a Developer ID certificate and notarized by Apple**: it opens without working around Gatekeeper. The app, the `nido` command, `gvproxy` and Sparkle all carry the same signature, with the Hardened Runtime.
- The SHA-256 checksums and the list of components (SBOM, SPDX) are published next to the DMG.

### Keychain
- **After the signing change, macOS may ask once more for access to the Hugging Face token** stored in the Keychain. Allow it once; if the token can no longer be read, enter it again in **Settings › Hugging Face**.

### Security
- **A VM can no longer make Nido quit**: out-of-range values sent by the guest (the monitor’s percentages, the sizes and progress of Ollama models) used to crash the app, and every running VM with it. They’re now capped before they’re shown.
- **Chat and console no longer freeze the app**: a local chat reply or console output crafted to slow Nido down is read in chunks and in linear time, without holding up the other VMs. Chat replies also have a size limit.
- **The update address is always Nido’s own**: a value left in the app’s preferences can no longer replace it. Updates were signed either way.

## [0.7.6] – 2026-11-10

### Images
- **`nido image check` shows the Debian build** it checked, for example `debian-13: up to date (build 20261103-2651)`; `nido image update` tells you which build it downloaded.
- **`nido image reset <id>`** forgets the build and signature already accepted for an image, after you confirm. You only need it if Nido keeps rejecting a list as “older than the one already accepted”; the rejection message now points to it instead of a file to delete by hand. The image in the cache stays.

### Controlled Network
- The Network tab’s **Turn Off** suggestion and the count of hidden local noise lines are now covered by a UI test.

## [0.7.5] – 2026-11-10

### Controlled Network
- **The Network tab offers to turn off background requests** in Linux VMs created before Nido 0.7.4: **Turn Off** stops them right away (with the VM running), and **Not Now** stops asking for that VM. The option is still in Settings › Guest Tools.
- **The Network tab says how many lines of local noise it hides** (IPv6 multicast and link-local, broadcast) and how to see them with `nido net log --all`.

### Images
- **Debian: checked builds.** Nido also reads the build manifest Debian publishes next to the image, and rejects inconsistent files or a build older than the one already accepted, before downloading. Debian doesn’t sign its cloud images: this isn’t a signature, but it stops an old copy from being served again.
- **Ubuntu: ready for a key change.** Nido can accept both the current signing key and the one announced as its successor, so a key change doesn’t block downloads.

### VM Window
- The compact toolbar (the **More** menu) is now covered by a UI test: in a narrow window, Pause and Stop stay visible and the items in More work.

## [0.7.4] – 2026-11-10

### A Cleaner Controlled Network
- **Debian no longer looks for changelogs online**: every hour, `apt-listchanges` tried to download them from `metadata.ftp-master.debian.org` (the cloud image doesn’t include them), and the log filled up with blocks. New Linux VMs have it turned off; for VMs created earlier, use **Settings › Guest Tools › Background requests · Turn Off**.
- **Local noise no longer shows up in the log**: IPv6 multicast and link-local announcements (`ff02::…`) and broadcasts from the VM’s network interface, which never leave the VM, are no longer printed by `nido start` or shown in the Network tab. `nido net log` says how many lines it hid; `nido net log --all` shows them.

### Ubuntu Images
- **A checksum list signed before the last one already accepted is rejected**: anyone serving an old (but signed) list to hold the cache on an earlier build is stopped before the download.
- **If Ubuntu changes its signing key**, Nido says so (“signed with a key Nido doesn’t know”, with the key ID) instead of a generic “invalid signature”.

### VM Window
- **In a narrow window**, the buttons that don’t fit (Suspend, Snapshots, Settings, Terminal Access, Enter Full Screen) move to the **More** menu; Pause, Resume, Start and Stop always stay visible.

## [0.7.3] – 2026-11-10

### Settings While the VM Is Running
- **The Settings button is there even while the VM is running**, in the VM window and on its card in the library. CPU and memory stay locked until the VM is stopped; the actions inside the VM (Guest Tools, **Background requests · Turn Off**) are meant to be used while it runs.

## [0.7.2] – 2026-11-09

### Ubuntu Images: Signature Verified
- **Nido verifies Ubuntu’s signature on the checksum list** (`SHA256SUMS.gpg`) before using it, both when downloading and with `nido image check`. Ubuntu’s key is built into Nido; you don’t need `gpg`. If the signature is missing or doesn’t match, Nido doesn’t download the image. The Download step says so: “SHA-256 checksum · Ubuntu signature”.
- Debian doesn’t publish a signature for its cloud images: for Debian, Nido still verifies the checksum over HTTPS.

### A Cleaner Controlled Network
- **apt’s SRV queries are turned off in every new Linux VM**, Debian included (they used to show up in the log as blocks on every `apt update`).
- **VMs created earlier**: VM Settings › Guest Tools › **Background requests · Turn Off** applies the same settings over SSH while the VM is running. On Ubuntu, it also turns off snap, news, Ubuntu Pro and the new-release check.
- Also tested live on Ubuntu 24.04.

### Fixes
- Image cache: if the new image can’t be saved, its new checksum no longer stays next to the old image, and a cache check that overlaps a download of the same image no longer downloads it a second time.

## [0.7.1] – 2026-11-09

### A Quieter Ubuntu on the Controlled Network
- New Ubuntu VMs no longer try to reach snap (`api.snapcraft.io`), the news in the login message (`motd.ubuntu.com`), Ubuntu Pro (`contracts.canonical.com`), the new-release check (`changelogs.ubuntu.com`) or `entropy.ubuntu.com`, and apt no longer asks for SRV records: the network log no longer fills up with blocks. Packages, security updates and the clock work as before.
- To turn them back on in the VM: `sudo systemctl unmask snapd.service snapd.socket snapd.seeded.service` (and the same for the other units), then allow the domain from the Network tab.
- Ubuntu VMs created earlier don’t change.

### Fixes
- **Safer qcow2 images**: a qcow2 that uses the same cluster twice, or that describes far more data than the file contains, is rejected before anything is written to the disk. This only affects `--image-file` with specially crafted files; Ubuntu’s images work as before.

## [0.7.0] – 2026-11-09

### Images: New Builds
- **Nido tells you when Debian or Ubuntu publishes a new build** of an image already in the cache (usually with security fixes). Until now, the downloaded copy stayed the same forever, with no notice.
- In the New VM wizard, Download step: when the image is already in the cache, there’s **Check for a New Build**. If there is one, the Download button fetches it, verifies it and replaces the old one.
- From Terminal: `nido image list` (catalog and cache, no network), `nido image check [id]` and `nido image update <id>`.
- The check downloads only the checksum list, never the image, and runs only when you ask. Existing VMs don’t change.

### Fixes
- **`nido ssh` uses the key the VM was created with.** For a VM created with a key other than the default ones in `~/.ssh`, it answered “Permission denied (publickey)”. It also works when the private key lives only in an agent (a password manager, for example). A `-i` after `--` is still tried.

## [0.6.0] – 2026-11-03

### Controlled Network: Back by Default
- **New VMs start on the controlled network again** (Linux and macOS), and it now also works with IP forwarding turned off on the Mac, which is the macOS default. The 0.5.1 warning about IP forwarding is gone: Nido no longer reads or changes `net.inet.ip.forwarding`.
- Behind the scenes, each controlled VM has its own `gvproxy`, a small third-party program that does the NAT instead of vmnet. Nido’s filter still decides first, for every packet. If `gvproxy` doesn’t start or stops, the VM is left without a network and Nido tells you: never Apple’s NAT in its place.
- `gvproxy` (gvisor-tap-vsock 0.9.0, Apache-2.0) is the only third-party program inside Nido: its version and checksum are pinned, it’s never downloaded while the app is running, and it carries Nido’s signature. Licenses and notices are in the app. To a firewall on the Mac, allowed traffic goes out as `gvproxy`.
- **SSH on `127.0.0.1`**: `nido ssh`, `nido ip` and the app’s SSH commands reach a controlled VM through a local port (it changes at every start; the host key is still recognized). The VM always has the address `192.168.127.2`. VMs on Apple’s NAT don’t change.
- **Removing a domain really closes the VM’s open connections**: the relay used to cut them without the VM knowing, and a download in progress would hang; now the VM gets a reset and the program fails right away.
- **Base list for macOS**: new macOS VMs start with Apple’s servers for activation, update checks and the clock (`albert`, `gdmf`, `mesu`, `swscan`, `swdist`, `time` on `apple.com`) instead of an empty list: Setup Assistant gets to the desktop and `softwareupdate --list` works. To download an update, you also need `updates.cdn-apple.com` and `updates-http.cdn-apple.com`; Apple ID, iCloud and the App Store still have to be allowed by hand.
- **“Type in VM” now types Shift characters correctly** (such as `$` and `"` on a German keyboard): before, they reached the macOS VM without Shift.
- If a controlled VM from 0.5.x was suspended, it starts from scratch (the saved state isn’t compatible).
- **Debian VMs from 0.5.0 without the first-boot packages**: Nido doesn’t install them afterwards (cloud-init installs them only at first boot). With the VM running and online (`deb.debian.org` is on the base list), install them over SSH: `nido ssh <vm> -- sudo apt-get update`, then `nido ssh <vm> -- sudo apt-get install -y ca-certificates curl wget git python3 python3-venv python3-pip openssh-server iproute2 procps util-linux jq tar zstd`. Or create the VM again.

## [0.5.1] – 2026-11-02

### Ubuntu Server
- **Ubuntu Server 26.04 LTS and 24.04 LTS** as systems for Linux VMs, alongside Debian 13: in the New VM wizard (the Ubuntu Server tile, where you choose the version) or with `nido create --image ubuntu-26.04` / `ubuntu-24.04`.
- The images come from `cloud-images.ubuntu.com` and are verified with SHA-256 before use.
- Ubuntu publishes arm64 images only in qcow2 format: Nido converts them to a sparse disk by itself, with no external tools. This also applies to a local image with `--image-file`.
- The library and `nido list` show each VM’s distribution.
- Guest Tools can be installed on Ubuntu too.
- Controlled network base list for Ubuntu: `archive.ubuntu.com`, `security.ubuntu.com`, `ports.ubuntu.com`, plus Ollama and `time.cloudflare.com`. The clock of new Ubuntu VMs syncs with `time.cloudflare.com`.

### Controlled Network: Now a Choice
- **New VMs start on Apple’s NAT.** With 0.5.0, a new VM on the controlled network couldn’t reach any site, not even the allowed ones, on a Mac with default settings: the controlled network only works with the Mac’s IP forwarding turned on (`net.inet.ip.forwarding`), and it’s usually off. `docs/SECURITY.md` explains why.
- Turn on the controlled network in the VM’s settings, Network section. New Linux VMs already have the base list ready; macOS VMs have an empty list.
- If IP forwarding is off, the confirmation for turning on the controlled network says so, and every start of a controlled VM shows a warning (`nido start` too). Nido reads the setting but doesn’t change it.
- VMs created with 0.5.0 stay on the controlled network: if they can’t reach the internet, turn it off in the VM’s settings. A Debian VM created without a network didn’t install the first-boot packages.

## [0.5.0] – 2026-10-29

### Controlled Network for VMs
- **New VMs reach the internet only for allowed domains.** Nido sits on the VM’s “network cable”: it answers the VM’s DNS queries and lets through only connections to the addresses it resolved for a domain on the list. Everything else is blocked: addresses never looked up by name, DNS to other servers, IPv6, ICMP, the Mac’s services (SSH from the Mac to the VM still works).
- Base list for Linux VMs: `deb.debian.org`, `registry.ollama.ai` and Ollama’s model storage, `time.cloudflare.com`. Existing VMs stay on Apple’s NAT until you turn on the controlled network in the VM’s settings, Network section.
- If the controlled network doesn’t start, the VM is left without a network and Nido tells you: never the NAT in its place.
- **Notices**: every block arrives as a Nido notification, with the VM, the destination and the port; repeated blocks are combined into one notice with a count. With the app closed, `nido start` writes a line in Terminal and the app shows the notices at its next launch. Network noise at startup (local IPv6, broadcast) stays in the log only.
- **Allow** in the notice adds the domain to the list, with Touch ID or the Mac password, and takes effect right away, without restarting the VM. Removing a domain asks for nothing and cuts its open connections right away; turning off the controlled network also asks for Touch ID.
- Network log in the VM window (Network tab) and with `nido net log`: time, domain, address, port, bytes, outcome. Never the content of the traffic.
- `nido net list|allow|deny|reset` manages the list from Terminal; `allow` and `reset` ask for Touch ID.
- **TLS name check**: an HTTPS connection to an allowed address that names a site that isn’t allowed on the same CDN is cut, and “Allow” offers that name. It’s an extra check, not a complete one (QUIC and some browsers aren’t covered: see `docs/SECURITY.md`).
- **macOS VMs**: they get the controlled network too, but with an empty list: macOS can’t reach Apple services (activation, updates, App Store, iCloud) until you allow them. If Setup Assistant stops at activation, add `albert.apple.com` or turn off the controlled network for Setup Assistant.
- VMs created or changed with this version don’t open in earlier versions of Nido.

### Nido Guest Tools 1.4.0
- The Mac downloads the Ollama archive (pinned version and SHA-256) and sends it into the VM (`--archive-stdin`): the VM never contacts GitHub. The AI view shows the download on the Mac, with Cancel.
- The archive stays in `~/Library/Caches/Nido/ollama`; old versions aren’t deleted automatically.
- The clock of new VMs syncs with `time.cloudflare.com`.
- To install Ollama in an existing VM, you need Guest Tools 1.4.0: reinstall them from the VM’s settings.

## [0.4.0] – 2026-10-27

### macOS VMs
- **Create a macOS VM from an IPSW file** of your choice (Nido downloads nothing and leaves the file untouched): in the New VM wizard or with `nido create --ipsw`. Before creating any file, Nido checks that the image suits this Mac.
- Installation takes 4 to 20 minutes, depending on the Mac and the disk, with progress and Cancel; if it’s interrupted, no half-made VM is left behind.
- The VM window shows the macOS screen. Closing the window should leave the VM running (not yet verified).
- **Terminal Access**: a panel guides you through turning on Remote Login and authorizing your key; **Type in VM** types the command into the guest’s Terminal (without pressing Return). Then `nido ssh` signs in with the account you entered when creating the VM. Tested live with macOS 26.6.2 (German keyboard): the command uses `"$HOME"` instead of `~`, which on some keyboards needs a dead key.
- Suspend, snapshots of a stopped VM, restore and clone also work for macOS (tested with a real IPSW); snapshots of a running VM from the app aren’t verified yet; a clone gets a new identifier and shows the steps to take once in the copy (SSH host keys and computer name).
- Shared folders (read-only by default, in `/Volumes/My Shared Files`) and audio output are set up but not yet verified in the guest. No shared clipboard or microphone.
- Guest Tools, the monitor, provisioning, Ollama, the AI bridge and VM templates remain Linux-only.

### Linux and the App
- An interrupted first boot of a Linux VM no longer leaves it without SSH access: missing host keys are regenerated at every start.
- If you quit Nido during the first minute of a first boot, the app warns you.
- `nido list` shows the SYSTEM column.

## [0.3.1] – 2026-10-26

### Chat with Local Models
- Web links in replies open in the browser; addresses that hide their destination, addresses that point to the Mac itself and any other kind of address stay plain text.
- Each reply shows the model that wrote it.
- **Clear Chat** asks for confirmation before the conversation is lost.
- If Ollama is stopped, the chat tells you to start it with **Start**.

### Security and Reliability
- The AI bridge closes with the VM: when you stop or suspend the VM, Hugging Face requests in progress are canceled right away and use no more budget.
- Hugging Face errors reach the VM without any of your account data: only the code and a fixed explanation.
- Each VM’s SSH key is tied to the VM, not to its address: if the address changes, Nido requires the same key.
- Bridge connections that are waiting no longer tie up threads on the Mac.

### Nido Guest Tools 1.3.0
- The services in the VM run with tighter system restrictions.
- Updates remove the files the new version no longer uses.
- A stopped Ollama stays stopped even after the VM restarts, until you start, restart, reinstall or update it.
- Reinstall the Guest Tools from the VM’s settings to get them in existing VMs.

## [0.3.0] – 2026-10-26

### Chat with Local Models
- Replies show Markdown formatting: **bold**, *italic*, `code`, lists, headings, quotes and code blocks.
- Replies come in without flicker and the conversation follows them; if you scroll up, it stays where you are and **Go to End** appears.
- **Copy** puts a reply on the clipboard, exactly as the model wrote it.
- Below each reply: how long it took and how many tokens per second the model generated.
- You see right away when the model is preparing its reply; **Stop** (or Esc) stops it.
- The chat stays in the VM and in memory: Nido doesn’t save it on the Mac, and Ollama can’t be reached from outside.

### AI in VMs
- New Debian VMs ready to go: essential packages and Nido Guest Tools at first boot.
- Ollama and the models you choose install in the VM with one click, with verified versions and checksums.
- VM monitor: CPU, memory, disk and alerts, read from the VM without the network.
- Optional AI bridge to Hugging Face: the token stays in the Keychain, never in the VM; token and request limits for each VM, and a log with no content.
- VM templates: save a VM as a template and create new VMs from it.

### Virtual Machines
- Snapshots, suspend and resume with the memory state.
- Clone a stopped VM.
- Shared folders: none by default, read-only unless you choose otherwise, revocable at any time, even while the VM is running; clones and templates don’t inherit them.
- Rosetta to run x86-64 programs in Linux VMs.
- A warning when the memory of running VMs exceeds what the Mac can give, and automatic restart of a VM that hangs on a kernel panic.

### Terminal
- `nido --version`, `nido template` and `nido create --from-template`.

### Fixes
- Changes to a VM’s configuration made at the same time from the app and from Terminal no longer undo each other.
- The AI bridge frees its connections when the Mac closes its end (Guest Tools 1.2.1: reinstall them in existing VMs).

## [0.2.0] – 2026-10-23

### First Version of the App
- VM library with live status.
- New VM wizard for Debian VMs.
- VM window with screen, serial console, pause and resume.
- VM settings and Nido settings.

## [0.1.0] – 2026-10-23

### The `nido` Command
- `nido create`, `list`, `start`, `stop`, `ip`, `ssh` and `delete`.
- Debian images downloaded only from approved sources and verified with SHA-512.
- Access to VMs with an SSH key only.
