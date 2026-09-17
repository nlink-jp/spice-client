#!/bin/bash
# Build the QEMU + spice-server image locally and record what it contains
# (ADR-0002). Never pushed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
IMAGE="${SPICE_CLIENT_LIVE_PEER_IMAGE:-localhost/spice-client-live-peer:local}"
ARTIFACTS="${SPICE_CLIENT_LIVE_PEER_ARTIFACTS:-$HERE/Artifacts}"
mkdir -p "$ARTIFACTS"
podman build --tag "$IMAGE" --file "$HERE/Containerfile" "$HERE"
live_peer_describe_image "$IMAGE" "$HERE/Containerfile" "$ARTIFACTS/image.json"
echo "build-image: built $IMAGE; $(cat "$ARTIFACTS/image.json")"
