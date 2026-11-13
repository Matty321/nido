# The `.nidovm` bundle format (schema version 5)

Every Nido virtual machine lives in a `<name>.nidovm` directory inside the VM root.
Directories created by Nido have permissions `0700`, files `0600`.

Labels such as M3a or M3c name Nido's development milestones: M1 the `nido` command (0.1.0); M2 the app (0.2.0); M3a suspend, snapshots, cloning, shared folders and Rosetta, and M3c the Guest Tools, the monitor, templates and the AI bridge (both 0.3.0); M3b macOS VMs (0.4.0); M3d the controlled network (0.5.0); M4 Developer ID signing and updates (0.8.0).

## Locations

- VM root: `~/Library/Application Support/Nido/VMs` (0700).
- Image cache: `~/Library/Caches/Nido/images` (0700).

## Contents

```
<name>.nidovm/
  config.json          VMConfig (see below)
  disk.img             raw disk (clonefile of the base image + extension)
  nvram.efi            VZEFIVariableStore (Linux only)
  machine-id.bin       Linux: VZGenericMachineIdentifier.dataRepresentation; macOS: VZMacMachineIdentifier.dataRepresentation
  seed.iso             (Linux only) cloud-init NoCloud (label "cidata": user-data, meta-data, network-config), attached read-only
  auxiliary-storage.img  (M3b, macOS only) the guest's VZMacAuxiliaryStorage, 0600
  hardware-model.bin   (M3b, macOS only) VZMacHardwareModel.dataRepresentation of the IPSW the VM was installed from, 0600
  authorized_key.pub   (M3b, macOS only) SSH public key chosen at creation, to be authorized in the guest ("Terminal Access" panel), 0600; not part of the machine
  console.log          serial console output (at most 16 MiB)
  console.log.1        previous generation of console.log (rotation)
  known_hosts          the VM's SSH host keys (used by `nido ssh`)
  ai-bridge-usage.json (M3c, optional) AI bridge tokens charged today: `{"day": "2026-10-24", "tokens": 1234}` (local calendar day), 0600
  ai-bridge.log        (M3c, optional) log of AI bridge calls, one JSON object per line, 0600, at most 1 MiB
  ai-bridge.log.1      previous generation of ai-bridge.log (rotation)
  egress.json          (M3d, optional) the controlled network's allowed domains: `{"allow": ["deb.debian.org", "*.example.com"], "v": 1}`, 0600; missing = no domains
  egress.log           (M3d, optional) the controlled network's blocks, cuts and summaries, one JSON object per line, no content, 0600, at most 1 MiB (+ `egress.log.1`)
  egress-flows.log     (M3d, optional) allowed connections, merged per destination, 0600, at most 1 MiB (+ `egress-flows.log.1`)
  .egress.lock         flock for changes to `egress.json`; never copied
  .suspend-result      (M3a, optional) why `nido start` couldn't suspend (read and removed by `nido stop --suspend`)
  .lock                flock; contains `<pid> <owner>` of the process holding it: `cli` (`nido start`, which runs the VM), `app` (the app) or `cli-op` (a `nido` maintenance command: snapshot, clone, share, rosetta, delete; since M3a); a line with only the PID, or an unknown owner, belongs to `cli`
  .config.lock         (M3c) flock that serializes every write of config.json (app and `nido`), 0600, empty, never removed
  state.vzvmsave       (M3a, optional) the machine's saved state (suspended VM or restored snapshot)
  snapshots/           (M3a) 0700
    <uuid>/            one complete snapshot (0700)
      meta.json        Snapshot (see below), 0600
      disk.img         clonefile of the disk, 0600
      nvram.efi        clonefile of the NVRAM, 0600 (Linux)
      auxiliary-storage.img  (M3b) clonefile of the auxiliary storage, 0600 (macOS)
      state.vzvmsave   only for a snapshot with saved state (VM running or suspended), 0600
    .<uuid>.partial/   snapshot being built (ignored by listing and restore)
    .<uuid>.deleting/  snapshot being deleted
  .config.json.<uuid>.tmp            atomic write of config.json in progress
  .<file>.restore-<tag>.new / .old   (M3a) copies and originals of a restore in progress (see "Snapshots")
  .restore-<tag>.commit              (M3a) marker of a committed restore
```

