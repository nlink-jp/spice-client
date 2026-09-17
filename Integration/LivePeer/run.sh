#!/bin/bash
# Start one live peer container (ADR-0002) and write its ports, ticket, ticket
# file, TLS material directory and name to the given environment file. The SPICE port is published on
# loopback with an ephemeral host port (a retained forward from an earlier run
# cannot be mistaken for this one); the ticket is random per run, handed to
# QEMU as a file rather than an argument, and removed by stop.sh; QEMU itself
# has a lifetime limit so an interrupted gate cannot leave it running forever.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
ENV_FILE="${1:?usage: run.sh <environment-file>}"
IMAGE="${SPICE_CLIENT_LIVE_PEER_IMAGE:-localhost/spice-client-live-peer:local}"
NAME="${SPICE_CLIENT_LIVE_PEER_CONTAINER:-spice-client-live-peer}"
ARTIFACTS="${SPICE_CLIENT_LIVE_PEER_ARTIFACTS:-$HERE/Artifacts}"
LIFETIME="${SPICE_CLIENT_LIVE_PEER_LIFETIME:-1800}"
for name in vmlinuz-virt initramfs.cpio.gz guest.json; do
    test -s "$ARTIFACTS/$name" || { echo "run: missing $ARTIFACTS/$name; run build-guest.sh" >&2; exit 1; }
done
podman image exists "$IMAGE" || { echo "run: missing image $IMAGE; run build-image.sh" >&2; exit 1; }
TICKET_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/spice-client/live-peer"
mkdir -p "$TICKET_DIR"
chmod 700 "$TICKET_DIR"
TICKET_FILE="$(mktemp "$TICKET_DIR/ticket.XXXXXX")"
chmod 600 "$TICKET_FILE"
TICKET="$(openssl rand -hex 16)"
printf '%s' "$TICKET" > "$TICKET_FILE"
# Per-run TLS material (phase 1b): QEMU reads ca-cert/server-cert/server-key from x509-dir.
X509_DIR="$(mktemp -d "$TICKET_DIR/x509.XXXXXX")"
live_peer_make_x509 "$X509_DIR" || { echo "run: could not generate the TLS certificates" >&2; exit 1; }
# A stale container of the same name is an interrupted earlier run.
podman rm -f "$NAME" > /dev/null 2>&1 || true
# One display head: the application presents a single display stream (ADR-0001),
# and a second head makes QEMU tear down two display channels per client
# disconnect, which is where it was seen to crash.
# No --rm: a peer that dies mid-run must keep its exit status and log for the
# gate to report. stop.sh removes the container; its lifetime is bounded by the
# QEMU timeout below and by the stale-name removal at the next start.
podman run --detach --name "$NAME" \
    --cpus "${SPICE_CLIENT_LIVE_PEER_CPUS:-4}" --memory 3g \
    --publish "127.0.0.1::5930" --publish "127.0.0.1::5931" \
    --volume "$ARTIFACTS:/guest:ro" \
    --volume "$TICKET_FILE:/run/spice-ticket:ro" \
    --volume "$X509_DIR:/run/x509:ro" \
    "$IMAGE" \
    timeout --signal=KILL "$LIFETIME" \
    qemu-system-aarch64 -nodefaults -no-user-config \
        -machine virt,gic-version=3 -accel tcg -cpu cortex-a72 -smp 2 -m 2048 \
        -kernel /guest/vmlinuz-virt -initrd /guest/initramfs.cpio.gz \
        -append "console=ttyAMA0 panic=-1" \
        -device virtio-gpu-pci,max_outputs=1 \
        -device virtio-keyboard-pci -device virtio-mouse-pci \
        -device virtio-serial-pci -chardev spicevmc,id=vdagent,name=vdagent \
        -device virtserialport,chardev=vdagent,name=com.redhat.spice.0 \
        -object secret,id=spice-password,file=/run/spice-ticket \
        -spice port=5930,tls-port=5931,addr=0.0.0.0,x509-dir=/run/x509,password-secret=spice-password \
        -display none -serial stdio -monitor none -no-reboot > /dev/null
