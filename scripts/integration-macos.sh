#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# End-to-end test of a real macOS VM installed from an IPSW the user downloaded:
#   create --ipsw (timed, with its progress line) → list (SISTEMA) → refusals (start --console,
#   rosetta, template save) → headless `nido start` for 60 s (ssh explains Remote Login when the
#   guest got an address) → snapshot while running (refused: only the app snapshots a running VM)
#   → `nido stop --suspend` (suspended, or refused with the reason and no state) → snapshot of the
#   suspended VM and resume → stop → snapshot (disk + auxiliary storage) → clone (new machine
#   identifier, guest steps printed) started headless for 60 s → restore of the snapshot and a
#   start of 30 s → delete.
# SSH into the guest cannot be checked: Setup Assistant is not completed (it is done by hand in
# the app's window), so the guest has no account and Remote Login is off.
# Everything is created in a temporary root and removed at the end (also on failure); no other VM
# is touched. The IPSW is only read: never downloaded, modified, moved or copied.
#
# Required:
#   NIDO_TEST_IPSW          macOS restore image (.ipsw) already downloaded
# Optional:
#   NIDO_TEST_KEY           SSH public key (.pub) recorded for the guest; default: a new temporary
#                           ed25519 key in the temporary root
#   NIDO_TEST_ROOT_PARENT   existing directory in which the temporary NIDO_ROOT is created
#                           (default: $TMPDIR); the volume needs the VM's disk size + 2 GiB free
#   NIDO_TEST_DISK          disk of the VM (default 64G, sparse: about 20 GiB are really written)
#   NIDO_BIN                nido binary (default: .build/debug/nido, signed by sign-dev.sh)
#   NIDO_TEST_MIN_FREE      minimum free memory of the Mac in percent (default 25)
# Relative paths are resolved against the current directory before anything else.
set -euo pipefail
# The checks below read nido's Italian output: pinned whatever the Mac's language.
export NIDO_LANGUAGE=it

: "${NIDO_TEST_IPSW:?NIDO_TEST_IPSW (macOS restore image, .ipsw) is required}"

absolute() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s\n' "$PWD/$1" ;;
    esac
}
NIDO_TEST_IPSW="$(absolute "$NIDO_TEST_IPSW")"
[[ -f "$NIDO_TEST_IPSW" ]] || { echo "ERROR: $NIDO_TEST_IPSW is not a file" >&2; exit 1; }
if [[ -n "${NIDO_TEST_KEY:-}" ]]; then
    NIDO_TEST_KEY="$(absolute "$NIDO_TEST_KEY")"
fi
if [[ -n "${NIDO_BIN:-}" ]]; then
    NIDO_BIN="$(absolute "$NIDO_BIN")"
fi
if [[ -n "${NIDO_TEST_ROOT_PARENT:-}" ]]; then
    NIDO_TEST_ROOT_PARENT="$(absolute "$NIDO_TEST_ROOT_PARENT")"
fi

cd "$(dirname "$0")/.."
NIDO="${NIDO_BIN:-$PWD/.build/debug/nido}"
[[ -x "$NIDO" ]] || { echo "ERROR: $NIDO missing: run scripts/sign-dev.sh" >&2; exit 1; }
VM=mac-it
CLONE=mac-it-copia
SNAPSHOT=prima
USER_NAME=nidotest

echo "==> Mac: $(uptime)"
free_pct=$(memory_pressure 2>/dev/null | awk -F': ' '/free percentage/ {gsub("%", "", $2); print $2}')
echo "==> Mac: free memory ${free_pct:-?} %"
if [[ -n "$free_pct" ]] && (( free_pct < ${NIDO_TEST_MIN_FREE:-25} )); then
    echo "ERROR: the Mac's free memory is below ${NIDO_TEST_MIN_FREE:-25} %: quit other VMs before the test" >&2
    exit 1
fi

if [[ -n "${NIDO_TEST_ROOT_PARENT:-}" ]]; then
    NIDO_ROOT="$(mktemp -d "$NIDO_TEST_ROOT_PARENT/nido-it-mac.XXXXXX")"
else
    NIDO_ROOT="$(mktemp -d)"
fi
chmod 700 "$NIDO_ROOT"
export NIDO_ROOT
echo "NIDO_ROOT: $NIDO_ROOT"
LOGS="$NIDO_ROOT/logs"
mkdir -p "$LOGS"
VM_PID=""
CLONE_PID=""
CREATE_PID=""

fail() { echo "ERROR: $*" >&2; exit 1; }