**Inner files per system** (`VMBundle.innerFileURLs(for:)`, checked with `lstat` by `verifyInnerFiles(for:)` before they are passed to Virtualization.framework: regular files, not symbolic links, owned by the user, with a single link): Linux `config.json`, `disk.img`, `nvram.efi`, `machine-id.bin`, `seed.iso`; macOS (M3b) `config.json`, `disk.img`, `auxiliary-storage.img`, `hardware-model.bin`, `machine-id.bin`, without `seed.iso` or `nvram.efi`. In both cases also `state.vzvmsave` if present.

In the root, besides the bundles: `.<name>.deleting-<uuid>/` (VM being deleted), `.<name>.cloning-<uuid>/` (clone being built) and `.creating-<uuid>/` (M3b: macOS VM being installed), all ignored by listing and opening.

**macOS installation** (M3b, `MacInstaller`): before any file is created in the root, Nido checks the SSH user, the key, the resources, the IPSW (`MacRestoreImage.inspect`, again), the image's CPU and memory minimums, that the name is free (case-insensitively) and the free space (disk + 2 GiB). Then, in `<root>/.creating-<uuid>/` (0700, `.lock` held for the whole installation), it creates `disk.img` (sparse), `auxiliary-storage.img` (`VZMacAuxiliaryStorage(creatingStorageAt:hardwareModel:options: [])`), `hardware-model.bin`, `machine-id.bin` (a new `VZMacMachineIdentifier`), `authorized_key.pub` and `config.json` (`guest: macos`, `sshUser`, `osVersion`, `minimumCPUCount` and `minimumMemoryBytes` from the IPSW; no M3c features); `VZMacOSInstaller` installs macOS, and only when the work is done does the folder become `<name>.nidovm`, with `renamex_np(RENAME_EXCL)`. Cancellation (the installer's `progress` is canceled) or an error: the folder is removed. Before the installer starts, `lstat` checks again that the IPSW is still a regular file; before the rename, `disk.img` and `auxiliary-storage.img` are written to disk with `F_FULLFSYNC`. A `.creating-` folder left by a crash is removed when its `.lock` is free and neither the folder nor the files inside it have changed for more than 2 minutes; with the `.lock` held (installation in progress), it is never removed.

## `config.json`

JSON with sorted keys, written atomically.

