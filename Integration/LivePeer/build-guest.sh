#!/bin/bash
# Build the live-peer guest (kernel + initramfs + guest.json) inside the pinned
# Alpine image (ADR-0002). Output goes to Artifacts/, which git ignores.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ARTIFACTS="${SPICE_CLIENT_LIVE_PEER_ARTIFACTS:-$HERE/Artifacts}"
GUEST_BASE_IMAGE="docker.io/library/alpine@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce"
mkdir -p "$ARTIFACTS"
podman run --rm --memory 1g \
    --env "GUEST_BASE_IMAGE=$GUEST_BASE_IMAGE" \
    --volume "$ARTIFACTS:/out" \
    --volume "$HERE/guest:/guest:ro" \
    "$GUEST_BASE_IMAGE" sh /guest/build-in-container.sh
for name in vmlinuz-virt initramfs.cpio.gz guest.json; do
    test -s "$ARTIFACTS/$name" || { echo "build-guest: missing $ARTIFACTS/$name" >&2; exit 1; }
done
echo "build-guest: wrote $ARTIFACTS"
