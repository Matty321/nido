#!/bin/bash
# Disk caching measurements for docs/DISK-CACHING.md. One throwaway VM per mode,
# 2 GiB / 2 vCPU, in a temporary NIDO_ROOT; booted by vzbench (NidoCore's configuration, boot
# disk attachment replaced for cached-fsync).
#   WORK=<dir> bench.sh default|cached-fsync <out-dir>
# WORK holds `key`/`key.pub` (a throwaway SSH key) and `root` (path of an existing, empty
# temporary NIDO_ROOT). Needs the signed debug `nido` (scripts/sign-dev.sh) and the image cache.
set -uo pipefail
MODE="$1"; OUT="$2"
: "${WORK:?WORK (working folder with key, key.pub and root) is required}"; S="$WORK"
N="$(cd "$(dirname "$0")/../.." && pwd)/.build/debug/nido"
VZ="$(cd "$(dirname "$0")" && pwd)/.build/release/vzbench"
export NIDO_ROOT="$(cat $S/root)"
VM="d-$MODE"
mkdir -p "$OUT"
LOG="$OUT/$MODE.log"
: > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }
host() { say "HOST $(date +%T) load=$(sysctl -n vm.loadavg | tr -d '{}') $(memory_pressure | tail -1 | sed 's/System-wide memory free percentage/memfree/') swap=$(sysctl -n vm.swapusage | awk '{print $6}')"; }
G() { $N ssh "$VM" -- -i $S/key -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=3 "$@" </dev/null; }
VZPID=""
boot() {
    $VZ "$NIDO_ROOT/$VM.nidovm" "$MODE" >> "$OUT/$MODE-vz.log" 2>&1 &
    VZPID=$!
    for _ in $(seq 1 90); do G true 2>/dev/null && return 0; sleep 2; done
    say "ERROR: no ssh"; return 1
}
hardstop() {
    kill -USR1 "$VZPID"; wait "$VZPID" 2>/dev/null
}
gentlestop() {
    kill -TERM "$VZPID"
    for _ in $(seq 1 60); do kill -0 "$VZPID" 2>/dev/null || break; sleep 1; done
    kill -USR1 "$VZPID" 2>/dev/null; wait "$VZPID" 2>/dev/null
}
cleanup() { [[ -n "$VZPID" ]] && kill -0 "$VZPID" 2>/dev/null && kill -USR1 "$VZPID"; sleep 2; $N delete "$VM" --yes >/dev/null 2>&1; }
trap cleanup EXIT

$N create "$VM" --image-file "$HOME/Library/Caches/Nido/images/debian-13-genericcloud-arm64.raw" \
    --ssh-key $S/key.pub --memory 2G --cpus 2 --disk 20G --no-packages --no-guest-tools >/dev/null 2>&1
host
boot || exit 1
G 'cloud-init status --wait >/dev/null; uname -r; cat /sys/block/vda/queue/write_cache' | tee -a "$LOG"
grep "vzbench: disk" "$OUT/$MODE-vz.log" | tee -a "$LOG"

say "== sequential (2 GiB, dd bs=1M)"
for r in 1 2 3; do
    host
    say "write-direct $r: $(G 'sudo dd if=/dev/zero of=/var/tmp/big bs=1M count=2048 oflag=direct conv=fsync 2>&1 | tail -1')"
    say "read-direct  $r: $(G 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null; sudo dd if=/var/tmp/big of=/dev/null bs=1M iflag=direct 2>&1 | tail -1')"
    say "write-buffered+fsync $r: $(G 'sudo rm -f /var/tmp/big; sudo dd if=/dev/zero of=/var/tmp/big bs=1M count=2048 conv=fsync 2>&1 | tail -1')"
    G 'sudo rm -f /var/tmp/big'
done

say "== small files"
G 'python3 - <<EOF
import os, random, tarfile
random.seed(14)
os.makedirs("/dev/shm/src", exist_ok=True)
for i in range(20000):
    d = "/dev/shm/src/d%03d" % (i % 200)
    os.makedirs(d, exist_ok=True)
    with open("%s/f%05d" % (d, i), "wb") as f:
        f.write(os.urandom(random.randint(512, 8192)))
