#!/bin/bash
# Sequential throughput with incompressible data (complements bench.sh, whose dd writes zeros).
#   WORK=<dir> bench-random.sh default|cached-fsync <out-dir>   (WORK as in bench.sh)
set -uo pipefail
MODE="$1"; OUT="$2"
: "${WORK:?WORK (working folder with key, key.pub and root) is required}"; S="$WORK"
N="$(cd "$(dirname "$0")/../.." && pwd)/.build/debug/nido"
VZ="$(cd "$(dirname "$0")" && pwd)/.build/release/vzbench"
export NIDO_ROOT="$(cat $S/root)"
VM="r-$MODE"
mkdir -p "$OUT"
LOG="$OUT/$MODE-random.log"
: > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }
host() { say "HOST $(date +%T) load=$(sysctl -n vm.loadavg | tr -d '{}') $(memory_pressure | tail -1 | sed 's/System-wide memory free percentage/memfree/') swap=$(sysctl -n vm.swapusage | awk '{print $6}')"; }
G() { $N ssh "$VM" -- -i $S/key -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=3 "$@" </dev/null; }
VZPID=""
cleanup() { [[ -n "$VZPID" ]] && kill -0 "$VZPID" 2>/dev/null && { kill -TERM "$VZPID"; sleep 15; kill -USR1 "$VZPID" 2>/dev/null; }; sleep 2; $N delete "$VM" --yes >/dev/null 2>&1; }
trap cleanup EXIT

$N create "$VM" --image-file "$HOME/Library/Caches/Nido/images/debian-13-genericcloud-arm64.raw" \
    --ssh-key $S/key.pub --memory 2G --cpus 2 --disk 20G --no-packages --no-guest-tools >/dev/null 2>&1
$VZ "$NIDO_ROOT/$VM.nidovm" "$MODE" >> "$OUT/$MODE-random-vz.log" 2>&1 &
VZPID=$!
for _ in $(seq 1 90); do G true 2>/dev/null && break; sleep 2; done
G 'cloud-init status --wait >/dev/null; head -c 512M /dev/urandom > /dev/shm/r && ls -l /dev/shm/r' | tee -a "$LOG"
for r in 1 2 3; do
    host
    say "random write-direct $r (4 x 512 MiB): $(G 'sudo rm -f /var/tmp/big; sync; s=$(date +%s.%N); for i in 0 1 2 3; do sudo dd if=/dev/shm/r of=/var/tmp/big bs=1M seek=$((i*512)) conv=notrunc,fsync oflag=direct status=none; done; e=$(date +%s.%N); python3 -c "print(round(2048 / ($e - $s)), \"MiB/s\")"')"
    say "random read-direct $r: $(G 'echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null; sudo dd if=/var/tmp/big of=/dev/null bs=1M iflag=direct 2>&1 | tail -1')"
    say "random write-buffered+fsync $r: $(G 'sudo rm -f /var/tmp/big; sync; s=$(date +%s.%N); for i in 0 1 2 3; do sudo dd if=/dev/shm/r of=/var/tmp/big bs=1M seek=$((i*512)) conv=notrunc status=none; done; sync; e=$(date +%s.%N); python3 -c "print(round(2048 / ($e - $s)), \"MiB/s\")"')"
done
host
say "done"