# stop_and_wait <vm> <pid>: graceful stop, then SIGKILL after 90 s.
stop_and_wait() {
    local vm="$1" pid="$2"
    [[ -n "$pid" ]] || return 0
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null || true; return 0; }
    "$NIDO" stop "$vm" >/dev/null 2>&1 || true
    for _ in $(seq 1 90); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

cleanup() {
    local status=$?
    trap - EXIT
    # A second Ctrl-C must not abort the cleanup (the VMs would be left running).
    trap '' INT TERM HUP
    if [[ -n "$CREATE_PID" ]] && kill -0 "$CREATE_PID" 2>/dev/null; then
        # Ctrl-C equivalent: the installer removes its .creating-* folder before exiting.
        kill -INT "$CREATE_PID" 2>/dev/null || true
        for _ in $(seq 1 120); do kill -0 "$CREATE_PID" 2>/dev/null || break; sleep 1; done
        kill -KILL "$CREATE_PID" 2>/dev/null || true
        wait "$CREATE_PID" 2>/dev/null || true
    fi
    stop_and_wait "$VM" "$VM_PID"
    stop_and_wait "$CLONE" "$CLONE_PID"
    if (( status != 0 )); then
        for log in "$LOGS"/*.log; do
            [[ -f "$log" ]] || continue
            echo "--- $(basename "$log")" >&2
            tail -n 20 "$log" >&2 || true
        done
    fi
    for vm in "$CLONE" "$VM"; do
        "$NIDO" delete "$vm" --yes >/dev/null 2>&1 || true
    done
    rm -rf "$NIDO_ROOT"
    if [[ -e "$NIDO_ROOT" ]]; then
        echo "WARNING: $NIDO_ROOT was not fully removed" >&2
        status=1
    fi
    exit "$status"
}
trap cleanup EXIT
# An interrupted run must not look successful: the EXIT trap still cleans up, with this status.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# expect_refusal <expected text> <command…>: the command must fail and print the text.
expect_refusal() {
    local expected="$1" out
    shift
    if out=$("$@" 2>&1); then fail "succeeded instead of being refused: $*"; fi
    grep -qF "$expected" <<<"$out" || { echo "$out" >&2; fail "unexpected message for: $*"; }
    echo "    refused: $out"
}

# wait_exit <pid> <seconds>: waits for the process to end; fails after the time.
wait_exit() {
    local pid="$1" seconds="$2"
    for _ in $(seq 1 "$seconds"); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    kill -0 "$pid" 2>/dev/null && fail "process $pid did not end within $seconds s"
    wait "$pid" || fail "nido start (pid $pid) exited with an error"
}

# run_for <pid-variable> <vm> <seconds> <log>: `nido start` in the background, which must stay up
# for the time. Its PID goes into the named variable (VM_PID or CLONE_PID) right after the launch,
# so the cleanup stops it whatever happens next; sets GOT_IP (empty when the guest got no address).
run_for() {
    local var="$1" vm="$2" seconds="$3" log="$4" pid
    "$NIDO" start "$vm" >"$log" 2>&1 &
    pid=$!
    printf -v "$var" '%s' "$pid"
    GOT_IP=""
    for _ in $(seq 1 "$seconds"); do
        kill -0 "$pid" 2>/dev/null || fail "nido start $vm ended early"
        [[ -n "$GOT_IP" ]] || GOT_IP=$("$NIDO" ip "$vm" 2>/dev/null) || GOT_IP=""
        sleep 1
    done
    "$NIDO" list | grep -Eq "^${vm}[[:space:]]+in esecuzione" || fail "$vm is not listed as running"
}

# stop_vm <vm> <pid> <log>: `nido stop`, the process ends within 90 s and says so.
stop_vm() {
    local vm="$1" pid="$2" log="$3"
    "$NIDO" stop "$vm"
    wait_exit "$pid" 90
    grep -q "VM $vm arrestata" "$log" || fail "stop of $vm not reported"
}

if [[ -n "${NIDO_TEST_KEY:-}" ]]; then
    KEY="$NIDO_TEST_KEY"
else
    /usr/bin/ssh-keygen -q -t ed25519 -N "" -C nido-it-mac -f "$NIDO_ROOT/key"
    KEY="$NIDO_ROOT/key.pub"
fi

echo "==> create --ipsw $(basename "$NIDO_TEST_IPSW") (4 to 20 minutes)"
t0=$(date +%s)
"$NIDO" create "$VM" --ipsw "$NIDO_TEST_IPSW" --ssh-key "$KEY" --user "$USER_NAME" \
    --disk "${NIDO_TEST_DISK:-64G}" >"$LOGS/create.out" 2>"$LOGS/create.log" &
CREATE_PID=$!
wait "$CREATE_PID" || { CREATE_PID=""; fail "create failed"; }
CREATE_PID=""
install_time=$(( $(date +%s) - t0 ))
cat "$LOGS/create.out"
grep -q "Installazione di macOS .*: [0-9]* %" "$LOGS/create.log" || fail "no progress line"
grep -q "VM $VM installata. Aprila in Nido" "$LOGS/create.out" || fail "final message missing"
echo "    installation: ${install_time} s"
[[ -z "$(ls -A "$NIDO_ROOT" | grep '^\.creating-' || true)" ]] || fail ".creating-* folder left behind"
bundle="$NIDO_ROOT/$VM.nidovm"
for f in config.json disk.img auxiliary-storage.img hardware-model.bin machine-id.bin authorized_key.pub; do
    [[ -f "$bundle/$f" ]] || fail "$f missing from the bundle"
done
[[ ! -e "$bundle/seed.iso" && ! -e "$bundle/nvram.efi" ]] || fail "Linux files in the macOS bundle"
perms=$(stat -f '%Sp' "$bundle")
[[ "$perms" == "drwx------" ]] || fail "bundle permissions: $perms"
grep -q "\"sshUser\" : \"$USER_NAME\"" "$bundle/config.json" || fail "sshUser not saved"
grep -q '"osVersion"' "$bundle/config.json" || fail "osVersion not saved"

echo "==> list"
listing=$("$NIDO" list)
echo "$listing"
grep -Eq "^${VM}[[:space:]]+ferma[[:space:]]+macOS [0-9]+\.[0-9]+" <<<"$listing" || fail "SISTEMA is not macOS <version>"

echo "==> refusals for macOS"
expect_refusal "la console seriale non esiste per le VM macOS" "$NIDO" start "$VM" --console
expect_refusal "Rosetta per Linux non riguarda le VM macOS" "$NIDO" rosetta enable "$VM"
expect_refusal "i modelli di VM macOS non sono ancora disponibili" "$NIDO" template save "$VM"

echo "==> headless start for 60 s"
"$NIDO" start "$VM" >"$LOGS/start.log" 2>&1 &
VM_PID=$!
ip=""
for _ in $(seq 1 60); do
    kill -0 "$VM_PID" 2>/dev/null || fail "nido start ended early"
    [[ -n "$ip" ]] || ip=$("$NIDO" ip "$VM" 2>/dev/null) || ip=""
    sleep 1
done
grep -q "VM $VM avviata" "$LOGS/start.log" || fail "start not reported"
listing=$("$NIDO" list)
grep -Eq "^${VM}[[:space:]]+in esecuzione" <<<"$listing" || { echo "$listing" >&2; fail "$VM is not listed as running"; }
[[ ! -e "$bundle/console.log" ]] || fail "console.log created for a macOS VM"
if [[ -n "$ip" ]]; then
    echo "    IP: $ip"
    # Setup Assistant not completed: Remote Login is off, port 22 refuses.
    expect_refusal "attiva Login remoto nel guest" "$NIDO" ssh "$VM" -- -o BatchMode=yes true
else
    echo "    no IP within 60 s: the nido ssh message is not checked"
fi
echo "    SSH into the guest: cannot be checked (Setup Assistant not completed)"

echo "==> snapshot of the running VM from Terminal"
expect_refusal "in un altro processo" "$NIDO" snapshot create "$VM" accesa

echo "==> suspend (nido stop --suspend)"
SUSPENDED=""
if out=$("$NIDO" stop --suspend "$VM" 2>&1); then
    echo "    $out"
    grep -q "VM $VM sospesa" <<<"$out" || fail "suspend not confirmed"
    wait_exit "$VM_PID" 120
    VM_PID=""
    grep -q "VM $VM sospesa" "$LOGS/start.log" || fail "suspend not reported by nido start"
    [[ -s "$bundle/state.vzvmsave" ]] || fail "state.vzvmsave missing after the suspend"
    "$NIDO" list | grep -Eq "^${VM}[[:space:]]+sospesa" || fail "$VM is not listed as suspended"
    SUSPENDED=1
else
    # The guest cannot save its state: the reason, no state, the VM goes on.
    echo "    refused: $out"
    grep -q "non è stata sospesa" <<<"$out" || fail "suspend refused without a reason"
    [[ ! -e "$bundle/state.vzvmsave" ]] || fail "state.vzvmsave left after a refused suspend"
    kill -0 "$VM_PID" 2>/dev/null || fail "the VM stopped after a refused suspend"
fi

if [[ -n "$SUSPENDED" ]]; then
    echo "==> snapshot of the suspended VM"
    "$NIDO" snapshot create "$VM" sospesa
    snapdir=$(grep -l '"name" : "sospesa"' "$bundle"/snapshots/*/meta.json | xargs dirname) \
        || fail "snapshot 'sospesa' not found"
    for f in disk.img auxiliary-storage.img state.vzvmsave meta.json; do
        [[ -f "$snapdir/$f" ]] || fail "$f missing from the snapshot of the suspended VM"
    done
    "$NIDO" snapshot delete "$VM" sospesa --yes

    echo "==> resume"
    run_for VM_PID "$VM" 30 "$LOGS/resume.log"
    grep -q "VM $VM ripresa dallo stato sospeso" "$LOGS/resume.log" \
        || { cat "$LOGS/resume.log" >&2; fail "the VM was not resumed from the suspended state"; }
    [[ ! -e "$bundle/state.vzvmsave" ]] || fail "state.vzvmsave not consumed by the resume"
    stop_vm "$VM" "$VM_PID" "$LOGS/resume.log"
    VM_PID=""