PORT="$(podman port "$NAME" 5930/tcp | sed -n 's/^127\.0\.0\.1:\([0-9][0-9]*\)$/\1/p' | head -n 1)"
test -n "$PORT" || { echo "run: podman did not publish 5930/tcp on 127.0.0.1" >&2; exit 1; }
TLS_PORT="$(podman port "$NAME" 5931/tcp | sed -n 's/^127\.0\.0\.1:\([0-9][0-9]*\)$/\1/p' | head -n 1)"
test -n "$TLS_PORT" || { echo "run: podman did not publish 5931/tcp on 127.0.0.1" >&2; exit 1; }
alive() { test "$(podman inspect --format '{{.State.Running}}' "$NAME" 2> /dev/null)" = "true"; }
deadline=$((SECONDS + 120))
# Both virtio input devices must be monitored before a key is injected; evdev
# does not buffer for readers that are not there yet.
until [ "$(podman logs "$NAME" 2>&1 | grep -c '^GUEST monitoring /dev/input/event' || true)" -ge 2 ]; do
    alive || { echo "run: the peer container exited before the guest was ready" >&2; exit 1; }
    if (( SECONDS >= deadline )); then echo "run: guest input monitors not ready within 120s" >&2; exit 1; fi
    sleep 1
done
# The agent stack (dbus, spice-vdagentd, Xorg, spice-vdagent) comes after the base
# markers. Its failure does not stop this run: the transport tests still run and
# the gate fails on the missing agent receipts, which names the layer that broke.
AGENT=0
while true; do
    podman logs "$NAME" 2>&1 | tr -d '\r' > "$ENV_FILE.log" || true
    if live_peer_agent_status "$ENV_FILE.log"; then AGENT=1; break; fi
    status=$?
    if [ "$status" -eq 2 ]; then echo "run: guest agent stack failed: $(grep '^AGENT_ERROR' "$ENV_FILE.log" | head -n 1)" >&2; break; fi
    alive || { echo "run: the peer container exited before the agent stack started" >&2; exit 1; }
    if (( SECONDS >= deadline )); then echo "run: guest agent stack not started within 120s" >&2; break; fi
    sleep 1
done
rm -f "$ENV_FILE.log"
for published in "$PORT" "$TLS_PORT"; do
    until nc -z 127.0.0.1 "$published" > /dev/null 2>&1; do
        alive || { echo "run: the peer container exited before the listener was reachable" >&2; exit 1; }
        if (( SECONDS >= deadline )); then echo "run: SPICE listener not reachable on 127.0.0.1:$published within 120s" >&2; exit 1; fi
        sleep 1
    done
done
{
    echo "SPICE_CLIENT_LIVE_PEER_PORT=$PORT"
    echo "SPICE_CLIENT_LIVE_PEER_TLS_PORT=$TLS_PORT"
    echo "SPICE_CLIENT_LIVE_PEER_X509_DIR=$X509_DIR"
    echo "SPICE_CLIENT_LIVE_PEER_TICKET=$TICKET"
    echo "SPICE_CLIENT_LIVE_PEER_TICKET_FILE=$TICKET_FILE"
    echo "SPICE_CLIENT_LIVE_PEER_CONTAINER=$NAME"
    echo "SPICE_CLIENT_LIVE_PEER_AGENT=$AGENT"
} > "$ENV_FILE"
# vdagent announces its capabilities shortly after Xorg; give it the settle upstream uses.
if [ "$AGENT" = 1 ]; then sleep 5; fi
echo "run: live peer ready on 127.0.0.1:$PORT (TLS $TLS_PORT, agent=$AGENT) after ${SECONDS}s; guest kernel $(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['kernel'])" "$ARTIFACTS/guest.json")"
