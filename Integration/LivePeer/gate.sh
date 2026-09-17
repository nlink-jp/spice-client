#!/bin/bash
# make live-peer (ADR-0002): build what is missing, start the peer, run the
# application-path tests against it, require both tests to have run and the
# injected key to appear in the guest log, record the pass for this commit,
# and always stop the container.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib.sh"
export SPICE_CLIENT_LIVE_PEER_IMAGE="${SPICE_CLIENT_LIVE_PEER_IMAGE:-localhost/spice-client-live-peer:local}"
export SPICE_CLIENT_LIVE_PEER_CONTAINER="${SPICE_CLIENT_LIVE_PEER_CONTAINER:-spice-client-live-peer}"
export SPICE_CLIENT_LIVE_PEER_ARTIFACTS="${SPICE_CLIENT_LIVE_PEER_ARTIFACTS:-$HERE/Artifacts}"
IMAGE="$SPICE_CLIENT_LIVE_PEER_IMAGE"; NAME="$SPICE_CLIENT_LIVE_PEER_CONTAINER"; ARTIFACTS="$SPICE_CLIENT_LIVE_PEER_ARTIFACTS"
command -v podman > /dev/null || { echo "live-peer: podman is required (brew install podman; podman machine init/start)" >&2; exit 1; }
podman info > /dev/null 2>&1 || { echo "live-peer: the podman machine is not running (podman machine start)" >&2; exit 1; }
ENV_FILE="$(mktemp "${TMPDIR:-/tmp}/spice-client-live-peer.env.XXXXXX")"
RECEIPT="$(mktemp "${TMPDIR:-/tmp}/spice-client-live-peer.receipt.XXXXXX")"
GUEST_LOG="$(mktemp "${TMPDIR:-/tmp}/spice-client-live-peer.log.XXXXXX")"
finish() {
    status=$?
    trap - EXIT INT TERM
    if [ "$status" -ne 0 ]; then
        echo "live-peer: FAILED (status $status); peer container: $(podman inspect --format 'running={{.State.Running}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} finished={{.State.FinishedAt}}' "$NAME" 2>&1)" >&2
        echo "live-peer: last guest/QEMU log lines (input events omitted):" >&2
        podman logs "$NAME" 2>&1 | grep -v '^INPUT_EVENT\|^ [0-9a-f][0-9a-f] \|framebuffer tick' | tail -n 60 >&2 || true
    fi
    if [ -s "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; fi
    # SPICE_CLIENT_LIVE_PEER_KEEP_LOG=<path> keeps the whole guest log, pass or
    # fail; the failure tail above is 60 lines, which can cut a sequence in half.
    if [ -n "${SPICE_CLIENT_LIVE_PEER_KEEP_LOG:-}" ]; then
        podman logs "$NAME" 2>&1 | tr -d '\r' > "$SPICE_CLIENT_LIVE_PEER_KEEP_LOG" || true
        cp "$RECEIPT" "$SPICE_CLIENT_LIVE_PEER_KEEP_LOG.receipt" 2>/dev/null || true
    fi
    bash "$HERE/stop.sh"
    rm -f "$ENV_FILE" "$RECEIPT" "$GUEST_LOG"
    exit "$status"
}
trap finish EXIT INT TERM
podman image exists "$IMAGE" || bash "$HERE/build-image.sh"
test -s "$ARTIFACTS/image.json" || live_peer_describe_image "$IMAGE" "$HERE/Containerfile" "$ARTIFACTS/image.json"
test -s "$ARTIFACTS/initramfs.cpio.gz" && live_peer_guest_current "$ARTIFACTS" "$HERE/guest" || bash "$HERE/build-guest.sh"
bash "$HERE/run.sh" "$ENV_FILE"
set -a; . "$ENV_FILE"; set +a
export SPICE_CLIENT_LIVE_PEER_RECEIPT="$RECEIPT"
# The SPICE server accepts one client at a time, so the two suites must not run
# concurrently; swift test parallelises suites, so run them as separate
# invocations. The agent suite runs only when the agent stack came up; when it
# did not, its receipts are missing and the receipt check below fails closed.
if [ "${SPICE_CLIENT_LIVE_PEER_AGENT:-0}" != 1 ]; then unset SPICE_CLIENT_LIVE_PEER_AGENT; fi
( cd "$ROOT" && swift test --disable-sandbox -Xswiftc -warnings-as-errors --filter LivePeerTests )
if [ -n "${SPICE_CLIENT_LIVE_PEER_AGENT:-}" ]; then
    ( cd "$ROOT" && swift test --disable-sandbox -Xswiftc -warnings-as-errors --filter LiveAgentTests )
fi
live_peer_tests_ran "$RECEIPT" connectsPresentsRealFramesDeliversInputAndReconnects wrongTicketFailsAuthenticationAndThePeerSurvives \
        connectsOverTLSWithTheFileCertificateAuthority connectsOverTLSWhenTheHostSubjectMatches rejectsADecoyAuthorityAndAWrongSubjectAndThePeerSurvives \
        clipboardFollowsSharingAndFocusInBothDirections resizeRequestReachesTheGuestTwiceOnOneAgentConnection \
    || { echo "live-peer: not all eight tests ran (transport, TLS, agent); a suite skips silently without its environment, and the agent suite needs the guest agent stack" >&2; exit 1; }
# The serial console ends lines with CRLF; anchored matches need the CR gone.
podman logs "$NAME" 2>&1 | tr -d '\r' > "$GUEST_LOG"
live_peer_guest_saw_key "$GUEST_LOG" || { echo "live-peer: the guest did not record the injected A key (evdev code 30 down)" >&2; exit 1; }
live_peer_agent_log_matches "$RECEIPT" "$GUEST_LOG"
echo "live-peer: observed latencies (ms): $(grep '^latency ' "$RECEIPT" | cut -d' ' -f2- | tr '\n' ';')"
HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"
if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then DIRTY=true; else DIRTY=false; fi
python3 - "$ARTIFACTS" "$HEAD_SHA" "$DIRTY" <<'PY'
import json, sys, datetime, pathlib
artifacts, head, dirty = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3] == "true"
record = {"passed": True, "head": head, "dirty": dirty,
          "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
          "guest": json.load(open(artifacts / "guest.json")), "image": json.load(open(artifacts / "image.json"))}
(artifacts / "last-pass.json").write_text(json.dumps(record, indent=2) + "\n")
PY
echo "live-peer: passed on $HEAD_SHA (dirty=$DIRTY); $(cat "$ARTIFACTS/image.json"); guest $(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d['kernel'], d['initramfs_sha256'][:12], len(d.get('packages', [])), 'packages')" "$ARTIFACTS/guest.json")"
