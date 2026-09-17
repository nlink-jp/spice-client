#!/bin/bash
# make live-peer (ADR-0002, ADR-0003): build what is missing, run the
# application-path tests against a real peer in two phases, check the guest logs
# and the tests' own receipt, record the pass for this commit, and always stop
# every container.
#
# Phase 1 is churn-heavy: transport, TLS and the agent suites connect and
# disconnect many times against one peer. Phase 2 is the audio test on its own
# peer with the playback device and a single connection, because the playback
# channel makes QEMU's spice server crash under repeated connect/disconnect
# (measured 2026-09-18: 3 crashes in 12 runs with the device, 0 in 18 without,
# on 8.2.2, and 2 in 5 on 10.0.13; 5 of 5 clean with one connection).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib.sh"
export SPICE_CLIENT_LIVE_PEER_IMAGE="${SPICE_CLIENT_LIVE_PEER_IMAGE:-localhost/spice-client-live-peer:local}"
export SPICE_CLIENT_LIVE_PEER_ARTIFACTS="${SPICE_CLIENT_LIVE_PEER_ARTIFACTS:-$HERE/Artifacts}"
IMAGE="$SPICE_CLIENT_LIVE_PEER_IMAGE"; ARTIFACTS="$SPICE_CLIENT_LIVE_PEER_ARTIFACTS"
MAIN_NAME="${SPICE_CLIENT_LIVE_PEER_CONTAINER:-spice-client-live-peer}"
AUDIO_NAME="${MAIN_NAME}-audio"
command -v podman > /dev/null || { echo "live-peer: podman is required (brew install podman; podman machine init/start)" >&2; exit 1; }
podman info > /dev/null 2>&1 || { echo "live-peer: the podman machine is not running (podman machine start)" >&2; exit 1; }
ENV_FILE="$(mktemp "${TMPDIR:-/tmp}/spice-client-live-peer.env.XXXXXX")"
AUDIO_ENV_FILE="$(mktemp "${TMPDIR:-/tmp}/spice-client-live-peer-audio.env.XXXXXX")"
RECEIPT="$(mktemp "${TMPDIR:-/tmp}/spice-client-live-peer.receipt.XXXXXX")"
GUEST_LOG="$(mktemp "${TMPDIR:-/tmp}/spice-client-live-peer.log.XXXXXX")"
PHASE=1