EOF
tar -C /dev/shm -cf /dev/shm/s.tar src && rm -rf /dev/shm/src && ls -l /dev/shm/s.tar' | tee -a "$LOG"
for r in 1 2 3; do
    host
    say "tar-x+sync $r: $(G 'sudo rm -rf /var/tmp/x; sync; mkdir -p /var/tmp/x; s=$(date +%s.%N); tar -xf /dev/shm/s.tar -C /var/tmp/x && sync; e=$(date +%s.%N); echo "$e - $s" | python3 -c "import sys; print(round(eval(sys.stdin.read()),2), \"s\")"')"
    say "fsync-each(2000x4KiB) $r: $(G 'python3 -c "
import os, time
os.makedirs(\"/var/tmp/fs\", exist_ok=True)
t = time.time()
for i in range(2000):
    fd = os.open(\"/var/tmp/fs/f%d\" % i, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    os.write(fd, os.urandom(4096)); os.fsync(fd); os.close(fd)
d = os.open(\"/var/tmp/fs\", os.O_RDONLY); os.fsync(d); os.close(d)
dt = time.time() - t
print(round(dt, 2), \"s\", round(2000 / dt), \"fsync/s\")
"; rm -rf /var/tmp/fs')"
done
G 'sudo rm -rf /var/tmp/x /dev/shm/s.tar'

say "== integrity (64 x 4 MiB random + 1 GiB buffered dd running alongside, then hard stop)"
WRITE='python3 - <<EOF
import os, hashlib
d = "/var/tmp/integ"
os.makedirs(d, exist_ok=True)
for i in range(64):
    b = os.urandom(4 << 20)
    with open("%s/f%02d" % (d, i), "wb") as f:
        f.write(b)
    print("f%02d" % i, len(b), hashlib.sha256(b).hexdigest())
EOF'
VERIFY='python3 - <<EOF
import os, hashlib, sys
m = {}
for line in open("/var/tmp/manifest"):
    n, size, h = line.split(); m[n] = (int(size), h)
ok = missing = short = bad = 0
for n, (size, h) in sorted(m.items()):
    p = "/var/tmp/integ/" + n
    if not os.path.exists(p): missing += 1; continue
    b = open(p, "rb").read()
    if hashlib.sha256(b).hexdigest() == h: ok += 1
    elif len(b) != size: short += 1
    else: bad += 1
print("ok=%d missing=%d short=%d corrupt(same size, wrong content)=%d" % (ok, missing, short, bad))
EOF'
for variant in sync nosync; do
    for r in 1 2 3; do
        host
        G 'sudo rm -rf /var/tmp/integ /var/tmp/load; sync'
        if [[ $variant == sync ]]; then
            # The heredoc of WRITE ends its line: sync goes on the next one.
            G "(dd if=/dev/zero of=/var/tmp/load bs=1M count=1024 2>/dev/null &) ; $WRITE
sync" > "$OUT/$MODE-manifest-$variant-$r"
        else
            G "(dd if=/dev/zero of=/var/tmp/load bs=1M count=1024 2>/dev/null &) ; $WRITE" > "$OUT/$MODE-manifest-$variant-$r"
        fi
        hardstop
        say "integrity $variant $r: manifest $(wc -l < "$OUT/$MODE-manifest-$variant-$r") files, hard stop at $(date +%T)"
        boot || exit 1
        $N ssh "$VM" -- -i $S/key -o IdentitiesOnly=yes -o BatchMode=yes 'cat > /var/tmp/manifest' < "$OUT/$MODE-manifest-$variant-$r"
        res=$(G "sudo $VERIFY")
        fs=$(G 'sudo dmesg | grep -E "EXT4-fs (error|warning)|recovery complete|orphan|I/O error" | sed "s/^\[[ 0-9.]*\] //" | sort | uniq -c | tr "\n" ";"')
        say "  verify: $res | dmesg: ${fs:-none}"
    done
done
host
G 'sudo dmesg | grep -ciE "ext4.*error|I/O error"' | sed 's/^/total fs errors in last boot: /' | tee -a "$LOG"
gentlestop
say "done"