| Field | Schema | Meaning |
|---|---|---|
| `schemaVersion` | 1 | `2` since M3a, `3` since M3c, `4` since M3b, `5` since M3d |
| `id`, `name`, `guest` | 1 | UUID, VM name, `linux` or (schema 4) `macos` |
| `cpuCount`, `memoryBytes`, `diskBytes` | 1 | resources |
| `macAddress` | 1 | MAC of the NAT interface |
| `clipboardSharing` | 1 | shared clipboard (false) |
| `sharedFolders` | 2 | list of `{ name, hostPath, readOnly }`: Mac folders at `/mnt/nido/<name>` (VirtioFS device with tag `nido`); `name` matches `^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$` and is unique, case-insensitively; `hostPath` is the path resolved with `realpath`; `readOnly` is `true` unless explicitly chosen otherwise |
| `rosetta` | 2 | Rosetta for x86_64 binaries (false) |
| `suspendedConfigHash` | 2 | optional: `stateHash()` of the configuration `state.vzvmsave` was saved with |
| `guestMountsSharedFolders` | 2 | true if the VM's cloud-init installs `nido-shares.service`, which mounts `/mnt/nido` (VMs created since M3a); false for earlier VMs, which get the command to run once in the guest |
| `guestRegistersRosetta` | 2 | true if the VM's cloud-init installs `nido-rosetta.service` (mounts `/media/rosetta` and registers Rosetta with binfmt_misc); false for earlier VMs, which get the command from `nido rosetta enable` and from the app |
| `provisioning` | 3 | optional: `{ essentialPackages, guestTools }`, what phase 1 of cloud-init was asked for at creation (missing = no profile) |
| `guestToolsVersion` | 3 | optional: version of the Guest Tools written to the seed or installed over SSH (missing = not installed) |
| `sshPublicKeyPath` | 3 | optional: path of the `.pub` public key authorized in the guest at creation |
| `isTemplate` | 3 | true if the VM is a template to clone from (false) |
| `aiBridge` | 3 | optional: the remote AI bridge policy `{ enabled, allowedModels, tokensPerDay, requestsPerMinute, maxTokensPerRequest, privacyAcknowledged }` (missing = bridge off; missing fields take the defaults: off, no models, 200,000 tokens per day, 20 requests per minute, `max_tokens` 4,096, notice not seen); not part of `stateHash()` |
| `pendingProvisioning` | 3 | optional: phase 2 as chosen in the wizard and not yet verified, `{ ollama, model }` (`model` optional, a single model); the app resumes it when the guest answers and removes it after a successful check or with "Don’t Install"; never passed to cloud-init; not inherited by clones and by VMs created from a template; not part of `stateHash()` |
| `sshUser` | 4 | optional: the guest account `nido ssh` signs in with (macOS: the account the user creates in Setup Assistant, given at creation and editable); matches `^[a-z_][a-z0-9_-]{0,31}$`; missing = `nido`, the account cloud-init creates on Linux |
| `osVersion` | 4 | optional: the macOS version installed in the guest, read from the IPSW (`"26.1"`, or `"26.0.1"` with a non-zero patch); missing for Linux VMs |
| `sshSucceeded` | 4 | optional, macOS only: `true` after the first `nido ssh` that reached the guest (ssh ended normally with a code other than 255); the app doesn't reopen the "Terminal Access" panel on its own when it is `true`. Not written while missing; **not part of `stateHash()`** (a suspended state stays resumable); **not** inherited by clones (cleared: the clone needs new host keys) |
| `minimumCPUCount` | 4 | optional, macOS only: the minimum CPU count the installed image supports, read from the IPSW at installation. Settings don't go below this value; missing (VMs installed before it was recorded) = 2. **Not part of `stateHash()`**; inherited by clones |
| `minimumMemoryBytes` | 4 | optional, macOS only: the minimum memory (bytes) the installed image supports, like `minimumCPUCount`; Settings round it up to the GiB and don't go below it; missing = 4 GiB. **Not part of `stateHash()`**; inherited by clones |
| `controlledNetwork` | 5 | true: the VM's network goes through Nido's relay and reaches only the domains in `egress.json`; if the relay doesn't start, the VM stays without a network (never Apple's NAT). False: Apple's NAT without filters. True for Linux VMs created since M3d (`VMFactory`, with `EgressPolicy.base` as `egress.json`) and for macOS VMs created since M3d (`MacInstaller`, with `EgressPolicy.macOSBase` as `egress.json` since 0.6.0; empty before); missing (schemas 1–4) = false. Part of `stateHash()` only when true |

The M3c features (`provisioning`, `guestToolsVersion`, `isTemplate`, `aiBridge`, `pendingProvisioning`) are Linux only: in a macOS VM they stay missing or false.