report_peer() {
    echo "live-peer: peer $1: $(podman inspect --format 'running={{.State.Running}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} finished={{.State.FinishedAt}}' "$1" 2>&1)" >&2
    echo "live-peer: its last guest/QEMU log lines (input events omitted):" >&2
    podman logs "$1" 2>&1 | grep -v '^INPUT_EVENT\|^ [0-9a-f][0-9a-f] ' | tail -n 60 >&2 || true
}
finish() {
    status=$?
    trap - EXIT INT TERM
    if [ "$status" -ne 0 ]; then
        echo "live-peer: FAILED in phase $PHASE (status $status)" >&2
        report_peer "$MAIN_NAME"
        if [ "$PHASE" = 2 ]; then report_peer "$AUDIO_NAME"; fi
    fi
    # SPICE_CLIENT_LIVE_PEER_KEEP_LOG=<path> keeps the whole guest log, pass or
    # fail; the failure tail above is 60 lines, which can cut a sequence in half.
    if [ -n "${SPICE_CLIENT_LIVE_PEER_KEEP_LOG:-}" ]; then
        podman logs "$MAIN_NAME" 2>&1 | tr -d '\r' > "$SPICE_CLIENT_LIVE_PEER_KEEP_LOG" || true
        podman logs "$AUDIO_NAME" 2>&1 | tr -d '\r' > "$SPICE_CLIENT_LIVE_PEER_KEEP_LOG.audio" || true
        cp "$RECEIPT" "$SPICE_CLIENT_LIVE_PEER_KEEP_LOG.receipt" 2>/dev/null || true
    fi
    if [ -s "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; fi
    SPICE_CLIENT_LIVE_PEER_CONTAINER="$MAIN_NAME" bash "$HERE/stop.sh"
    if [ -s "$AUDIO_ENV_FILE" ]; then set -a; . "$AUDIO_ENV_FILE"; set +a; fi
    SPICE_CLIENT_LIVE_PEER_CONTAINER="$AUDIO_NAME" bash "$HERE/stop.sh"
    rm -f "$ENV_FILE" "$AUDIO_ENV_FILE" "$RECEIPT" "$GUEST_LOG"
    exit "$status"
}
trap finish EXIT INT TERM

podman image exists "$IMAGE" || bash "$HERE/build-image.sh"
test -s "$ARTIFACTS/image.json" || live_peer_describe_image "$IMAGE" "$HERE/Containerfile" "$ARTIFACTS/image.json"
test -s "$ARTIFACTS/initramfs.cpio.gz" && live_peer_guest_current "$ARTIFACTS" "$HERE/guest" || bash "$HERE/build-guest.sh"
export SPICE_CLIENT_LIVE_PEER_RECEIPT="$RECEIPT"

# --- phase 1: transport, TLS and the agent, against one peer without audio ---
SPICE_CLIENT_LIVE_PEER_CONTAINER="$MAIN_NAME" bash "$HERE/run.sh" "$ENV_FILE"
set -a; . "$ENV_FILE"; set +a
export SPICE_CLIENT_LIVE_PEER_CONTAINER="$MAIN_NAME"
# The SPICE server accepts one client at a time, so the suites must not run
# concurrently; swift test parallelises suites, so run them as separate
# invocations. The agent suite runs only when the agent stack came up; when it
# did not, its receipts are missing and the receipt check below fails closed.
if [ "${SPICE_CLIENT_LIVE_PEER_AGENT:-0}" != 1 ]; then unset SPICE_CLIENT_LIVE_PEER_AGENT; fi
( cd "$ROOT" && swift test --disable-sandbox -Xswiftc -warnings-as-errors --filter LivePeerTests )
if [ -n "${SPICE_CLIENT_LIVE_PEER_AGENT:-}" ]; then
    ( cd "$ROOT" && swift test --disable-sandbox -Xswiftc -warnings-as-errors --filter LiveAgentTests )
fi
# The serial console ends lines with CRLF; anchored matches need the CR gone.
podman logs "$MAIN_NAME" 2>&1 | tr -d '\r' > "$GUEST_LOG"
live_peer_guest_saw_key "$GUEST_LOG" || { echo "live-peer: the guest did not record the injected A key (evdev code 30 down)" >&2; exit 1; }
live_peer_agent_log_matches "$RECEIPT" "$GUEST_LOG"
SPICE_CLIENT_LIVE_PEER_CONTAINER="$MAIN_NAME" bash "$HERE/stop.sh"

# --- phase 2: audio, on its own peer, one connection ---
PHASE=2
SPICE_CLIENT_LIVE_PEER_CONTAINER="$AUDIO_NAME" SPICE_CLIENT_LIVE_PEER_AUDIO=1 bash "$HERE/run.sh" "$AUDIO_ENV_FILE"
set -a; . "$AUDIO_ENV_FILE"; set +a
export SPICE_CLIENT_LIVE_PEER_CONTAINER="$AUDIO_NAME" SPICE_CLIENT_LIVE_PEER_AUDIO=1
( cd "$ROOT" && swift test --disable-sandbox -Xswiftc -warnings-as-errors --filter LiveAudioTests )
podman logs "$AUDIO_NAME" 2>&1 | tr -d '\r' > "$GUEST_LOG"
live_peer_guest_audio_started "$GUEST_LOG" || { echo "live-peer: the audio guest never started playing" >&2; exit 1; }

live_peer_tests_ran "$RECEIPT" connectsPresentsRealFramesDeliversInputAndReconnects wrongTicketFailsAuthenticationAndThePeerSurvives \
        connectsOverTLSWithTheFileCertificateAuthority connectsOverTLSWhenTheHostSubjectMatches rejectsADecoyAuthorityAndAWrongSubjectAndThePeerSurvives \
        clipboardFollowsSharingAndFocusInBothDirections resizeRequestReachesTheGuestTwiceOnOneAgentConnection \
        receivesAudioPlaybackFromTheGuest \
    || { echo "live-peer: not all eight tests ran (transport, TLS, agent, audio); a suite skips silently without its environment, the agent suite needs the guest agent stack, and the audio suite needs phase 2" >&2; exit 1; }
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
