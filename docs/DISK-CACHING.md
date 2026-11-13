# Linux VM disk caching: measurements (Nido 0.3.0)

Status: **decided (see "Decision")**. Before these measurements the VMs' disk was attached with
`VZDiskImageStorageDeviceAttachment(url:readOnly:)`, that is `cachingMode = .automatic` and
`synchronizationMode = .full`. With these measurements in hand, the user chose on 2026-10-25
`.cached` + `.full` for every Linux VM (since 0.3.0).

## Why

The investigation into the guest crashes during the development of 0.3.0
attributed the crash to guest RAM pages that macOS lost under memory overcommit, not to the disk.
It did, however, find two signals on the disk path: an ext4 checksum error after a forced stop and
0-byte files after an abrupt stop in an earlier test. In addition, Lima (issue #1957, then
`DiskImageCachingModeCached` since v0.19) and vfkit/podman (PR #76, `.cached` + `.fsync`) moved
away from exactly the default mode that Nido uses, because of disk corruption reported on Apple
silicon. This document measures what would actually change.

## Modes compared (APIs checked in the macOS 26 headers)

`VZDiskImageStorageDeviceAttachment(url:readOnly:cachingMode:synchronizationMode:)`, macOS 12+:

| Name | `cachingMode` | `synchronizationMode` | Notes |
|---|---|---|---|
| **A, default** (today) | `.automatic` (0) | `.full` (1) | every guest flush becomes an `F_FULLFSYNC` on the Mac |
| **B, `cached-fsync`** | `.cached` (2) | `.fsync` (2) | vfkit/podman's choice |
| **C, `cached-full`** | `.cached` (2) | `.full` (1) | added to separate the effect of the two options (it is Lima's choice) |

`.fsync` syncs the data to the Mac's disk with `fsync()`, without asking the drive to flush its
own cache: after a power loss it can lose writes that the guest believes are already safe.
`.full` guarantees it (`F_FULLFSYNC`), at a cost of about 10 ms per flush on this Mac.
`.cached` sends the VM disk's reads and writes through the macOS file cache.

## Method

- Mac: Apple M2, 16 GiB, internal APFS SSD, macOS 26.7.1 (25G241). Docker Desktop running (an 8 GiB VM,
  measured footprint 4.9 GiB), no other Nido VM. Load on the Mac during the tests 2.7–4.5
  (1-minute average), free memory according to `memory_pressure` 56–66%, swap steady at 6.9 GB
  (already in use before the tests). Recorded before every repetition in the test logs.
- One throwaway VM at a time, created from the image cache
  (`debian-13-genericcloud-arm64.raw`, kernel `6.12.113+deb13-cloud-arm64`) in a temporary
  root with `nido create --memory 2G --cpus 2 --disk 20G --no-packages --no-guest-tools`.
  Guest RAM deliberately low: overcommit is exactly what the investigation pointed to as the cause
  of the crashes. The guest sees the disk's write cache as `write back`.
- Started with `scripts/disk-caching/` (`vzbench`, not part of Nido's products): it builds the
  configuration with NidoCore's `LinuxConfigurationBuilder`, exactly as `nido start` does, and for B
  and C replaces only the boot disk's attachment. `SIGUSR1` = abrupt stop
  (`VZVirtualMachine.stop`, no guest shutdown).
- Tests (3 repetitions each; A and B in two rounds, the second in reverse order; C in one round):
  - sequential, 2 GiB with `dd bs=1M`: write `oflag=direct conv=fsync`, read
    `iflag=direct` after `drop_caches`, write through the guest's cache with `conv=fsync`; the data is zeros.
    Repeated with incompressible random data (a 512 MiB file in `/dev/shm` written 4 times).
  - small files: extracting a tar of 20,000 files of 0.5–8 KiB (98 MiB) plus `sync`;
    2,000 files of 4 KiB with an `fsync` for each (the workload of `dpkg`, databases, git).
  - integrity: 64 random 4 MiB files with the SHA-256 of each saved on the Mac, while a 1 GiB
    `dd` writes in parallel (I/O load); then an abrupt stop right after `sync` (3 times) and
    right after writing without `sync` (3 times); restart, check of presence, size and
    content of every file, ext4 kernel messages.

## Results

Medians (minimum–maximum in parentheses). MB/s and GB/s as `dd` prints them (base 10), MiB/s computed.

| Test | A default | B `cached-fsync` | C `cached-full` |
|---|---|---|---|
| Direct write 2 GiB, zeros | 210 MB/s (137–218) | 1.75 GB/s (1.2–2.8) | 1.6 GB/s (1.5–2.0) |
| Direct write 2 GiB, random | 218 MiB/s (204–229) | 2,314 MiB/s (1,838–2,323) | 1,150 MiB/s (1,110–1,238) |
| Direct read 2 GiB | 804 MB/s (364–835) | 8.0 GB/s (3.6–8.6) | 4.2 GB/s (3.7–8.9) |
| Cached write + fsync, zeros | 2.1 GB/s (1.9–2.3) | 1.65 GB/s (1.4–1.9) | 1.5 GB/s (1.2–1.9) |
| Cached write + sync, random | 2,021 MiB/s (615–2,224) | 1,408 MiB/s (1,089–1,410) | 1,316 MiB/s (1,272–1,515) |
| tar of 20,000 files + `sync` | 0.39 s (0.37–0.43) | 0.27 s (0.25–0.30) | 0.31 s (0.30–0.32) |
| 2,000 × (4 KiB + `fsync`) | **92 fsync/s** (83–94) | **2,920 fsync/s** (2,254–3,308) | **96 fsync/s** (94–97) |
| Integrity, stop after `sync` | 6/6 rounds, 384/384 files intact | 6/6 rounds, 384/384 intact | 3/3 rounds, 192/192 intact |
| Integrity, stop without `sync` | 6/6 rounds: all files missing, no file truncated or altered | same (6/6 rounds) | same (3/3 rounds) |
| File system errors after the restart | none (only `EXT4-fs (vda1): recovery complete`) | none | none |

How to read them:

- **`.cached` multiplies direct writes** (about 8–10×) and reads: over 3 GB/s for reads
  means the data comes from the macOS file cache, not from the SSD. Writing through the guest's
  cache was already fast with A and doesn't improve.
- **`.fsync` is what matters for flush-heavy workloads**: with `.full`, every guest `fsync`
  costs an `F_FULLFSYNC` (about 11 ms), with or without `.cached` (A and C ~95/s); with `.fsync` it goes to
  about 3,000/s (~30×).
- **Integrity**: no measurable difference. After `sync`, every file was intact in every
  mode; without `sync`, about 1 second after the write, the files weren't in the ext4 journal yet
  and were all missing (as expected), with the file system consistent (journal recovery, no errors).
  In 30 abrupt stops, not a single corrupted file or file of the wrong length appeared.

## Limits of the measurements

- The abrupt stop stops the VM, not the Mac: the macOS file cache survives. So these tests
  can't show the difference between `.full` and `.fsync` after a **power loss** or a
  panic of the Mac, which is exactly the case where `.fsync` can lose writes acknowledged to the guest (on a
  laptop the battery makes this rare; on a desktop Mac it doesn't).
- Tests without memory pressure on the Mac (a deliberate choice, see above): they don't tell whether the
  corruption Lima reported with `.automatic` shows up here, nor how `.cached` behaves when
  macOS has to free memory. The file cache is memory that macOS can free (clean pages
  are discarded, dirty ones must be written first), unlike the guest's RAM, which has to be
  compressed or written to swap; this wasn't measured.
- A single Mac, a single SSD, few repetitions (3 per round); the variation between repetitions is
  reported. The reads of C and B vary a lot (how much of the file is still in the Mac's cache).

## Recommendation

1. **Adopt `.cached` for the boot disk of Linux VMs** (Lima's choice): the same flush guarantees as
   today (`.full`), direct writes about 5–10 times faster and reads served from the
   Mac's cache, no difference in integrity observed. It aligns Nido with the projects that saw
   corruption with `.automatic`. The seed stays read-only and as it is.
2. **`.fsync` only as an explicit choice** (for example a per-VM "disk performance" option,
   off by default): about 30 times faster for `apt`/`dpkg`, databases and git, at the price of possibly
   losing writes already acknowledged to the guest if the Mac suddenly loses power.
3. Before changing the default: repeat the integrity test with the Mac's memory under
   pressure (like round 3 of the investigation) on a VM with `.cached`, and document the change in
   `docs/BUNDLE-FORMAT.md` and `docs/SECURITY.md`. An existing VM needs no migration: the mode
   applies from the next start and the format of `disk.img` doesn't change.

## Decision

The user's choice, 2026-10-25: **`.cached` + `.full`** for the boot disk of every Linux VM,
from the next start, with no per-VM option (`LinuxConfigurationBuilder`,
`VZDiskImageStorageDeviceAttachment(url:readOnly:cachingMode:synchronizationMode:)`). The cloud-init
seed stays as it is: it is read-only and tiny, and the headers don't say that the mode matters for it.
Snapshots and cloning don't change; no migration, `disk.img` keeps the same format.

Point 3 of the recommendation was done only in part: the change is documented in
`docs/SECURITY.md` and here, but the integrity test with the Mac's memory under pressure (round 3)
**wasn't run** before the decision (the user decided on the measurements without pressure).
It remains a known limit, listed among the residual risks of M3c (0.3.0) in `docs/SECURITY.md`.

A suspended state saved before the change: the mode does **not** go into the compatibility hash. Real
test (macOS 26.7.1): a VM suspended with the earlier build (3d2d992), started with the new one, **resumed**
(a marker written before the suspend still present, no warning). If the framework refused,
the existing path applies (cold boot with a warning, never an error), covered by
`oldSuspendedStateFallsBackToColdBoot`; `suspendedStateBeforeDiskModeChangeStillResumes` pins the
hash's inputs (a new input, such as a disk mode, would make it fail). Integrity test: a new VM, `dd bs=1M count=512
conv=fsync`, clean stop, restart: `journalctl -k -b -1` without ext4 errors (only the GPT warning
caused by resizing the image).

## Reproducing

```sh
./scripts/sign-dev.sh
swift build -c release --package-path scripts/disk-caching
codesign --sign - --entitlements Resources/nido.entitlements --force scripts/disk-caching/.build/release/vzbench
WORK=$(mktemp -d); ssh-keygen -q -t ed25519 -N "" -f "$WORK/key"
mktemp -d /Users/Shared/nido-disk.XXXXXX > "$WORK/root"; chmod 700 "$(cat "$WORK/root")"
for m in default cached-fsync cached-full; do
    WORK="$WORK" scripts/disk-caching/bench.sh "$m" "$WORK/out"
    WORK="$WORK" scripts/disk-caching/bench-random.sh "$m" "$WORK/out"
done
rmdir "$(cat "$WORK/root")"
```

Every test creates and deletes its own VM; the results are in `$WORK/out/<mode>.log`.