`stateHash()` is the hexadecimal SHA-256 of the sorted-key JSON encoding of `cpuCount`, `memoryBytes`, `macAddress`, `sharedFolders` and `rosetta`, plus `controlledNetwork` only when it is true (M3d: a VM on the NAT keeps its earlier hash, and its saved state resumes; a state saved on the NAT doesn't resume on the relay, nor the other way around). `guestMountsSharedFolders` and `guestRegistersRosetta` aren't part of it. The saved state uses the `attachedStateHash` variant (only the folders actually attached at start, Rosetta only if the device was attached).

### Migration

- A schema 1 `config.json` is read with the defaults of the schema 2 fields (`sharedFolders` empty, `rosetta` and `guestMountsSharedFolders` false, no hash) and keeps `schemaVersion: 1` until it is rewritten: reading alone never changes it.
- A schema 1 or 2 `config.json` is also read with the defaults of the schema 3 fields (`provisioning`, `guestToolsVersion`, `sshPublicKeyPath`, `aiBridge` and `pendingProvisioning` missing, `isTemplate` false).
- A schema 1, 2 or 3 `config.json` is read as a Linux VM without the schema 4 fields (`sshUser` and `osVersion` missing) and isn't rewritten just to read it.
- A schema 1–4 `config.json` has no `controlledNetwork` and is read as false: migration never puts an existing VM on the controlled network. At the first write, the field is written explicitly as false.
- Every write (`VMBundle.writeConfig`) writes the current schema (5) after `VMConfig.validate`.
- A schema higher than the known one (or lower than 1) is refused (`unsupportedSchema`). So a version of Nido earlier than M3d doesn't read a schema 5 VM: it can't start it on the NAT or rewrite its config without `controlledNetwork`.
- Missing `guestMountsSharedFolders` and `guestRegistersRosetta` count as false: a VM created before M3a doesn't have the units in the guest and gets the command to run once.

## Snapshots

`meta.json` (JSON with sorted keys, ISO 8601 dates, at most 64 KiB, read without following symbolic links):

| Field | Meaning |
|---|---|
| `id` | UUID, same as the folder name |
| `name` | same rules as a VM name, unique per VM, case-insensitively |
| `createdAt` | creation date |
| `hasSavedState` | true if the folder contains `state.vzvmsave` (snapshot of a running VM, or of a suspended one) |
| `configHash` | for a saved state: the hash of the machine actually running (`VMSession.attachedStateHash`: `stateHash()` with only the shared folders actually attached and Rosetta only if the device was attached; for a suspended VM, its `suspendedConfigHash`); otherwise the configuration's `stateHash()` (for information) |

- **Creation** (`SnapshotStore.create`): while the VM is stopped, under the bundle lock (`cli-op` for `nido snapshot create`, `app` for the app). A VM running in another process is refused ("the VM is running in another process: use the app, or stop it"); only the process that runs it (the app, through the session) can snapshot it while it runs: pause → `saveMachineStateTo` → `clonefile` of the machine files → resume (also on error), after `validateSaveRestoreSupport` (otherwise `snapshotUnsupported`). The snapshot of a **suspended** VM (stopped, with a valid saved state: the bundle's `hasSavedState`) also includes its `state.vzvmsave` (cloned like the other files, 0600), with `hasSavedState` true and `configHash` = `suspendedConfigHash`: once restored, the next start resumes the suspended session instead of starting from a disk stopped halfway. Everything happens in `snapshots/.<uuid>.partial/` (0700, files 0600), renamed to `snapshots/<uuid>/` only when the work is done; on any error the partial folder is removed.
- **Free space**: before starting, `volumeAvailableCapacityForImportantUsage` of the bundle's volume is checked. On a volume that supports `clonefile` (APFS), cloning takes no space right away: only the 2 GiB margin is needed (+ the VM's memory as an estimate of the saved state, for a snapshot of a running VM). On a volume that doesn't clone, the allocated space (`st_blocks`) of the machine files is added, because the fallback copy is sparse. The same applies to restore.
- **Machine files** (`SnapshotStore.machineFileNames(for:)`, according to the config's `guest`): Linux `disk.img` and `nvram.efi`; macOS (M3b) `disk.img` and `auxiliary-storage.img`, because a disk without the auxiliary storage it was written with doesn't boot. A macOS VM's `hardware-model.bin` and `machine-id.bin` never change: the bundle's stay. The bundle's files are checked with its system's `verifyInnerFiles(for:)` (there is no default "Linux" check); a restore first checks that the snapshot contains all the machine files of its system, and otherwise is refused without touching anything.
- **Writing to disk**: before they are cloned, the machine files are opened read-only and synced (`fsync`), so the clone contains everything Virtualization.framework has already written to the file. Residual risk, for a snapshot of a running VM: writes that the paused guest issued and that the framework still holds internally aren't covered (no API flushes them); the saved state includes the guest's cache. After every rename, the folder involved is synced.
- **Restore** (`SnapshotStore.restore`): only while the VM is stopped (lock available); otherwise refused without touching any file. Order "invalidate first, commit last":
  1. the snapshot's files are cloned next to the bundle's (`.<file>.restore-<tag>.new`);
  2. `suspendedConfigHash` is cleared in `config.json`, and the bundle's `state.vzvmsave`, if any, is moved aside (`.state.vzvmsave.restore-<tag>.old`): from here on, no saved state can be resumed;
  3. `disk.img` and then `nvram.efi` (Linux) or `auxiliary-storage.img` (macOS) are moved aside (`.old`) and replaced by the copies, then the snapshot's state (if any) becomes `state.vzvmsave`;
  4. the `.restore-<tag>.commit` marker is written;
  5. `config.json` gets `suspendedConfigHash` = the snapshot's `configHash` (none without a saved state);
  6. the `.old` originals and the marker are removed.
  An error (exception) before the end puts the originals back, syncs the bundle folder and only then rewrites the previous configuration, then removes the copies. If putting an original back fails, nothing is deleted and the error names the file kept (`restoreIncomplete`). If, after the restore is committed (marker written), the marker can't be removed, nothing is rolled back: the VM stays at the snapshot with no state to resume, and the error says so (`restoreMarkerKept`).
- **Creation, final sync**: if syncing `snapshots/` fails after the rename to `snapshots/<uuid>/`, the snapshot exists: creation succeeds with a warning.
- **Interruptions** (crash, power loss): at no point is a resumable saved state left on a different disk, because the hash is cleared before the files are touched and set again only at the very end. The next operation that takes the lock (`SnapshotStore.recoverBeforeUse`: creation, restore, starting the VM from `nido start` and from the app) completes a restore that has a marker (removes `.old`, `.new` and the marker) and rolls back one without a marker (renames every `.old` onto its file, removes the `.new` copies); in that case the suspended state from before the restore stays unusable (cold boot). It also removes the `snapshots/.<uuid>.partial` and `.deleting` folders. If a `.restore-*` file remains after recovery (an original that couldn't be put back, a copy or a marker that couldn't be removed), the operation is refused (`restoreLeftovers`) with the list of files to check: none of them is deleted. The next start resumes from the saved state only if the hash matches that of the machine that starts; otherwise it discards the state with a warning and cold-boots (also if Virtualization.framework rejects the state: `NidoError.restoreFailed`).
- **Deletion** (`SnapshotStore.delete`): while the VM is stopped, first renaming the folder to `.<uuid>.deleting`.
- **Controlled network** (M3d): a snapshot contains neither `egress.json` nor the network logs, just as it doesn't contain `config.json`. A restore keeps the current list: it never brings back a domain removed after the snapshot.
- A `meta.json` with a name that breaks the rules (for example, control characters) is ignored.
- `state.vzvmsave` is protected by a key tied to this Mac: it can be restored only here.

## Suspend

- **macOS** (M3b): same rules; `validateSaveRestoreSupport` decides whether the guest's state can be saved; otherwise suspending is refused with the reason and no state is written. A macOS machine never has the Rosetta device, so a `rosetta` flag in the config doesn't go into the hash that decides whether to resume.
- **Suspend** (`VMSession.suspend`: "Suspend" in the VM window, "Suspend and Quit" when quitting the app, `nido stop --suspend`): only while the VM is running or paused, in the process that runs it and holds the lock. First `validateSaveRestoreSupport` (otherwise refused without touching anything), then pause → `saveMachineStateTo` on `state.vzvmsave` (an earlier file is removed; 0600, checked with `PrivateFile` and synced) → `suspendedConfigHash` = `VMSession.attachedStateHash` in `config.json` → stop (forced at once: the VM is paused and the guest writes nothing more). An error before the hash removes the state and resumes the VM; if the stop fails, the hash is cleared and the state removed.
- `nido stop --suspend <vm>` sends `SIGUSR1` to the `nido start` process that holds the lock (owner `cli`; a maintenance command, `cli-op`, receives no signals: `nido stop` and `nido stop --suspend` answer at once "an operation on <vm> is in progress (pid N): try again when it’s done"), which suspends the VM and exits; it waits (up to 5 minutes) for the lock to be released and says whether the VM is suspended. If the process can't suspend (VM not started yet or already stopping, a configuration that can't be saved, saving failed), it answers at once by writing the reason to `.suspend-result` (0600, `PrivateFile`), which `nido stop --suspend` reads, shows and removes. A stop requested during the suspend is carried out if the suspend fails. A VM in the app is refused as for `nido stop`.
- **Stop while resuming**: a stop requested while the state is being restored (Ctrl-C or `nido stop` for `nido start`, Stop or quitting in the app) isn't lost: `VMSession` keeps it and, once the restore is done, stops the paused machine instead of resuming it (the guest doesn't run again); if the restore fails, it doesn't cold-boot. The state, consumed by the restore, is discarded. `nido stop --suspend` during the resume answers at once that the VM is resuming.
- **Start** (`VMSession.startOrResume`, after `recoverBeforeUse`): with `state.vzvmsave` a regular, non-empty file owned by the user with a single link, and `suspendedConfigHash` equal to the `attachedStateHash` of the machine that starts, the hash is cleared, the state restored, the file removed and the VM resumed. In every other case (invalid state file; a different hash: "The suspended state was discarded because the configuration changed"; a state without a hash; a hash without a state; Virtualization.framework rejecting the state, for example one from another version of macOS, with the reason), the hash is cleared, the state removed and the VM cold-boots with the warning (in the terminal for the CLI, in the window's bar for the app).
- `nido list` shows `suspended`, and the app shows the "Suspended" card (Resume, Settings), for a stopped VM with `suspendedConfigHash` and a regular, non-empty `state.vzvmsave`.

## Cloning

`VMCloner.clone` (`nido clone <source> <new-name>`, "Clone…" in the card's menu in the app):

- **Only while the VM is stopped** (suspended included): the source's lock (`cli-op` or `app`) is held for the whole copy; a running VM, here or in another process, is refused ("stop it before cloning it"). Under the lock, `SnapshotStore.recoverBeforeUse` runs (leftover `.restore-*` files → refused) and the bundle's files are checked.
- **Before starting**: a name already in use (case-insensitively, the source's included) → refused; free space as for snapshots (2 GiB margin; plus the allocated space of the machine files on a volume that doesn't clone). The source's files are checked with its system's `verifyInnerFiles(for:)`.
- **Building**: in `<root>/.<new-name>.cloning-<uuid>/` (0700, ignored by listing and opening), renamed to `<new-name>.nidovm` with `renamex_np(RENAME_EXCL)` only when the work is done; on any error, and when the task is canceled (quitting the app with "Cancel and Quit": the check happens between one step and the next, up to but not including the rename), the folder is removed and the source stays intact. A `.cloning-` folder left by an interruption is removed like the tombstones when neither the folder nor the files inside it have changed for more than an hour.
- **Contents** (Linux): `disk.img` and `nvram.efi` synced and cloned (`clonefile`, sparse fallback copy); `config.json` with a new `id`, the name, a new MAC (`VZMACAddress.randomLocallyAdministered`), without `suspendedConfigHash`; a new `machine-id.bin` (`VZGenericMachineIdentifier`); a new `seed.iso` with the source's `user-data` (read from its `seed.iso`) plus `ssh_deletekeys: true` and a `bootcmd` that, only once per instance (`cloud-init-per instance nido-machine-id`), regenerates `/etc/machine-id` (cloud-init doesn't change it: without this, clone and source would have the same one), plus (if missing) the every-boot `bootcmd` `ssh-keygen -A` that recreates missing SSH host keys (M3b: an interrupted first boot doesn't leave the guest without SSH; new Linux VMs have it too, while the `seed.iso` of existing VMs doesn't change), a new `instance-id`, `local-hostname` = the new name and `network-config` on the new MAC. With the new `instance-id`, cloud-init runs the per-instance modules again at first boot: host name and new SSH host keys.
- **macOS** (M3b): no `seed.iso` (nothing runs in the guest at first boot). `disk.img`, `auxiliary-storage.img` and `hardware-model.bin` synced and cloned, `authorized_key.pub` copied if present; a new `machine-id.bin` (`VZMacMachineIdentifier`) and a new MAC; `sshUser`, `osVersion`, `minimumCPUCount` and `minimumMemoryBytes` stay. With the new `id`, the SSH alias `HostKeyAlias=nido-<id>` is new too, and `known_hosts` isn't copied. What only the guest can change is returned by `VMCloner.cloneReportingNotes` as `cloneNotes` (`VMCloner.cloneNotes(guest:name:)`, empty for Linux) and shown by `nido clone`: new SSH host keys (`sudo rm /etc/ssh/ssh_host_* && sudo ssh-keygen -A`) and names (`sudo scutil --set ComputerName <name>`, `LocalHostName` and `HostName` with `.` and `_` replaced by `-`). There are no macOS VM templates (rule R4): `createFromTemplate` refuses a macOS source even if it was marked by hand.
- Copied as they are: CPUs, memory, disk size, Rosetta, `guestMountsSharedFolders`, `guestRegistersRosetta`. Not inherited: shared folders (`sharedFolders` empty) and the AI bridge policy (`aiBridge` missing: bridge off), as for a template; nor `pendingProvisioning`. Not copied: `snapshots/`, `state.vzvmsave` (the clone cold-boots), `known_hosts`, `console.log`, `ai-bridge-usage.json`, `ai-bridge.log`, `.lock`, `.config.lock`.
- **Controlled network** (M3d): `controlledNetwork` stays as it is, and `egress.json` is rewritten in the clone from the source's list as read at that moment (`EgressPolicyStore.load`), never copied by name. Without `egress.json` in the source, the clone has none; an unreadable or invalid file gives the clone an empty list, never a wider one. Not copied: `egress.log`, `egress-flows.log` and their rotations (the clone starts with a clean log), `.egress.lock` and the `.egress.json.*.tmp` files. The same holds for a VM created from a template.

## VM templates (M3c)

- **Save as Template** (`VMTemplates.save`: `nido template save <vm>`, "Save as Template…" in the app): only while the VM is stopped and has no suspended state, under the bundle lock; it writes `isTemplate: true` and nothing else. A template doesn't start (`VMSession` refuses it: `nido start` and the app say to use `nido create --from-template` or `nido template edit`) and can't be cloned with `nido clone`. On a template, the app and `nido` (`nido share add|remove`, `nido snapshot restore`, `nido rosetta enable|disable`) also refuse changes to shared folders and Rosetta and restoring a snapshot: "<name> is a template: use nido create --from-template or nido template edit".
- **Edit Template** (`nido template edit`, "Edit Template" in the app): sets `isTemplate` back to false; the VM can start again and, once updated, can be saved again.
- **New VM from a template** (`VMCloner.createFromTemplate`: `nido create <name> --from-template <template> [--ssh-key …]`, "From Template" in the wizard): the same construction as cloning (`.cloning-` folder, `clonefile`, new `id`, MAC and `machine-id.bin`), with `isTemplate` false; CPUs, memory, disk, `provisioning` and `guestToolsVersion` from the template. A new `seed.iso` with **the identity only** (`userDataForTemplateClone`: user `nido`, public key, `ssh_deletekeys: true`, `/etc/machine-id` regenerated once per instance, `ssh-keygen -A` at every boot; a new `instance-id`, `local-hostname` = the new name, `network-config` on the new MAC): no packages, Guest Tools or panic settings, which the template's disk already contains. The key is the template's (`sshPublicKeyPath`) unless another one is chosen, and it is saved in the new VM's config; if the template's key file is missing, creation is refused. Not inherited: `sharedFolders`, `aiBridge`, `pendingProvisioning`, snapshots, saved state, `known_hosts`, logs.

## cloud-init

The `seed.iso` of VMs created since M3a installs in the guest, with `write_files` and `runcmd` (`systemctl enable --now`), two oneshot systemd units instead of lines in `/etc/fstab`:

- `nido-shares.service`: `ExecCondition` creates `/mnt/nido` and mounts the VirtioFS tag `nido` (`nosuid,nodev`) if it isn't mounted already.
- `nido-rosetta.service`: mounts the tag `rosetta` read-only at `/media/rosetta` (`ro,nosuid,nodev`) and registers the interpreter with `systemd-binfmt /etc/nido/rosetta-binfmt.conf` (x86_64 ELF only, flag `F`).

The mount is the unit's condition: if the VM starts without that device (no shared folder, Rosetta off or not installed), the unit is skipped, with no failed units and no "degraded" system (an fstab line with `nofail` still fails if the tag is missing). For VMs created earlier, the app, `nido share` and `nido rosetta enable` show a `sudo sh -c '…'` command to run once in the guest: it writes the same files and enables the unit (`SharedFolder.legacyGuestCommand`, `RosettaSupport.legacyGuestCommand`).

**Visible panics and reboot (M3c)**: VMs created with the Guest Tools also get, through `write_files` (`root:root`, `0644`, base64), `/etc/default/grub.d/nido.cfg` (adds `console=tty0 console=hvc0` to `GRUB_CMDLINE_LINUX_DEFAULT`: kernel messages, panics included, also reach the virtio console and therefore `console.log`; without it they end up only on `tty0`, which a VM without a screen doesn't show) and `/etc/sysctl.d/90-nido.conf` (`kernel.panic = 10`, `kernel.panic_on_oops = 1`: after a panic, or an oops, the guest reboots by itself within 10 seconds instead of hanging with its virtual CPUs at 100%). At the end of `runcmd` come `update-grub` (the command line applies from the second boot) and `sysctl --system` (the values apply at once). Without Guest Tools and without a profile (`user-data` identical to before M3c), nothing changes; the seed of a VM from a template (identity only) doesn't repeat them: the template's disk already has them. Existing VMs get them only through an explicit action: `GuestCommand.applyPanicSettings` over SSH (a constant script with `sudo -n /bin/sh -c`, idempotent: it rewrites both files whole, then runs `update-grub` and `sysctl --system`), never automatically.

Clones get the source's `user-data` plus a `bootcmd` for `/etc/machine-id` (see "Cloning").

## Security rules

- The VM name matches `^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$`, `..` is forbidden; the comparison is case-insensitive (also on case-sensitive volumes).
- `config.json` is written atomically: a temporary file in the bundle with permissions `0600`, then `rename`.
- Every write of `config.json` (M3c) happens under `flock(LOCK_EX)` on `.config.lock` (opened with `PrivateFile`: 0600, no symbolic links), held from the read to the `rename` (`VMBundle.updateConfig`: reread, change, write). So two writers, in the same process or in different processes (app and `nido`), never lose a change, even while the VM is running and its process holds `.lock` (live shared folders, the AI bridge policy, `suspendedConfigHash` for suspend and restore). Lock order: `.lock` (`BundleLock`) first, then `.config.lock`, never the other way around; `.config.lock` is held only to read and write the file and, while it is held, no other lock is taken.
- A bundle that is a symbolic link, or whose resolved path leaves the root, is refused (`unsafePath`); `remove` doesn't follow symbolic links.
- A directory without `config.json` or without the `.nidovm` suffix isn't considered a VM.
- Shared folders are added, removed or changed only while the VM is stopped, under the bundle lock (`cli-op` for `nido share`, `app` for the app); the paths follow the rules in `docs/SECURITY.md` ("VM isolation"), repeated at every start.

## AI bridge (M3c)

The AI bridge's proxy (`AIBridgeProxy`) runs in the app for VMs started from the app and writes only these to the bundle:

- `ai-bridge-usage.json`: the tokens charged on the local calendar day (`AIBridgeLimiter`), rewritten atomically (a 0600 temporary file, renamed) at every charge, so the budget survives a restart; a day other than today counts as zero; an unreadable or invalid file counts as zero.
- `ai-bridge.log`: one JSON line per call `{"time", "model", "provider"?, "inputTokens", "outputTokens", "estimated", "status", "durationMs"}`; never prompts, replies, headers or tokens. Rotated at 1 MiB into `ai-bridge.log.1`.

The Hugging Face token is never in the bundle: it lives in the Mac's Keychain (generic password, service `Nido Hugging Face`, account `default`, accessible only while the Mac is unlocked and only on this device).
