#!/bin/bash
# Stop the live peer container and remove its ticket file. Idempotent; also the
# gate's trap handler.
set -uo pipefail
NAME="${SPICE_CLIENT_LIVE_PEER_CONTAINER:-spice-client-live-peer}"
podman rm -f "$NAME" > /dev/null 2>&1 || true
if [ -n "${SPICE_CLIENT_LIVE_PEER_TICKET_FILE:-}" ]; then rm -f "$SPICE_CLIENT_LIVE_PEER_TICKET_FILE"; fi
echo "stop: live peer $NAME removed"
