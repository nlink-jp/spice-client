#!/bin/bash
# make package: refuse to release a commit the live peer gate has not passed on
# with a clean tree (ADR-0002).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
ARTIFACTS="${SPICE_CLIENT_LIVE_PEER_ARTIFACTS:-$HERE/Artifacts}"
HEAD_SHA="${1:?usage: require-pass.sh <git-head>}"
if live_peer_pass_matches "$ARTIFACTS/last-pass.json" "$HEAD_SHA"; then
    echo "live-peer: clean pass recorded for $HEAD_SHA"
else
    echo "live-peer: no clean pass recorded for $HEAD_SHA; run make live-peer on this commit" >&2
    exit 1
fi
