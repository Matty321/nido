#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# End-to-end test on real Linux VMs, one 2 GiB VM at a time except the clone check (two at once):
#   M3c, VM "t" (standard profile, first boot run as the app does by nidoprobe):
#     phase 1 (essential packages, Guest Tools, panic settings, listeners) → monitor over vsock
#     (time from the first boot) → AI bridge with the DEBUG fake router (403 while off, filtered
#     model list and streaming chat while on, model not allowed, off again; the token never
#     reaches the guest or the bundle's files) → stop
#   M3a, VM "t" under `nido start`: read-only shared folder (+ Rosetta when already installed)
#     → suspend and resume (a guest counter keeps counting) → snapshot → change → restore
#     → clone (new identity, no shared folder inherited; both running at once)
#   M3c templates: template save → start refused → create from template (timed) → new identity,
#     Guest Tools active, no folder, bridge off → delete
#   M3c existing VM ("t-vecchia", created without packages and Guest Tools): Guest Tools and panic
#     settings over SSH → monitor over vsock at the next start
#   gvproxy controlled network (new VMs "t-rete" and "t-rete2", the default network of a new VM):
#     first boot with packages and `apt update` through the filter → a site outside the list is
#     blocked and in `nido net log` → `nido ip` / `nido ssh` on the 127.0.0.1 forward → stop and
#     start again (new forward port, no host-key prompt) → `kill -9` of `nido start` → no gvproxy of
#     that VM left after the next `nido start` of another VM. The run stops at the start if
#     net.inet.ip.forwarding is not 0 (the controlled network must work without IP forwarding).
#   Phase 2 ("t-ai", standard profile): Ollama's pinned release and one model, ~2 GiB downloaded
#     in the guest: ONLY with NIDO_TEST_OLLAMA=1 AND a confirmation at the start of the run.
#   Real Hugging Face call: ONLY with NIDO_TEST_HF=1 and NIDO_TEST_HF_MODEL=<id> AND a confirmation
#     at the start of the run (uses the token of the user's Keychain, service "Nido Hugging Face";
#     the request text leaves the Mac for Hugging Face and the provider).
#   Confirmations are asked on the terminal ("Continue? [y/N]"); without a terminal (stdin not a
#   TTY) the run stops before creating anything. NIDO_TEST_YES=1 skips the questions: setting it is
#   the user's explicit consent to every download and call enabled by the variables above.
# Phase 2 also runs on the controlled network (gvproxy), so it checks Ollama's download path.
# Everything is created in a temporary root and removed at the end; no other VM is touched.
#
# Required:
#   NIDO_TEST_IMAGE         raw Debian image, already downloaded and verified
#   NIDO_TEST_KEY           SSH public key (.pub) authorized in the guest; the private key must sit
#                           next to it without the .pub suffix (Nido's background SSH uses it)
# Optional:
#   NIDO_TEST_SSH_IDENTITY  matching private key passed to `nido ssh` with -i
#   NIDO_TEST_ROOT_PARENT   existing directory in which the temporary NIDO_ROOT is created
#                           (e.g. a path containing spaces); default: $TMPDIR
#   NIDO_TEST_SHARE_PARENT  existing directory for the temporary shared folder (default:
#                           /Users/Shared, because $TMPDIR lives under /private, which Nido
#                           refuses to share)
#   NIDO_BIN                nido binary (default: .build/debug/nido, signed by sign-dev.sh)
#   NIDO_TEST_OLLAMA=1      also run phase 2 (Ollama pinned release + qwen3:0.6b) in t-ai
#   NIDO_TEST_OLLAMA_MODEL  model of phase 2 (default: qwen3:0.6b)
#   NIDO_TEST_YES=1         explicit consent: no confirmation questions (see above)
#   NIDO_TEST_MIN_FREE      minimum free memory of the Mac in percent (default 25): the guests
#                           crash under host memory overcommit (M3c investigation)
# Relative paths are resolved against the current directory before anything else.
# Rosetta is never installed: its step runs only when `nido rosetta status` says it is installed.
set -euo pipefail
# The checks below read nido's Italian output: pinned whatever the Mac's language.
export NIDO_LANGUAGE=it

# The controlled network no longer needs IP forwarding: the test must prove that, so it refuses to
# run when forwarding is on (it never changes the setting itself).
forwarding=$(sysctl -n net.inet.ip.forwarding)
if [[ "$forwarding" != "0" ]]; then
    echo "ERROR: net.inet.ip.forwarding is $forwarding: the test needs 0 (the controlled network must work without IP forwarding)" >&2
    exit 1
fi

: "${NIDO_TEST_IMAGE:?NIDO_TEST_IMAGE (raw image) is required}"
: "${NIDO_TEST_KEY:?NIDO_TEST_KEY (.pub key) is required}"

absolute() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s\n' "$PWD/$1" ;;
    esac
}
NIDO_TEST_IMAGE="$(absolute "$NIDO_TEST_IMAGE")"
NIDO_TEST_KEY="$(absolute "$NIDO_TEST_KEY")"
if [[ -n "${NIDO_TEST_SSH_IDENTITY:-}" ]]; then
    NIDO_TEST_SSH_IDENTITY="$(absolute "$NIDO_TEST_SSH_IDENTITY")"
fi
if [[ -n "${NIDO_BIN:-}" ]]; then
    NIDO_BIN="$(absolute "$NIDO_BIN")"
fi
if [[ -n "${NIDO_TEST_ROOT_PARENT:-}" ]]; then
    NIDO_TEST_ROOT_PARENT="$(absolute "$NIDO_TEST_ROOT_PARENT")"
fi
SHARE_PARENT="$(absolute "${NIDO_TEST_SHARE_PARENT:-/Users/Shared}")"
OLLAMA_MODEL="${NIDO_TEST_OLLAMA_MODEL:-qwen3:0.6b}"