else
    echo "==> stop"
    stop_vm "$VM" "$VM_PID" "$LOGS/start.log"
    VM_PID=""
fi

echo "==> snapshot of the stopped VM"
"$NIDO" snapshot create "$VM" "$SNAPSHOT"
"$NIDO" snapshot list "$VM" | grep -q "$SNAPSHOT" || fail "snapshot not listed"
snapdir=$(grep -l "\"name\" : \"$SNAPSHOT\"" "$bundle"/snapshots/*/meta.json | xargs dirname) \
    || fail "snapshot $SNAPSHOT not found"
for f in disk.img auxiliary-storage.img meta.json; do
    [[ -f "$snapdir/$f" ]] || fail "$f missing from the snapshot"
done
[[ ! -e "$snapdir/nvram.efi" && ! -e "$snapdir/state.vzvmsave" ]] || fail "unexpected files in the snapshot"

echo "==> clone"
clone_out=$("$NIDO" clone "$VM" "$CLONE")
echo "$clone_out"
grep -q "nuovo identificatore della macchina" <<<"$clone_out" || fail "macOS clone summary missing"
grep -qF "sudo rm /etc/ssh/ssh_host_* && sudo ssh-keygen -A" <<<"$clone_out" || fail "SSH keys step missing"
grep -qF "sudo scutil --set ComputerName $CLONE" <<<"$clone_out" || fail "computer name step missing"
"$NIDO" list | grep -Eq "^${CLONE}[[:space:]]" || fail "clone not listed"
clone_bundle="$NIDO_ROOT/$CLONE.nidovm"
for f in config.json disk.img auxiliary-storage.img hardware-model.bin machine-id.bin authorized_key.pub; do
    [[ -f "$clone_bundle/$f" ]] || fail "$f missing from the clone"
done
for f in seed.iso nvram.efi known_hosts state.vzvmsave snapshots; do
    [[ ! -e "$clone_bundle/$f" ]] || fail "$f should not be in the clone"
done
cmp -s "$bundle/machine-id.bin" "$clone_bundle/machine-id.bin" && fail "the clone has the same machine identifier"
cmp -s "$bundle/hardware-model.bin" "$clone_bundle/hardware-model.bin" || fail "different hardware model in the clone"

echo "==> starting the clone for 60 s (new identifier)"
run_for CLONE_PID "$CLONE" 60 "$LOGS/clone-start.log"
grep -q "VM $CLONE avviata" "$LOGS/clone-start.log" || fail "start of the clone not reported"
clone_ip="$GOT_IP"
echo "    IP of the clone: ${clone_ip:-none within 60 s}"
stop_vm "$CLONE" "$CLONE_PID" "$LOGS/clone-start.log"
CLONE_PID=""
"$NIDO" delete "$CLONE" --yes

echo "==> restoring the snapshot and starting for 30 s"
"$NIDO" snapshot restore "$VM" "$SNAPSHOT" --yes
run_for VM_PID "$VM" 30 "$LOGS/restored.log"
grep -q "VM $VM avviata" "$LOGS/restored.log" || fail "start after the restore not reported"
stop_vm "$VM" "$VM_PID" "$LOGS/restored.log"
VM_PID=""

echo "==> delete"
"$NIDO" delete "$VM" --yes
[[ ! -e "$bundle" ]] || fail "the bundle still exists"

echo
echo "OK: macOS from $(basename "$NIDO_TEST_IPSW"), installation ${install_time} s"
if [[ -n "$SUSPENDED" ]]; then echo "Suspend and resume: verified"; else echo "Suspend: refused by the guest (reason shown, no state)"; fi
echo "Clone started with a new machine identifier (IP: ${clone_ip:-none within 60 s})"
echo "SSH into the guest: not checked (needs Setup Assistant completed in the app)"