# confirm <what>: asks before a download or a call that leaves the Mac; refuses without a terminal.
# NIDO_TEST_YES=1 is the only bypass (explicit consent written by the user).
confirm() {
    echo "==> $1"
    if [[ "${NIDO_TEST_YES:-}" == "1" ]]; then
        echo "    confirmed with NIDO_TEST_YES=1"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        echo "ERROR: a confirmation is needed but stdin is not a terminal: run again from Terminal or with NIDO_TEST_YES=1" >&2
        exit 1
    fi
    local answer
    read -r -p "    Continue? [y/N] " answer
    [[ "$answer" == "y" || "$answer" == "Y" ]] || { echo "ERROR: not confirmed" >&2; exit 1; }
}
if [[ "${NIDO_TEST_OLLAMA:-}" == "1" ]]; then
    confirm "phase 2: a temporary VM downloads Ollama ${OLLAMA_MODEL:+and $OLLAMA_MODEL} in the guest (Ollama 0.40.10 from GitHub, about 1.5 GiB, plus the model: about 2 GiB in all) and is deleted at the end"
fi
if [[ "${NIDO_TEST_HF:-}" == "1" ]]; then
    : "${NIDO_TEST_HF_MODEL:?NIDO_TEST_HF_MODEL (model id) is required with NIDO_TEST_HF=1}"
    confirm "real AI bridge: one request to router.huggingface.co with $NIDO_TEST_HF_MODEL using the token in your Keychain; the request text leaves the Mac for Hugging Face and the provider"
fi

cd "$(dirname "$0")/.."
NIDO="${NIDO_BIN:-$PWD/.build/debug/nido}"
VM=t
CLONE=t-copia
FROM_TEMPLATE=t-uno
OLD=t-vecchia
AI=t-ai
NET=t-rete
NET2=t-rete2
FAKE_TOKEN=hf_NidoDebugFakeToken
BRIDGE_MODEL=openai/gpt-oss-120b

echo "==> Mac: $(uptime)"
free_pct=$(memory_pressure 2>/dev/null | awk -F': ' '/free percentage/ {gsub("%", "", $2); print $2}')
echo "==> Mac: free memory ${free_pct:-?} %"
if [[ -n "$free_pct" ]] && (( free_pct < ${NIDO_TEST_MIN_FREE:-25} )); then
    echo "ERROR: the Mac's free memory is below ${NIDO_TEST_MIN_FREE:-25} %: quit other VMs before the test" >&2
    exit 1
fi

echo "==> nidoprobe (app paths the CLI lacks: monitor, AI bridge, Guest Tools over SSH)"
swift build --package-path scripts/integration-probe >/dev/null
PROBE="$PWD/scripts/integration-probe/.build/debug/nidoprobe"
codesign --sign - --entitlements Resources/nido.entitlements --force "$PROBE" 2>/dev/null
# Like the CLI, the probe looks for the pinned gvproxy in libexec/ next to itself (controlled network).
sh scripts/fetch-gvproxy.sh >/dev/null
mkdir -p "$(dirname "$PROBE")/libexec"
cp .build/gvproxy/gvproxy "$(dirname "$PROBE")/libexec/gvproxy"
codesign --sign - --identifier io.gitlab.pichierri.Nido.gvproxy --options runtime --force "$(dirname "$PROBE")/libexec/gvproxy" 2>/dev/null

if [[ -n "${NIDO_TEST_ROOT_PARENT:-}" ]]; then
    NIDO_ROOT="$(mktemp -d "$NIDO_TEST_ROOT_PARENT/nido-it.XXXXXX")"
else
    NIDO_ROOT="$(mktemp -d)"
fi
chmod 700 "$NIDO_ROOT"
export NIDO_ROOT
echo "NIDO_ROOT: $NIDO_ROOT"
SHARE_DIR="$(mktemp -d "$SHARE_PARENT/nido-it-share.XXXXXX")" || { rm -rf "$NIDO_ROOT"; exit 1; }
LOGS="$NIDO_ROOT/logs"
mkdir -p "$LOGS"
VM_PID=""
CLONE_PID=""
SAMPLER_PID=""
PROBE_PID=""
PROBE_VM=""

now() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%.2f\n", time'; }
elapsed() { /usr/bin/perl -e 'printf "%.2f\n", $ARGV[1] - $ARGV[0]' "$1" "$2"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

# stop_and_wait <vm> <pid>: graceful stop, then SIGKILL after 60 s.
stop_and_wait() {
    local vm="$1" pid="$2"
    [[ -n "$pid" ]] || return 0
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null || true; return 0; }
    "$NIDO" stop "$vm" >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# probe_close: closes the probe's stdin (it stops the VM gracefully), SIGKILL after 90 s.
probe_close() {
    [[ -n "$PROBE_PID" ]] || return 0
    exec 7>&- 2>/dev/null || true
    for _ in $(seq 1 90); do
        kill -0 "$PROBE_PID" 2>/dev/null || break
        sleep 1
    done
    kill -KILL "$PROBE_PID" 2>/dev/null || true
    wait "$PROBE_PID" 2>/dev/null || true
    PROBE_PID=""
}

cleanup() {
    local status=$?
    if [[ -n "$SAMPLER_PID" ]]; then
        kill "$SAMPLER_PID" 2>/dev/null || true
        wait "$SAMPLER_PID" 2>/dev/null || true
    fi
    probe_close
    for vm in "$VM" "$FROM_TEMPLATE" "$OLD" "$AI" "$NET" "$NET2"; do "$NIDO" stop "$vm" >/dev/null 2>&1 || true; done
    stop_and_wait "$VM" "$VM_PID"
    stop_and_wait "$CLONE" "$CLONE_PID"
    if (( status != 0 )); then
        for log in "$LOGS"/*.log; do
            [[ -f "$log" ]] || continue
            echo "--- $(basename "$log")" >&2
            tail -n 20 "$log" >&2 || true
        done
    fi
    for vm in "$VM" "$CLONE" "$FROM_TEMPLATE" "$OLD" "$AI" "$NET" "$NET2"; do
        "$NIDO" template edit "$vm" >/dev/null 2>&1 || true
        "$NIDO" delete "$vm" --yes >/dev/null 2>&1 || true
    done
    rm -rf "$NIDO_ROOT" "$SHARE_DIR"
    exit "$status"
}
trap cleanup EXIT

ssh_extra=()
if [[ -n "${NIDO_TEST_SSH_IDENTITY:-}" ]]; then
    ssh_extra=(-i "$NIDO_TEST_SSH_IDENTITY" -o IdentitiesOnly=yes)
fi
ssh_extra+=(-o BatchMode=yes -o ConnectTimeout=5)

# guest <vm> <command…>: runs a command in the guest over SSH (stdin closed).
guest() {
    local vm="$1"
    shift
    "$NIDO" ssh "$vm" -- "${ssh_extra[@]}" "$@" </dev/null
}

# start_bg <vm> <log>: starts `nido start` in the background; the pid is in STARTED_PID.
start_bg() {
    "$NIDO" start "$1" >"$LOGS/$2.log" 2>&1 &
    STARTED_PID=$!
}

# wait_ssh <vm> <pid> <seconds>: waits until SSH into the guest works.
wait_ssh() {
    local vm="$1" pid="$2" deadline=$(( $(date +%s) + $3 ))
    while (( $(date +%s) < deadline )); do
        kill -0 "$pid" 2>/dev/null || fail "the process of VM $vm ended early"
        if guest "$vm" true 2>/dev/null; then return 0; fi
        sleep 1
    done
    fail "SSH into $vm did not succeed within $3 s"
}

# stop_vm <vm> <pid>: graceful stop that must finish within 60 s.
stop_vm() {
    local vm="$1" pid="$2"
    "$NIDO" stop "$vm"
    for _ in $(seq 1 60); do
        kill -0 "$pid" 2>/dev/null || { wait "$pid"; return 0; }
        sleep 1
    done
    fail "VM $vm did not stop within 60 s"
}

expect_state() {
    local vm="$1" state="$2" listing
    listing=$("$NIDO" list)
    grep -Eq "^${vm}[[:space:]]+${state}" <<<"$listing" || { echo "$listing" >&2; fail "$vm is not listed as $state"; }
}

# probe_start <vm> [options…]: runs the VM as the app does; commands go to fd 7.
probe_start() {
    PROBE_VM="$1"
    shift
    local fifo="$NIDO_ROOT/probe.in"
    rm -f "$fifo"
    mkfifo -m 600 "$fifo"
    "$PROBE" run "$NIDO_ROOT" "$PROBE_VM" "$@" <"$fifo" >"$LOGS/probe-$PROBE_VM.log" 2>&1 &
    PROBE_PID=$!
    exec 7>"$fifo"
    probe_wait "started:" 120 0 >/dev/null
}

# probe_wait <regex> <seconds> <from line>: prints the first matching probe line after <from line>.
probe_wait() {
    local regex="$1" deadline=$(( $(date +%s) + $2 )) from="$3" log="$LOGS/probe-$PROBE_VM.log" line
    while (( $(date +%s) < deadline )); do
        line=$(tail -n +"$((from + 1))" "$log" | grep -E "$regex|ERROR" | head -n 1 || true)
        if [[ -n "$line" ]]; then
            [[ "$line" != *ERROR* ]] || fail "nidoprobe: $line"
            printf '%s\n' "$line"
            return 0
        fi
        kill -0 "$PROBE_PID" 2>/dev/null || fail "nidoprobe ended early"
        sleep 0.5
    done
    fail "nidoprobe: no '$regex' line within $2 s"
}

# probe_cmd <command> <regex> <seconds>: sends a command and waits for its answer line.
probe_cmd() {
    local lines
    lines=$(wc -l <"$LOGS/probe-$PROBE_VM.log")
    echo "$1" >&7
    probe_wait "$2" "$3" "$lines"
}

# probe_stop: asks the probe to stop the VM and waits for it to exit.
probe_stop() {
    probe_cmd stop "stopped:" 90 >/dev/null
    exec 7>&-
    wait "$PROBE_PID" || fail "nidoprobe exited with an error"
    PROBE_PID=""
}

# http_code <vm> <curl arguments…>: HTTP status of a request made inside the guest.
http_code() {
    local vm="$1"
    shift
    guest "$vm" curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$@"
}

host_key() { guest "$1" ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}'; }

echo "==> shared folder on the Mac: $SHARE_DIR"
mkdir "$SHARE_DIR/docs"
printf 'ciao dal Mac\n' >"$SHARE_DIR/docs/nota.txt"

echo "==> create (standard profile: essential packages and Guest Tools)"
"$NIDO" create "$VM" --image-file "$NIDO_TEST_IMAGE" --ssh-key "$NIDO_TEST_KEY" \
    --memory 2G --cpus 2 --disk 8G --yes
grep -q '"guestToolsVersion"' "$NIDO_ROOT/$VM.nidovm/config.json" || fail "config without guestToolsVersion"

echo "==> share add (read only, the default)"
"$NIDO" share add "$VM" "$SHARE_DIR/docs" --name docs
"$NIDO" share list "$VM"

rosetta=0
if "$NIDO" rosetta status | grep -q "^Rosetta per Linux è installata"; then
    rosetta=1
    echo "==> rosetta enable (Rosetta is already installed on this Mac)"
    "$NIDO" rosetta enable "$VM"
else
    echo "==> Rosetta not installed: check skipped (this script never installs it)"
fi

echo "==> first boot as in the app (nidoprobe): monitor over vsock from the first boot"
m0=$(now)
probe_start "$VM"
monitor_line=$(probe_cmd "monitor 600" "monitor ok" 620)
m1=$(now)
monitor_time=$(elapsed "$m0" "$m1")
echo "$monitor_line"
grep -q 'agent=Nido AI Monitor version=2\.' <<<"$monitor_line" || fail "unexpected monitor response"
grep -q "hostname=$VM " <<<"$monitor_line" || fail "the monitor does not report host name $VM"
wait_ssh "$VM" "$PROBE_PID" 120

echo "==> phase 1: cloud-init, essential packages, Guest Tools"
guest "$VM" cloud-init status --wait >"$LOGS/cloud-init.txt" || true
grep -q "status: done" "$LOGS/cloud-init.txt" || { cat "$LOGS/cloud-init.txt"; fail "cloud-init is not done"; }
guest "$VM" "dpkg-query -W -f='\${Package} \${Status}\n' ca-certificates curl wget git python3 python3-venv \
    python3-pip openssh-server iproute2 procps util-linux jq tar zstd" >"$LOGS/packages.txt"
missing=$(grep -vc "install ok installed" "$LOGS/packages.txt" || true)
(( missing == 0 )) || { cat "$LOGS/packages.txt"; fail "essential packages missing"; }
gt_version=$(guest "$VM" cat /opt/nido-guest-tools/VERSION)
echo "Guest Tools $gt_version"
[[ "$(guest "$VM" systemctl is-active nido-guest-tools nido-ai-bridge | tr '\n' ' ')" == "active active " ]] \
    || fail "nido-guest-tools or nido-ai-bridge not active"
[[ "$(guest "$VM" systemctl show -p DynamicUser --value nido-guest-tools)" == "yes" ]] || fail "monitor without DynamicUser"

echo "==> phase 1: visible panics and reboot (files, sysctl)"
guest "$VM" test -f /etc/default/grub.d/nido.cfg -a -f /etc/sysctl.d/90-nido.conf || fail "panic files missing"
[[ "$(guest "$VM" cat /proc/sys/kernel/panic)" == "10" ]] || fail "kernel.panic is not 10"
[[ "$(guest "$VM" cat /proc/sys/kernel/panic_on_oops)" == "1" ]] || fail "kernel.panic_on_oops is not 1"
guest "$VM" sudo grep -q 'console=hvc0' /boot/grub/grub.cfg || fail "grub.cfg without console=hvc0"

echo "==> no new network service: only 127.0.0.1:11435 (bridge) besides SSH and DNS"
guest "$VM" ss -Hltn | awk '{print $4}' | sort -u | tee "$LOGS/listeners.txt"
if grep -Ev '^(0\.0\.0\.0:22|\[::\]:22|127\.0\.0\.5[34](%lo)?:53|127\.0\.0\.1:11435|0\.0\.0\.0:5355|\[::\]:5355)$' \
    "$LOGS/listeners.txt"; then
    fail "unexpected listening ports in the guest"
fi

echo "==> AI bridge (fake router): off → 403"
code=$(http_code "$VM" http://127.0.0.1:11435/v1/models)
[[ "$code" == "403" ]] || fail "bridge off: expected 403, got $code"

echo "==> AI bridge on for $BRIDGE_MODEL: filtered list and streaming chat"
probe_cmd "enable $BRIDGE_MODEL" "bridge on" 10 >/dev/null
models=$(guest "$VM" curl -s --max-time 20 http://127.0.0.1:11435/v1/models)
[[ "$(jq -r '[.data[].id] | join(",")' <<<"$models")" == "$BRIDGE_MODEL" ]] || fail "model list: $models"
guest "$VM" curl -sN --max-time 30 http://127.0.0.1:11435/v1/chat/completions \
    -H "'Content-Type: application/json'" -H "'Authorization: Bearer chiave-del-guest'" \
    -d "'{\"model\":\"$BRIDGE_MODEL\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"Di ciao\"}]}'" \
    >"$LOGS/bridge-chat.txt"
grep -q '^data: \[DONE\]' "$LOGS/bridge-chat.txt" || fail "streaming chat without [DONE]"
chunks=$(grep -c '"content"' "$LOGS/bridge-chat.txt" || true)
(( chunks >= 2 )) || fail "streaming chat: $chunks chunks"
code=$(http_code "$VM" http://127.0.0.1:11435/v1/chat/completions -H "'Content-Type: application/json'" \
    -d "'{\"model\":\"Qwen/Qwen3-8B\",\"messages\":[{\"role\":\"user\",\"content\":\"x\"}]}'")
[[ "$code" == "403" ]] || fail "model not allowed: expected 403, got $code"
probe_cmd disable "bridge off" 10 >/dev/null
code=$(http_code "$VM" http://127.0.0.1:11435/v1/models)
[[ "$code" == "403" ]] || fail "bridge off again: expected 403, got $code"

echo "==> AI bridge: log without content, token never in the guest or the bundle"
log_file="$NIDO_ROOT/$VM.nidovm/ai-bridge.log"
[[ "$(stat -f '%Sp' "$log_file")" == "-rw-------" ]] || fail "ai-bridge.log is not 0600"
grep -q "\"model\":\"$BRIDGE_MODEL\"" "$log_file" || fail "ai-bridge.log without the call"
if grep -q "Di ciao" "$log_file"; then fail "ai-bridge.log contains the prompt"; fi
if grep -rq "$FAKE_TOKEN" "$NIDO_ROOT/$VM.nidovm" "$LOGS/bridge-chat.txt"; then fail "token in the bundle or in the response"; fi
if guest "$VM" sudo grep -rqs "$FAKE_TOKEN" /etc /opt /var/lib/nido-provision /home; then fail "token in the guest"; fi

if [[ "${NIDO_TEST_HF:-}" == "1" ]]; then
    : "${NIDO_TEST_HF_MODEL:?NIDO_TEST_HF_MODEL (model id) is required with NIDO_TEST_HF=1}"
    echo "==> real AI bridge (NIDO_TEST_HF=1): one request to router.huggingface.co with $NIDO_TEST_HF_MODEL"
    probe_stop
    probe_start "$VM" --real-router
    wait_ssh "$VM" "$PROBE_PID" 120
    probe_cmd "enable $NIDO_TEST_HF_MODEL" "bridge on" 10 >/dev/null
    guest "$VM" curl -sN --max-time 120 http://127.0.0.1:11435/v1/chat/completions -H "'Content-Type: application/json'" \
        -d "'{\"model\":\"$NIDO_TEST_HF_MODEL\",\"stream\":true,\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"Di ciao\"}]}'" \
        >"$LOGS/bridge-hf.txt"
    grep -q '^data: \[DONE\]' "$LOGS/bridge-hf.txt" || fail "real call without [DONE]"
    if grep -rq 'hf_' "$NIDO_ROOT/$VM.nidovm/ai-bridge.log" "$LOGS/bridge-hf.txt"; then fail "token in the log or in the response"; fi
    probe_cmd disable "bridge off" 10 >/dev/null
fi

mid_t=$(guest "$VM" cat /etc/machine-id)
key_t=$(host_key "$VM")
probe_stop
expect_state "$VM" ferma

echo "==> start (nido start, second boot)"
t0=$(date +%s)
start_bg "$VM" start-1
VM_PID=$STARTED_PID

# Sample the RSS (KiB) of the start process every second until it exits.
RSS_FILE="$NIDO_ROOT/rss.max"
echo 0 >"$RSS_FILE"
(
    max=0
    while rss=$(ps -o rss= -p "$VM_PID" 2>/dev/null); do
        rss=${rss// /}
        if [[ -n "$rss" ]] && (( rss > max )); then
            max=$rss
            echo "$max" >"$RSS_FILE"
        fi
        sleep 1
    done
) &
SAMPLER_PID=$!

echo "==> waiting for the IP (max 180 s)"
ip=""
for _ in $(seq 1 180); do
    kill -0 "$VM_PID" 2>/dev/null || fail "start ended early"
    if ip=$("$NIDO" ip "$VM" 2>/dev/null); then break; fi
    ip=""
    sleep 1
done
[[ -n "$ip" ]] || fail "no IP within 180 s"
echo "IP: $ip"

echo "==> waiting for SSH (max 120 s)"
wait_ssh "$VM" "$VM_PID" 120
# The host key must be pinned in the bundle's own known_hosts (also when NIDO_ROOT has spaces).
[[ -s "$NIDO_ROOT/$VM.nidovm/known_hosts" ]] || fail "the bundle's known_hosts is empty"
boot_to_ssh=$(( $(date +%s) - t0 ))

echo "==> panic: kernel command line from the second boot"
guest "$VM" cat /proc/cmdline | grep -q 'console=hvc0' || fail "/proc/cmdline without console=hvc0"

echo "==> shared folder: read"
content=$(guest "$VM" cat /mnt/nido/docs/nota.txt)
[[ "$content" == "ciao dal Mac" ]] || fail "content read in the VM: '$content'"
echo "==> shared folder: write refused"
if guest "$VM" "touch /mnt/nido/docs/nuovo.txt" 2>"$LOGS/touch.err"; then
    fail "writing to the read-only folder succeeded"
fi
cat "$LOGS/touch.err"
[[ ! -e "$SHARE_DIR/docs/nuovo.txt" ]] || fail "a file created in the VM reached the Mac"
[[ "$(ls "$SHARE_DIR/docs")" == "nota.txt" ]] || fail "the folder on the Mac changed"

if (( rosetta )); then
    echo "==> Rosetta: x86_64 binary"
    # 175-byte static x86_64 ELF: write(1, "x86_64 via Rosetta ok\n") + exit(0).
    elf='f0VMRgIBAQAAAAAAAAAAAAIAPgABAAAAeABAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAEAAOAABAAAAAAAAAAEAAAAFAAAAAAAAAAAAAAAAAEAAAAAAAAAAQAAAAAAArwAAAAAAAACvAAAAAAAAAAAQAAAAAAAAuAEAAAC/AQAAAEiNNRAAAAC6FgAAAA8FuDwAAAAx/w8FeDg2XzY0IHZpYSBSb3NldHRhIG9rCg=='
    out=$(guest "$VM" "echo $elf | base64 -d >/tmp/hello-x86_64 && chmod +x /tmp/hello-x86_64 && /tmp/hello-x86_64")
    [[ "$out" == "x86_64 via Rosetta ok" ]] || fail "x86_64 binary: '$out'"
    echo "$out"
fi

echo "==> suspend: counter in the guest"
guest "$VM" "nohup sh -c 'i=0; while :; do i=\$((i+1)); echo \$i >/tmp/contatore; sleep 1; done' >/dev/null 2>&1 &"
sleep 5
c1=$(guest "$VM" cat /tmp/contatore)
b1=$(guest "$VM" cat /proc/sys/kernel/random/boot_id)
echo "before: counter=$c1 boot_id=$b1"
s0=$(now)
"$NIDO" stop --suspend "$VM"
for _ in $(seq 1 120); do
    kill -0 "$VM_PID" 2>/dev/null || break
    sleep 0.2
done
kill -0 "$VM_PID" 2>/dev/null && fail "nido start did not exit after the suspend"
wait "$VM_PID"
s1=$(now)
VM_PID=""
wait "$SAMPLER_PID" 2>/dev/null || true
SAMPLER_PID=""
suspend_time=$(elapsed "$s0" "$s1")
expect_state "$VM" sospesa
perms=$(stat -f '%Sp' "$NIDO_ROOT/$VM.nidovm/state.vzvmsave")
[[ "$perms" == "-rw-------" ]] || fail "state.vzvmsave has permissions $perms"
state_size=$(stat -f '%z' "$NIDO_ROOT/$VM.nidovm/state.vzvmsave")
sleep 5

echo "==> resume"
r0=$(now)
start_bg "$VM" start-2
VM_PID=$STARTED_PID
wait_ssh "$VM" "$VM_PID" 120
r1=$(now)
resume_time=$(elapsed "$r0" "$r1")
grep -q "ripresa dallo stato sospeso" "$LOGS/start-2.log" || fail "the VM was not resumed from the suspended state"
# The guest counter ticks once a second: give it time to tick after resuming.
sleep 2
c2=$(guest "$VM" cat /tmp/contatore)
b2=$(guest "$VM" cat /proc/sys/kernel/random/boot_id)
echo "after: counter=$c2 boot_id=$b2"
[[ "$b1" == "$b2" ]] || fail "boot_id changed: the VM cold-booted"
(( c2 > c1 )) || fail "the counter did not move on ($c1 → $c2)"
[[ ! -e "$NIDO_ROOT/$VM.nidovm/state.vzvmsave" ]] || fail "state.vzvmsave left after the resume"

echo "==> stop (max 60 s)"
stop_vm "$VM" "$VM_PID"
VM_PID=""

echo "==> list"
"$NIDO" list
expect_state "$VM" ferma

echo "==> snapshot create (VM stopped)"
n0=$(now)
"$NIDO" snapshot create "$VM" base
n1=$(now)
snapshot_time=$(elapsed "$n0" "$n1")
"$NIDO" snapshot list "$VM" | tee "$LOGS/snapshots.txt"
grep -q "base" "$LOGS/snapshots.txt" || fail "snapshot 'base' is not listed"

echo "==> change in the guest after the snapshot"
start_bg "$VM" start-3
VM_PID=$STARTED_PID
wait_ssh "$VM" "$VM_PID" 180
guest "$VM" "echo dopo-lo-snapshot >/home/nido/modifica.txt && sync"
guest "$VM" cat /home/nido/modifica.txt
stop_vm "$VM" "$VM_PID"
VM_PID=""

echo "==> snapshot restore"
"$NIDO" snapshot restore "$VM" base --yes

echo "==> clone"
k0=$(now)
"$NIDO" clone "$VM" "$CLONE"
k1=$(now)
clone_time=$(elapsed "$k0" "$k1")
if grep -q '"hostPath"' "$NIDO_ROOT/$CLONE.nidovm/config.json"; then fail "the clone inherited the shared folder"; fi

echo "==> starting the original and the clone (2 × 2 GiB)"
start_bg "$VM" start-4
VM_PID=$STARTED_PID
start_bg "$CLONE" start-clone
CLONE_PID=$STARTED_PID
wait_ssh "$VM" "$VM_PID" 180
wait_ssh "$CLONE" "$CLONE_PID" 180

echo "==> restore: the change is gone"
guest "$VM" "test ! -e /home/nido/modifica.txt" \
    || fail "the file created after the snapshot still exists (or SSH does not answer)"

echo "==> identity of the original and the clone"
ip_a=$("$NIDO" ip "$VM"); ip_b=$("$NIDO" ip "$CLONE")
host_a=$(guest "$VM" hostname); host_b=$(guest "$CLONE" hostname)
mid_a=$(guest "$VM" cat /etc/machine-id); mid_b=$(guest "$CLONE" cat /etc/machine-id)
printf '%-12s %-18s %-18s\n' "" "$VM" "$CLONE"
printf '%-12s %-18s %-18s\n' "IP" "$ip_a" "$ip_b"
printf '%-12s %-18s %-18s\n' "hostname" "$host_a" "$host_b"
printf '%-12s %-18s %-18s\n' "machine-id" "${mid_a:0:12}…" "${mid_b:0:12}…"
[[ "$ip_a" != "$ip_b" ]] || fail "the original and the clone have the same IP"
[[ "$host_a" == "$VM" && "$host_b" == "$CLONE" ]] || fail "unexpected host names: $host_a / $host_b"
[[ "$mid_a" != "$mid_b" ]] || fail "the original and the clone have the same machine-id"
if guest "$CLONE" test -e /mnt/nido/docs/nota.txt; then fail "the clone sees the original's shared folder"; fi
[[ "$(guest "$CLONE" systemctl is-active nido-guest-tools)" == "active" ]] || fail "Guest Tools not active in the clone"

echo "==> stopping the original and the clone"
stop_vm "$VM" "$VM_PID"
VM_PID=""
stop_vm "$CLONE" "$CLONE_PID"
CLONE_PID=""
expect_state "$VM" ferma
expect_state "$CLONE" ferma
"$NIDO" delete "$CLONE" --yes

echo "==> VM template: save, start refused"
"$NIDO" template save "$VM"
expect_state "$VM" "ferma \\(modello\\)"
if "$NIDO" start "$VM" >"$LOGS/start-template.log" 2>&1; then fail "a template started"; fi
grep -q "è un modello" "$LOGS/start-template.log" || fail "unexpected refusal message"

echo "==> new VM from the template"
f0=$(now)
"$NIDO" create "$FROM_TEMPLATE" --from-template "$VM"
f1=$(now)
template_time=$(elapsed "$f0" "$f1")
config_new="$NIDO_ROOT/$FROM_TEMPLATE.nidovm/config.json"
if grep -q '"isTemplate" : true\|"aiBridge"\|"hostPath"' "$config_new"; then fail "the new VM inherited the template flag, the bridge or folders"; fi
start_bg "$FROM_TEMPLATE" start-from-template
VM_PID=$STARTED_PID
wait_ssh "$FROM_TEMPLATE" "$VM_PID" 180
host_n=$(guest "$FROM_TEMPLATE" hostname)
mid_n=$(guest "$FROM_TEMPLATE" cat /etc/machine-id)
key_n=$(host_key "$FROM_TEMPLATE")
printf '%-12s %-18s %-18s\n' "" "$VM (template)" "$FROM_TEMPLATE"
printf '%-12s %-18s %-18s\n' "machine-id" "${mid_t:0:12}…" "${mid_n:0:12}…"
printf '%-12s %-18s %-18s\n' "host key" "${key_t:7:12}…" "${key_n:7:12}…"
[[ "$host_n" == "$FROM_TEMPLATE" ]] || fail "host name of the new VM: $host_n"
[[ "$mid_n" != "$mid_t" ]] || fail "same machine-id as the template"
[[ "$key_n" != "$key_t" ]] || fail "same SSH host key as the template"
[[ "$(guest "$FROM_TEMPLATE" systemctl is-active nido-guest-tools)" == "active" ]] || fail "Guest Tools not active"
stop_vm "$FROM_TEMPLATE" "$VM_PID"
VM_PID=""
"$NIDO" delete "$FROM_TEMPLATE" --yes
"$NIDO" template edit "$VM"
"$NIDO" delete "$VM" --yes

echo "==> existing VM without Guest Tools (as before Nido 0.3.0)"
"$NIDO" create "$OLD" --image-file "$NIDO_TEST_IMAGE" --ssh-key "$NIDO_TEST_KEY" \
    --memory 2G --cpus 2 --disk 8G --no-packages --no-guest-tools --yes
if grep -q '"guestToolsVersion"' "$NIDO_ROOT/$OLD.nidovm/config.json"; then fail "guestToolsVersion without Guest Tools"; fi
start_bg "$OLD" start-old
VM_PID=$STARTED_PID
wait_ssh "$OLD" "$VM_PID" 180
guest "$OLD" cloud-init status --wait >/dev/null || true
if guest "$OLD" test -e /opt/nido-guest-tools/VERSION; then fail "Guest Tools present without being asked for"; fi
[[ "$(guest "$OLD" cat /proc/sys/kernel/panic)" == "0" ]] || fail "kernel.panic already set"

echo "==> Guest Tools over SSH (like \"Install Guest Tools\")"
g0=$(now)
"$PROBE" guest-tools "$NIDO_ROOT" "$OLD" | tee "$LOGS/guest-tools.log"
g1=$(now)
gt_install_time=$(elapsed "$g0" "$g1")
grep -q "nido-guest-tools: active" "$LOGS/guest-tools.log" || fail "service not active after the installation"
grep -q '"guestToolsVersion"' "$NIDO_ROOT/$OLD.nidovm/config.json" || fail "guestToolsVersion not written"

echo "==> visible panics over SSH (explicit action)"
"$PROBE" panic-settings "$NIDO_ROOT" "$OLD"
[[ "$(guest "$OLD" cat /proc/sys/kernel/panic)" == "10" ]] || fail "kernel.panic not applied"

stop_vm "$OLD" "$VM_PID"
VM_PID=""

echo "==> monitor over vsock at the restart after the installation"
probe_start "$OLD"
old_monitor=$(probe_cmd "monitor 180" "monitor ok" 200)
echo "$old_monitor"
grep -q "hostname=$OLD " <<<"$old_monitor" || fail "the monitor does not report host name $OLD"
probe_stop
"$NIDO" delete "$OLD" --yes

echo "==> controlled network with gvproxy: new VM $NET (the default), first boot with the packages"
"$NIDO" create "$NET" --image-file "$NIDO_TEST_IMAGE" --ssh-key "$NIDO_TEST_KEY" \
    --memory 2G --cpus 2 --disk 8G --yes
grep -q '"controlledNetwork" : true' "$NIDO_ROOT/$NET.nidovm/config.json" || fail "$NET is not on the controlled network by default"
start_bg "$NET" start-net
VM_PID=$STARTED_PID
wait_ssh "$NET" "$VM_PID" 180
guest "$NET" cloud-init status --wait >"$LOGS/cloud-init-net.txt" || true
grep -q "status: done" "$LOGS/cloud-init-net.txt" || { cat "$LOGS/cloud-init-net.txt"; fail "cloud-init of $NET is not done"; }
guest "$NET" "dpkg-query -W -f='\${Package} \${Status}\n' curl jq zstd" >"$LOGS/packages-net.txt"
[[ "$(grep -c 'install ok installed' "$LOGS/packages-net.txt")" == "3" ]] || { cat "$LOGS/packages-net.txt"; fail "first-boot packages missing on $NET"; }
echo "==> apt update through the filter"
guest "$NET" "sudo apt-get update" >"$LOGS/apt-net.txt" 2>&1 || { tail -n 5 "$LOGS/apt-net.txt"; fail "apt update failed"; }
grep -q "^Reading package lists" "$LOGS/apt-net.txt" || fail "apt update without the package lists"

echo "==> a site not on the list is blocked and shows in the log"
if guest "$NET" curl -sS -o /dev/null --max-time 10 https://example.org 2>/dev/null; then fail "example.org reachable: it should be blocked"; fi
seen=0
for _ in $(seq 1 15); do
    if "$NIDO" net log "$NET" | grep -q "bloccato.*example\.org"; then seen=1; break; fi
    sleep 1
done
(( seen )) || fail "example.org blocked but missing from nido net log"

echo "==> nido ip and nido ssh on the 127.0.0.1 forward"
ip_line=$("$NIDO" ip "$NET")
echo "$ip_line"
grep -Eq '^192\.168\.127\.2 \(SSH dal Mac: 127\.0\.0\.1:[0-9]+\)$' <<<"$ip_line" || fail "nido ip: unexpected format"
port1=$(sed -E 's/.*127\.0\.0\.1:([0-9]+).*/\1/' <<<"$ip_line")
[[ "$(guest "$NET" hostname)" == "$NET" ]] || fail "nido ssh does not reach $NET"

echo "==> stop and start again: new port, no host-key warning"
stop_vm "$NET" "$VM_PID"
VM_PID=""
start_bg "$NET" start-net2
VM_PID=$STARTED_PID
wait_ssh "$NET" "$VM_PID" 180
ip_line=$("$NIDO" ip "$NET")
port2=$(sed -E 's/.*127\.0\.0\.1:([0-9]+).*/\1/' <<<"$ip_line")
echo "SSH port: $port1 → $port2"
ssh_out=$("$NIDO" ssh "$NET" -- "${ssh_extra[@]}" hostname </dev/null 2>&1) || fail "nido ssh after the restart: $ssh_out"
[[ "$ssh_out" == "$NET" ]] || fail "nido ssh after the restart printed something else (a host-key warning?): $ssh_out"
[[ "$(grep -c . "$NIDO_ROOT/$NET.nidovm/known_hosts")" == "1" ]] || fail "known_hosts with more than one line"

echo "==> kill -9 of nido start: no gvproxy of $NET left after the next start of another VM"
gv_pid=$(jq -r '.pid' "$NIDO_ROOT/$NET.nidovm/ssh-forward.json")
kill -0 "$gv_pid" 2>/dev/null || fail "gvproxy of $NET is not running (pid $gv_pid)"
kill -KILL "$VM_PID"
wait "$VM_PID" 2>/dev/null || true
VM_PID=""
"$NIDO" create "$NET2" --image-file "$NIDO_TEST_IMAGE" --ssh-key "$NIDO_TEST_KEY" \
    --memory 2G --cpus 2 --disk 8G --no-packages --no-guest-tools --yes
start_bg "$NET2" start-net-b
VM_PID=$STARTED_PID
gone=0
for _ in $(seq 1 30); do
    if ! kill -0 "$gv_pid" 2>/dev/null; then gone=1; break; fi
    sleep 1
done
(( gone )) || fail "the orphan gvproxy (pid $gv_pid) is still running after $NET2 started"
wait_ssh "$NET2" "$VM_PID" 180
if nc -z 127.0.0.1 "$port2" 2>/dev/null; then fail "the orphan's SSH port $port2 is still listening"; fi
stop_vm "$NET2" "$VM_PID"
VM_PID=""
"$NIDO" delete "$NET2" --yes
"$NIDO" delete "$NET" --yes

if [[ "${NIDO_TEST_OLLAMA:-}" == "1" ]]; then
    echo "==> phase 2 (NIDO_TEST_OLLAMA=1): VM $AI (standard profile, 2 GiB, 16 GiB disk)"
    echo "    Ollama at the pinned version and $OLLAMA_MODEL: about 2 GiB downloaded in the guest"
    "$NIDO" create "$AI" --image-file "$NIDO_TEST_IMAGE" --ssh-key "$NIDO_TEST_KEY" \
        --memory 2G --cpus 2 --disk 16G --yes
    start_bg "$AI" start-ai
    VM_PID=$STARTED_PID
    wait_ssh "$AI" "$VM_PID" 180
    guest "$AI" cloud-init status --wait >/dev/null || true
    o0=$(now)
    "$PROBE" ollama "$NIDO_ROOT" "$AI" install | tee "$LOGS/ollama.log"
    o1=$(now)
    "$PROBE" ollama "$NIDO_ROOT" "$AI" pull "$OLLAMA_MODEL" | tee -a "$LOGS/ollama.log"
    o2=$(now)
    "$PROBE" ollama "$NIDO_ROOT" "$AI" verify | tee -a "$LOGS/ollama.log"
    "$PROBE" ollama "$NIDO_ROOT" "$AI" status | tee -a "$LOGS/ollama.log"
    grep -q "attivo=true" "$LOGS/ollama.log" || fail "Ollama not active"
    grep -q "modelli=.*$OLLAMA_MODEL" "$LOGS/ollama.log" || fail "model not listed"
    c0=$(now)
    "$PROBE" ollama "$NIDO_ROOT" "$AI" chat "$OLLAMA_MODEL" "Rispondi solo: ciao" | tee -a "$LOGS/ollama.log"
    c1=$(now)
    guest "$AI" ss -Hltn | awk '{print $4}' | tee "$LOGS/listeners-ai.txt"
    grep -qx '127\.0\.0\.1:11434' "$LOGS/listeners-ai.txt" || fail "Ollama not listening on 127.0.0.1:11434"
    if grep -E ':11434$' "$LOGS/listeners-ai.txt" | grep -vqx '127\.0\.0\.1:11434'; then fail "Ollama outside the loopback"; fi
    ollama_install_time=$(elapsed "$o0" "$o1")
    ollama_pull_time=$(elapsed "$o1" "$o2")
    ollama_chat_time=$(elapsed "$c0" "$c1")
    stop_vm "$AI" "$VM_PID"
    VM_PID=""
    "$NIDO" delete "$AI" --yes
fi

"$NIDO" list

echo "First boot until the monitor answers (phase 1 included): $monitor_time s"
echo "Seconds from nido start to a working SSH (second boot): $boot_to_ssh"
echo "Peak RSS of the start process: $(cat "$RSS_FILE") KiB"
echo "Suspend (nido stop --suspend until start exits): $suspend_time s, saved state $(( state_size / 1048576 )) MiB"
echo "Resume (nido start until SSH works): $resume_time s"
echo "Snapshot creation (VM stopped, 8 GiB disk): $snapshot_time s"
echo "Clone (8 GiB disk): $clone_time s"
echo "Creation from a template: $template_time s"
echo "Guest Tools over SSH on an existing VM: $gt_install_time s"
if [[ "${NIDO_TEST_OLLAMA:-}" == "1" ]]; then
    echo "Phase 2: Ollama $ollama_install_time s, model $OLLAMA_MODEL $ollama_pull_time s, one reply $ollama_chat_time s"
else
    echo "Phase 2: not run (NIDO_TEST_OLLAMA=1 to run it)"
fi
echo "Controlled network (gvproxy, IP forwarding 0): apt update, block, ssh, restart and kill -9 verified"
if (( rosetta )); then echo "Rosetta: verified"; else echo "Rosetta: skipped (not installed)"; fi
